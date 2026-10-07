#!/bin/bash
# Option B forensics window (2026-10-07): why does the canary L0 HtoD fail with the 96 tier-run
# shape when the 48 per-layer shape passed L0 twice in the same context?
#
# Same closed loop as optionb-win.sh (memory: llm-service-window-rule): dead-man BEFORE the stop,
# explicit `docker start` at the end, trap for the abort paths.  Two engine starts (determinism):
# the 48-run shape passed twice, so one 96-run pass is not proof of anything.
#
# Captures per run: STRATA_PCIE_REGLOG (one line per registration), CUDA_LOG_FILE (driver log),
# the canary line (now with the cudaGetErrorString rc), dmesg NVRM/Xid delta.
set -u
cd /home/ai/Strata
CTR=NInfer-kaushikvira-swift15
RES=/home/ai/Strata/tools/repro/optionb-forensic-results.txt
SLOG=/home/ai/Strata/tools/repro/optionb-forensic-server.log
ELOG=/home/ai/Strata/strata-iq3_s.log
: > "$RES"; : > "$SLOG"
log() { echo "$(date +%T) $*" | tee -a "$RES"; }

# 1) dead-man
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

# 3) VRAM pre-check
used=999999
for i in $(seq 1 60); do
    used=$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits | head -1)
    [ "$used" -lt 1024 ] && break
    sleep 2
done
if [ "$used" -ge 1024 ]; then
    log "ABORT: VRAM not released (used=${used} MiB) - restoring the LLM"
    exit 1
fi
log "VRAM released (used=${used} MiB)"

# 4) deploy the current binary (rc-string canary) - idempotent
cp build/strata engine/strata
log "deployed build/strata -> engine/strata"

dmesg_delta() {  # $1 = label; NVRM/Xid lines since the previous capture
    local base
    base=$(sudo dmesg 2>/dev/null | grep -c 'NVRM\|Xid' || echo 0)
    echo "$1: NVRM/Xid lines so far: $base" | tee -a "$RES"
}
dmesg_delta "pre"

run() {  # $1 = run number
    local n=$1
    local reglog="tools/repro/reglog-run${n}.txt" cudalog="/tmp/cuda-strata-run${n}.log"
    : > "$reglog"
    log_start=$(stat -c %s "$ELOG" 2>/dev/null || echo 0)
    STRATA_PCIE_REGLOG="$PWD/$reglog" CUDA_LOG_FILE="$cudalog" \
        .venv/bin/python serve/server.py --engine strata --config strata-iq3_s.json --port 8090 > "$SLOG" 2>&1 &
    local sp=$!
    log "run $n: server starting (pid $sp)"
    ok=0
    for i in $(seq 1 360); do
        kill -0 "$sp" 2>/dev/null || { log "run $n: server died early"; break; }
        tail -c +"$log_start" "$ELOG" 2>/dev/null | grep -q 'the profile fill failed' && { log "run $n: FILL FAILED"; break; }
        curl -s -m 2 -o /dev/null "http://127.0.0.1:8090/" && { ok=1; break; }
        sleep 2
    done
    [ "$ok" = 1 ] && log "run $n: server answering (canary + fill done)"
    pkill -f 'serve/server.py --engine strata' 2>/dev/null
    pkill -f 'engine/strata --serve' 2>/dev/null
    pkill -f 'strata-vision' 2>/dev/null
    for i in $(seq 1 60); do
        used=$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits | head -1)
        [ "$used" -lt 1024 ] && break
        sleep 2
    done
    if [ "$used" -ge 1024 ]; then  # SIGTERM-resistant child holding the context: escalate
        log "run $n: VRAM not released (used=${used} MiB) - kill -9 fallback"
        pkill -9 -f 'serve/server.py --engine strata' 2>/dev/null
        pkill -9 -f 'engine/strata' 2>/dev/null
        pkill -9 -f 'strata-vision' 2>/dev/null
        for i in $(seq 1 60); do
            used=$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits | head -1)
            [ "$used" -lt 1024 ] && break
            sleep 2
        done
    fi
    log "run $n: engine stopped, VRAM used=${used} MiB"
    {
        echo "=== run $n: registration lines (rc per run) ==="
        awk -F' ' '{print $NF}' "$reglog" | sort | uniq -c | sort -rn | head
        echo "=== run $n: canary / tier lines (this run) ==="
        tail -c +"$log_start" "$ELOG" | grep -E 'tier-ordered layout|PCIe alias|canary|degraded|handed back' | tee -a "$RES"
        echo "=== run $n: CUDA log NVRM/driver lines ==="
        grep -E 'NVRM|Xid|ERROR|fail' "$cudalog" 2>/dev/null | tail -20 | tee -a "$RES"
    }
}

# 5) two starts: determinism of the L0 failure
run 1
run 2
dmesg_delta "post"

# 6) restore the LLM (the standing rule's explicit step)
trap - EXIT
if [ "$used" -ge 1024 ]; then
    log "ABORT: orphan VRAM ${used} MiB - NOT starting the LLM; find the holder with nvidia-smi and kill it"
    sudo systemctl stop llm-deadman.timer llm-deadman.service >>"$RES" 2>&1
    exit 1
fi
docker start "$CTR" >>"$RES" 2>&1
log "swift15 started (explicit)"
# the container defines no docker healthcheck (inspect says n/a): probe 8088 directly (401 = up, needs the key)
for i in $(seq 1 90); do
    code=$(curl -s -m 2 -o /dev/null -w '%{http_code}' "http://127.0.0.1:8088/" 2>/dev/null)
    [ "$code" != "000" ] && { log "8088 answering (HTTP $code)"; break; }
    sleep 2
done
sudo systemctl stop llm-deadman.timer llm-deadman.service >>"$RES" 2>&1
log "dead-man cancelled; forensics window closed"
