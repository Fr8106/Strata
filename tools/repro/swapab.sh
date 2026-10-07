#!/bin/bash
# Expert swap-out counts: whole-cache adaptive (fixed 0 = the original behavior + the new telemetry)
# versus the 50/50 fixed tier (2026-10-08).  Same engine, same workload, only --expert-cache-fixed differs.
# The pre-P2 binary has no serve-side swap telemetry at all, so fixed=0 on the current build is the closest
# measurable stand-in for the original mechanism.
set -u
cd /home/ai/Strata
CTR=NInfer-kaushikvira-swift15
RES=/home/ai/Strata/tools/repro/swapab-results.txt
SLOG=/home/ai/Strata/tools/repro/swapab-server.log
ELOG=/home/ai/Strata/strata-iq3_s.log
PORT=8090
: > "$RES"; : > "$SLOG"
log() { echo "$(date +%T) $*" | tee -a "$RES"; }

docker stop "$CTR" >>"$RES" 2>&1 || true
used=999999
for i in $(seq 1 60); do
    used=$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits | head -1)
    [ "$used" -lt 1024 ] && break
    sleep 2
done
[ "$used" -ge 1024 ] && { log "ABORT: VRAM ${used} MiB"; exit 1; }
log "VRAM released (used=${used} MiB)"
sync; sudo sh -c 'echo 3 > /proc/sys/vm/drop_caches' 2>>"$RES"

stop_arm() {
    pkill -f 'serve/server.py --engine strata' 2>/dev/null
    pkill -f 'engine/strata' 2>/dev/null
    pkill -f 'strata-vision' 2>/dev/null
    used=999999
    for i in $(seq 1 60); do
        used=$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits | head -1)
        [ "$used" -lt 1024 ] && break
        sleep 2
    done
    if [ "$used" -ge 1024 ]; then
        pkill -9 -f 'serve/server.py --engine strata' 2>/dev/null
        pkill -9 -f 'engine/strata' 2>/dev/null
        pkill -9 -f 'strata-vision' 2>/dev/null
        for i in $(seq 1 60); do
            used=$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits | head -1)
            [ "$used" -lt 1024 ] && break
            sleep 2
        done
    fi
    for i in $(seq 1 30); do ss -ltn 2>/dev/null | grep -q ":$PORT " || break; sleep 1; done
    log "engine stopped (VRAM $used MiB)"
}

run_arm() {   # $1 = fixed0|fixed50, $2 = seed
    .venv/bin/python - "$1" "/tmp/swap-$1.json" <<'PY'
import json, sys
c = json.load(open("/home/ai/Strata/strata-iq3_s.json"))
a = c["args"]
i = a.index("--expert-cache-fixed")
if sys.argv[1] == "fixed0":
    del a[i:i+2]
json.dump(c, open(sys.argv[2], "w"), indent=2, ensure_ascii=False)
PY
    log_start=$(stat -c %s "$ELOG" 2>/dev/null || echo 0)
    .venv/bin/python serve/server.py --engine strata --config "/tmp/swap-$1.json" --port $PORT > "$SLOG" 2>&1 &
    sp=$!
    ok=0
    for i in $(seq 1 400); do
        kill -0 "$sp" 2>/dev/null || { log "[$1] server died early"; break; }
        curl -s -m 2 -o /dev/null "http://127.0.0.1:$PORT/" && { ok=1; break; }
        sleep 2
    done
    [ "$ok" != 1 ] && { log "[$1] NOT ready"; stop_arm; return 1; }
    tail -c +"$log_start" "$ELOG" | grep -E 'expert cache [0-9]+ slots|fixed tier: [0-9]+|fixed tier per layer|the prompt loan is capped|adaptive tier:' | head -4 | tee -a "$RES"
    log "[$1] engine ready"
    SEED0=$2 TIMEOUT=240 CONC=1 .venv/bin/python tools/repro/kv-multi-smoke.py "20000,20000,20000" 1 $PORT 512 "$1" 2>&1 | tail -4 | tee -a "$RES"
    log "=== [$1] swap telemetry (this run) ==="
    {
        tail -c +"$log_start" "$ELOG" | grep -oE 'round [0-9]+ swapped [0-9]+' | awk '{r=$2; s=$4; n++; tot+=s; if (s>mx) mx=s} END {printf "adapt rounds: %d, swaps total: %d, avg/round: %.1f, max/round: %d\n", n, tot, (n?tot/n:0), mx}'
        tail -c +"$log_start" "$ELOG" | grep -E 'no-victim' | tail -1
        tail -c +"$log_start" "$ELOG" | grep 'expert tiers this round' | awk -F'[ %,]+' '{f+=$4; a+=$6; m+=$8; n++} END {printf "tier shares (avg): fixed %.1f%% adaptive %.1f%% miss %.1f%%\n", f/n, a/n, m/n}'
        tail -c +"$log_start" "$ELOG" | grep -E 'expert cache hit rate' | tail -1
        tail -c +"$log_start" "$ELOG" | grep -E 'prompt [0-9]+ tokens =' | tail -3
    } | tee -a "$RES"
    stop_arm
}

run_arm fixed0  3100
run_arm fixed50 4100
log "window closed; swift15 left stopped"
