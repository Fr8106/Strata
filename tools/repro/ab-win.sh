#!/bin/bash
# Steady-state A/B window (2026-10-07): warmup + 1K/8K/32K prefill tiers (3 rounds each, medians) +
# decode + memory snapshots, for plan section 9.5's acceptance numbers.
#
# Same closed loop as verify-win.sh (memory: llm-service-window-rule): dead-man BEFORE the stop,
# explicit `docker start` at the end, trap for the abort paths.
set -u
cd /home/ai/Strata
CTR=NInfer-kaushikvira-swift15
RES=/home/ai/Strata/tools/repro/ab-results.txt
SLOG=/home/ai/Strata/tools/repro/ab-server.log
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

# 4) (re)deploy the phase-0 binary - idempotent
cp build/strata engine/strata

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
    snap "post-startup (idle)"
    # 6) warmup + tiers.  Random-word prompts (seeded, no repeated sentences - BPE collapses those,
    #    the 19:26 smoke's 3600 words came out to only 1052 tokens).  The engine log reports the
    #    exact token counts and tok/s; the tiers are ~1K/8K/32K words.
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

seq = [("warmup", 1000, 16)] * 3 + [("1K", 1000, 32)] * 3 + [("8K", 8000, 32)] * 3 + [("32K", 32000, 128)] * 3
for i, (tier, n, mt) in enumerate(seq):
    dt, data = req(words(n, 1000 + i), mt)
    note = json.loads(data.decode()).get("usage", {}) if data else {}
    with open(RES, "a") as f:
        f.write(f"req {i:02d} {tier}: {dt:.1f}s wall, usage={note}\n")
PYEOF
    snap "post-32K-tier (peak)"
fi

# 7) the numbers: the engine's own per-request lines (this run only), grouped by tier
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
log "engine stopped, VRAM used=${used} MiB"

# 9) restore the LLM (the standing rule's explicit step)
trap - EXIT
docker start "$CTR" >>"$RES" 2>&1
log "swift15 started (explicit)"
for i in $(seq 1 90); do
    st=$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}n/a{{end}}' "$CTR" 2>/dev/null)
    [ "$st" = "healthy" ] && { log "8088 healthy"; break; }
    sleep 2
done
sudo systemctl stop llm-deadman.timer llm-deadman.service >>"$RES" 2>&1
log "dead-man cancelled; A/B window closed"
