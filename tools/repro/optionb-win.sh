#!/bin/bash
# Option B (P4-B, plan 9.6) verification window (2026-10-07): deploy the tier-ordered-arena binary,
# verify the new log lines (tier layout + tier runs + real fixed-tier release), a 32K prefill tier,
# and the memory numbers (peak MemAvailable vs the 8 GiB safety line).  Then RESTORE the LLM.
#
# Same closed loop as ab-win.sh (memory: llm-service-window-rule): dead-man BEFORE the stop,
# explicit `docker start` at the end, trap for the abort paths.
set -u
cd /home/ai/Strata
CTR=NInfer-kaushikvira-swift15
RES=/home/ai/Strata/tools/repro/optionb-results.txt
SLOG=/home/ai/Strata/tools/repro/optionb-server.log
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

# 4) deploy the P4-B binary - idempotent
cp build/strata engine/strata
log "deployed build/strata -> engine/strata"

# 5) start the service on 8090
log_start=$(stat -c %s "$ELOG" 2>/dev/null || echo 0)
.venv/bin/python serve/server.py --engine strata --config strata-iq3_s.json --port 8090 > "$SLOG" 2>&1 &
sp=$!
log "server starting (pid $sp)"

ok=0
for i in $(seq 1 360); do
    kill -0 "$sp" 2>/dev/null || { log "server process died early"; break; }
    tail -c +"$log_start" "$ELOG" 2>/dev/null | grep -q 'the profile fill failed' && { log "FILL FAILED"; break; }
    curl -s -m 2 -o /dev/null "http://127.0.0.1:8090/" && { ok=1; break; }
    sleep 2
done
[ "$ok" = 1 ] && log "server answering on :8090"

snap() {
    {
        echo "=== memory: $1 ($(date +%T)) ==="
        grep -E 'MemAvailable:|SwapFree:|Unevictable:|AnonHugePages:' /proc/meminfo
        head -1 /proc/pressure/memory
        echo "vram: $(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits | head -1) MiB"
        ep=$(pgrep -f 'engine/strata --serve' | head -1)
        [ -n "$ep" ] && grep -E 'VmRSS|VmPin' "/proc/$ep/status"
    } | tee -a "$RES"
}

if [ "$ok" = 1 ]; then
    sleep 10
    snap "post-startup (idle, after the fixed-tier release)"
    # 6) warmup + one 32K tier (three rounds, the A/B's acceptance tier)
    .venv/bin/python - "$RES" <<'PYEOF'
import json, random, sys, time, urllib.request

RES = sys.argv[1]
BASE = "http://127.0.0.1:8090"

def words(n, seed):
    rng = random.Random(seed)
    vocab = ("the of and a in that it was to be is are for with as his they had i he she you "
             "not have at from by one this we but what their all when who they can there "
             "will would could should each some than which or if into about out off over "
             "under again then so both up down out now no yes maybe often always never "
             "new old good big small large small first last next right left time day year "
             "work home school money power water earth light sound music color name word "
             "story problem question answer thought feeling moment way world life people "
             "city road river mountain valley field house room door window table chair "
             "book pen paper desk window glass metal wood stone fire ice wind rain snow").split()
    return " ".join(rng.choice(vocab) for _ in range(n))

def req(content, max_tokens):
    body = json.dumps({"model": "strata",
                      "messages": [{"role": "user", "content": content}],
                      "max_tokens": max_tokens}).encode()
    r = urllib.request.Request(BASE + "/v1/chat/completions", data=body,
                               headers={"Content-Type": "application/json",
                                        "Authorization": "Bearer ninfer-local"})
    t0 = time.time()
    with urllib.request.urlopen(r, timeout=600) as f:
        data = f.read()
    return time.time() - t0, data

for i, (tier, n, mt) in enumerate([("warmup", 1000, 16)] * 3 + [("32K", 32000, 128)] * 3):
    dt, data = req(words(n, 2000 + i), mt)
    note = json.loads(data.decode()).get("usage", {}) if data else {}
    with open(RES, "a") as f:
        f.write(f"req {i:02d} {tier}: {dt:.1f}s wall, usage={note}\n")
PYEOF
    snap "post-32K-tier (peak)"
fi

# 7) the Option B acceptance lines (this run only)
log "=== P4-B lines (this run) ==="
tail -c +"$log_start" "$ELOG" | grep -E 'tier-ordered layout|PCIe alias|canary|handed back|fixed-tier expert|pre-filled|usage seeded' | tee -a "$RES"
log "=== engine per-request lines (this run) ==="
tail -c +"$log_start" "$ELOG" | grep 'prompt .* tokens =' | tee -a "$RES"
log "=== tier telemetry (this run) ==="
tail -c +"$log_start" "$ELOG" | grep -E 'fixed|swaps|adapt' | tail -6 | tee -a "$RES"

# 8) shut down, wait for VRAM
pkill -f 'serve/server.py --engine strata' 2>/dev/null
pkill -f 'engine/strata --serve' 2>/dev/null
pkill -f 'strata-vision' 2>/dev/null
for i in $(seq 1 60); do
    used=$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits | head -1)
    [ "$used" -lt 1024 ] && break
    sleep 2
done
if [ "$used" -ge 1024 ]; then
    # a SIGTERM-resistant child (or a forked vision process) is holding the context: escalate, then re-check
    log "VRAM not released after SIGTERM (used=${used} MiB) - kill -9 fallback"
    pkill -9 -f 'serve/server.py --engine strata' 2>/dev/null
    pkill -9 -f 'engine/strata' 2>/dev/null
    pkill -9 -f 'strata-vision' 2>/dev/null
    for i in $(seq 1 60); do
        used=$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits | head -1)
        [ "$used" -lt 1024 ] && break
        sleep 2
    done
fi
log "engine stopped, VRAM used=${used} MiB"

# 9) restore the LLM (the standing rule's explicit step)
trap - EXIT
if [ "$used" -ge 1024 ]; then
    # an orphaned CUDA context would leave the LLM without VRAM (it cannot start on top of 4 GiB of
    # leftovers on this 32 GB card): leave it for manual cleanup instead of stacking a broken LLM on it
    log "ABORT: orphan VRAM ${used} MiB - NOT starting the LLM; find the holder with nvidia-smi and kill it"
    sudo systemctl stop llm-deadman.timer llm-deadman.service >>"$RES" 2>&1
    exit 1
fi
docker start "$CTR" >>"$RES" 2>&1
log "swift15 started (explicit)"
for i in $(seq 1 90); do
    st=$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}n/a{{end}}' "$CTR" 2>/dev/null)
    [ "$st" = "healthy" ] && { log "8088 healthy"; break; }
    sleep 2
done
sudo systemctl stop llm-deadman.timer llm-deadman.service >>"$RES" 2>&1
log "dead-man cancelled; Option B window closed"
