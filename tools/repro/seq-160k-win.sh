#!/bin/bash
# Sequence/state versus size: WHY do 130K/160K requests fail after other large requests,
# when a single 160K on a fresh engine runs fine on both builds? (2026-10-08)
#   arm fresh130      : current build, SINGLE 130K on a fresh engine        (size hypothesis)
#   arm after100-160  : current build, 100K then 160K, strictly sequential  (state hypothesis)
#   arm p0-after100-160: P0 build+config, same sequence                     (did the change matter?)
# Closed loop: VRAM pre-check + orphan guard; swift15 left stopped (user: no restore within 8h).
set -u
cd /home/ai/Strata
CTR=NInfer-kaushikvira-swift15
RES=/home/ai/Strata/tools/repro/seq-160k-results.txt
SLOG=/home/ai/Strata/tools/repro/seq-160k-server.log
ELOG=/home/ai/Strata/strata-iq3_s.log
PORT=8090
[ "${ONLY_ARM:-all}" = all ] && { : > "$RES"; : > "$SLOG"; }
log() { echo "$(date +%T) $*" | tee -a "$RES"; }

docker stop "$CTR" >>"$RES" 2>&1 || true
log "swift15 stopped (if it was up)"

used=999999
for i in $(seq 1 60); do
    used=$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits | head -1)
    [ "$used" -lt 1024 ] && break
    sleep 2
done
if [ "$used" -ge 1024 ]; then log "ABORT: VRAM not released (used=${used} MiB)"; exit 1; fi
log "VRAM released (used=${used} MiB)"
sync; sudo sh -c 'echo 3 > /proc/sys/vm/drop_caches' 2>>"$RES"
log "page cache dropped ($(grep MemAvailable /proc/meminfo | awk '{print $2/1048576" GiB"}'))"

snap() {
    { echo "=== memory: $1 ($(date +%T)) ==="
      grep -E 'MemAvailable:|SwapFree:' /proc/meminfo
      echo "vram: $(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits | head -1) MiB"
    } | tee -a "$RES"
}

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
    log "engine stopped (VRAM $used MiB)"
    for i in $(seq 1 30); do ss -ltn 2>/dev/null | grep -q ":$PORT " || break; sleep 1; done
}

run_arm() {   # $1 label, $2 config source, $3 exe, $4 sizes (comma list)
    .venv/bin/python - "$2" "$3" "/tmp/$1-seq.json" <<'PY'
import json, sys
c = json.load(open(sys.argv[1])); c["exe"] = sys.argv[2]
json.dump(c, open(sys.argv[3], "w"), indent=2, ensure_ascii=False)
PY
    log "[$1] exe=$3 sizes=$4"
    log_start=$(stat -c %s "$ELOG" 2>/dev/null || echo 0)
    .venv/bin/python serve/server.py --engine strata --config "/tmp/$1-seq.json" --port $PORT > "$SLOG" 2>&1 &
    sp=$!
    ok=0
    for i in $(seq 1 400); do
        kill -0 "$sp" 2>/dev/null || { log "[$1] server died early"; break; }
        curl -s -m 2 -o /dev/null "http://127.0.0.1:$PORT/" && { ok=1; break; }
        sleep 2
    done
    if [ "$ok" != 1 ]; then log "[$1] engine NOT ready - skipping"; stop_arm; return 1; fi
    log "[$1] engine ready"
    TIMEOUT=240 CONC=1 .venv/bin/python tools/repro/kv-multi-smoke.py "$4" 1 $PORT 512 "$1" 2>&1 | tee -a "$RES"
    log "=== [$1] engine evidence (this arm) ==="
    {
        echo "--- verify timeouts: $(tail -c +"$log_start" "$ELOG" | grep -c 'verify: timed out')"
        tail -c +"$log_start" "$ELOG" | grep -E 'prompt [0-9]+ tokens =|KV streaming|verify: timed out|expert cache [0-9]+ slots|VRAM free with everything loaded|OVERFLOW|conversation cache: parked' | tail -14
    } | tee -a "$RES"
    snap "[$1] post"
    stop_arm
    return 0
}

ONLY=${ONLY_ARM:-all}   # ONLY_ARM=p0 reruns just the P0 arm
if [ "$ONLY" = all ] || [ "$ONLY" = fresh130 ]; then
    run_arm fresh130       strata-iq3_s.json           /home/ai/Strata/engine/strata           "130000"
fi
if [ "$ONLY" = all ] || [ "$ONLY" = cur ]; then
    run_arm after100-160   strata-iq3_s.json           /home/ai/Strata/engine/strata           "100000,160000"
fi
if [ "$ONLY" = all ] || [ "$ONLY" = p0 ]; then
    run_arm p0-after100-160 strata-iq3_s.json.p0-backup /home/ai/Strata/engine/strata.pre-p2   "100000,160000"
fi
log "window closed; swift15 left stopped (user: no restore within 8h)"
