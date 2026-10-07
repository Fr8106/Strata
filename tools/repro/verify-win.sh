#!/bin/bash
# P4-A verification window (2026-10-07): deploy the phase-0 binary, verify the 48-layer Mapped
# registration + canary L0 + profile fill + READY, one prefill smoke, then RESTORE the LLM.
#
# Standing rule (memory: llm-service-window-rule): this session runs on the 8088 LLM, so stop and
# restore must be one closed loop.  Belt: trap on EXIT re-starts the container.  Suspenders: a
# dead-man timer registered BEFORE the stop brings it back in 25 min even if the script and the
# session both die (SIGKILL, SSH drop).  The explicit `docker start` at the end is the rule's step.
set -u
cd /home/ai/Strata
CTR=NInfer-kaushikvira-swift15
RES=/home/ai/Strata/tools/repro/verify-results.txt
SLOG=/home/ai/Strata/tools/repro/verify-server.log
ELOG=/home/ai/Strata/strata-iq3_s.log
: > "$RES"; : > "$SLOG"
log() { echo "$(date +%T) $*" | tee -a "$RES"; }

# 1) dead-man: register the restore BEFORE stopping the LLM (cancel a stale one from a crashed run)
sudo systemctl stop llm-deadman.timer llm-deadman.service >>"$RES" 2>&1
sudo systemd-run --on-active=25m --unit=llm-deadman docker start "$CTR" >>"$RES" 2>&1
log "dead-man timer set (25 min)"

restore() {
    log "RESTORE (trap): docker start $CTR"
    docker start "$CTR" >>"$RES" 2>&1
    sleep 3
    sudo systemctl stop llm-deadman.timer llm-deadman.service >>"$RES" 2>&1
    log "dead-man timer cancelled"
}
trap restore EXIT

# 2) stop the LLM
docker stop "$CTR" >>"$RES" 2>&1
log "swift15 stopped"

# 3) VRAM pre-check: the last window OOM'd the engine's weight arena because the VRAM did not
#    come back.  Abort and restore instead of running into it.
used=999999
for i in $(seq 1 60); do
    used=$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits | head -1)
    [ "$used" -lt 1024 ] && break
    sleep 2
done
if [ "$used" -ge 1024 ]; then
    log "ABORT: VRAM not released (used=${used} MiB after 120 s) - restoring the LLM"
    exit 1    # trap -> restore
fi
log "VRAM released (used=${used} MiB)"

# 4) deploy the phase-0 binary (build/strata has the 48-layer fix + the phase-0 hardening)
cp build/strata engine/strata
log "deployed build/strata -> engine/strata"

# 5) run the real service path: python server on 8090 (8088 is free - swift15 is stopped), the
#    engine as its child, with the forensics env of the review's phase 0
log_start=$(stat -c %s "$ELOG" 2>/dev/null || echo 0)   # the log is appended across runs: only NEW lines count
env CUDA_LOG_FILE=/home/ai/Strata/tools/repro/cuda-log.txt \
    STRATA_PCIE_REGLOG=/home/ai/Strata/tools/repro/reg-sequence.txt \
    .venv/bin/python serve/server.py --engine strata --config strata-iq3_s.json --port 8090 \
    > "$SLOG" 2>&1 &
sp=$!
log "server starting (pid $sp)"

# 6) wait for readiness: the port answers (any HTTP status counts - the engine's load+register+
#    fill takes a few minutes; 12 min timeout)
ok=0
for i in $(seq 1 360); do
    kill -0 "$sp" 2>/dev/null || { log "server process died early"; break; }
    tail -c +"$log_start" "$ELOG" 2>/dev/null | grep -q 'the profile fill failed' && { log "FILL FAILED - see $ELOG"; break; }
    curl -s -m 2 -o /dev/null "http://127.0.0.1:8090/" && { ok=1; break; }
    sleep 2
done
[ "$ok" = 1 ] && log "server answering on :8090"

# 7) prefill smoke: one ~4k-token prompt, 8 output tokens - the prefill number for plan section 9.5
if [ "$ok" = 1 ]; then
    prompt=$(python3 -c "print(('The quick brown fox jumps over the lazy dog. ' * 10) * 10)")
    curl -s -m 180 "http://127.0.0.1:8090/v1/chat/completions" \
        -H 'Content-Type: application/json' -H "Authorization: Bearer ninfer-local" \
        -d "{\"model\":\"strata\",\"messages\":[{\"role\":\"user\",\"content\":$(python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "$prompt")}],\"max_tokens\":8}" \
        > /home/ai/Strata/tools/repro/smoke-response.json 2>&1
    log "smoke request done ($(wc -c < /home/ai/Strata/tools/repro/smoke-response.json) bytes)"
fi

# 8) the engine's own numbers from its log (this run's lines only)
tail -c +"$log_start" "$ELOG" | grep -E 'PCIe alias|canary|degraded|pre-filled|profile fill|usage seeded|large pages' | tail -10 | tee -a "$RES"
tail -c +"$log_start" "$ELOG" | grep 'prompt .* tokens =' | tail -2 | tee -a "$RES"

# 9) shut the service down (engine + vision child) and wait for the VRAM to come back
pkill -f 'serve/server.py --engine strata' 2>/dev/null
pkill -f 'engine/strata --serve' 2>/dev/null
pkill -f 'strata-vision' 2>/dev/null
for i in $(seq 1 60); do
    used=$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits | head -1)
    [ "$used" -lt 1024 ] && break
    sleep 2
done
log "engine stopped, VRAM used=${used} MiB"

# 10) restore the LLM (the standing rule's explicit step) and verify it is healthy again
trap - EXIT
docker start "$CTR" >>"$RES" 2>&1
log "swift15 started (explicit)"
for i in $(seq 1 90); do
    st=$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}n/a{{end}}' "$CTR" 2>/dev/null)
    [ "$st" = "healthy" ] && { log "8088 healthy"; break; }
    sleep 2
done
sudo systemctl stop llm-deadman.timer llm-deadman.service >>"$RES" 2>&1
log "dead-man cancelled; window closed"
