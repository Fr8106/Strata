#!/bin/bash
# Bisect the 100K->160K #267 trigger (2026-10-08): the current config always dies; P0 does not.
#   arm fixed0 : drop --expert-cache-fixed  -> no fixed tier, no tier layout, no selective alias/release
#   arm kvres32: keep 50/50, set --kv-resident 32768 (the P0 KV window)
# Each arm: fresh engine + one 100K->160K sequence (CONC=1).  Closed loop: no LLM restore (user: 8h).
set -u
cd /home/ai/Strata
CTR=NInfer-kaushikvira-swift15
RES=/home/ai/Strata/tools/repro/discrim-results.txt
SLOG=/home/ai/Strata/tools/repro/discrim-server.log
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
if [ "$used" -ge 1024 ]; then log "ABORT: VRAM not released (used=${used} MiB)"; exit 1; fi
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

run_arm() {   # $1 label, $2 python-args-edit code, $3 seed0
    .venv/bin/python - "$2" "/tmp/discrim-$1.json" <<'PY'
import json, sys
code = sys.argv[1]
c = json.load(open("/home/ai/Strata/strata-iq3_s.json"))
a = c["args"]
if code == "fixed0":
    i = a.index("--expert-cache-fixed"); del a[i:i+2]
elif code == "kvres32":
    i = a.index("--kv-resident"); a[i+1] = "32768"
json.dump(c, open(sys.argv[2], "w"), indent=2, ensure_ascii=False)
PY
    log "[$1] edit=$2 -> $(grep -A1 '"--kv-resident"' /tmp/discrim-$1.json | tail -1 | tr -d ' ",')"
    log_start=$(stat -c %s "$ELOG" 2>/dev/null || echo 0)
    .venv/bin/python serve/server.py --engine strata --config "/tmp/discrim-$1.json" --port $PORT > "$SLOG" 2>&1 &
    sp=$!
    ok=0
    for i in $(seq 1 400); do
        kill -0 "$sp" 2>/dev/null || { log "[$1] server died early"; break; }
        curl -s -m 2 -o /dev/null "http://127.0.0.1:$PORT/" && { ok=1; break; }
        sleep 2
    done
    if [ "$ok" != 1 ]; then log "[$1] engine NOT ready"; stop_arm; return 1; fi
    log "[$1] engine ready"
    tail -c +"$log_start" "$ELOG" | grep -E 'tier-ordered layout|PCIe alias|pre-filled|handed back|fixed tier:|expert cache [0-9]+ slots|VRAM free' | tee -a "$RES"
    SEED0=$3 TIMEOUT=240 CONC=1 .venv/bin/python tools/repro/kv-multi-smoke.py "100000,160000" 1 $PORT 512 "$1" 2>&1 | tee -a "$RES"
    tail -c +"$log_start" "$ELOG" | grep -E 'prompt [0-9]+ tokens =' | tail -2 | tee -a "$RES"
    stop_arm
}

run_arm fixed0  fixed0  1000
run_arm kvres32 kvres32 1300
log "window closed; swift15 left stopped"
