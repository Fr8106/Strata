#!/bin/bash
# P0-original versus current: how does ONE 160K-token prompt run? (2026-10-08)
#   arm p0 : engine/strata.pre-p2 + strata-iq3_s.json.p0-backup  (kv-resident 32768, no 50/50, no tier arena)
#   arm p4b: engine/strata          + strata-iq3_s.json           (kv-resident 131072, 50/50 + tier arena)
# Closed loop: VRAM pre-check + orphan guard; swift15 is left stopped (user: no restore within 8h).
set -u
cd /home/ai/Strata
CTR=NInfer-kaushikvira-swift15
RES=/home/ai/Strata/tools/repro/p0-160k-results.txt
SLOG=/home/ai/Strata/tools/repro/p0-160k-server.log
ELOG=/home/ai/Strata/strata-iq3_s.log
PORT=8090
: > "$RES"; : > "$SLOG"
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
}

run_arm() {   # $1 label, $2 config source, $3 exe
    .venv/bin/python - "$2" "$3" "/tmp/$1-160k.json" <<'PY'
import json, sys
c = json.load(open(sys.argv[1])); c["exe"] = sys.argv[2]
json.dump(c, open(sys.argv[3], "w"), indent=2, ensure_ascii=False)
PY
    log "[$1] exe=$3 kv-resident=$(grep -A1 '"--kv-resident"' "/tmp/$1-160k.json" | tail -1 | tr -d ' ",')"
    log_start=$(stat -c %s "$ELOG" 2>/dev/null || echo 0)
    .venv/bin/python serve/server.py --engine strata --config "/tmp/$1-160k.json" --port $PORT > "$SLOG" 2>&1 &
    sp=$!
    ok=0
    for i in $(seq 1 400); do
        kill -0 "$sp" 2>/dev/null || { log "[$1] server died early"; break; }
        curl -s -m 2 -o /dev/null "http://127.0.0.1:$PORT/" && { ok=1; break; }
        sleep 2
    done
    if [ "$ok" != 1 ]; then log "[$1] engine NOT ready - skipping the request"; stop_arm; return 1; fi
    log "[$1] engine ready"
    snap "[$1] idle"
    TIMEOUT=480 .venv/bin/python tools/repro/kv-multi-smoke.py 160000 1 $PORT 512 "$1" 2>&1 | tee -a "$RES"
    snap "[$1] post-request"
    log "=== [$1] engine evidence (this arm) ==="
    {
        echo "--- verify timeouts: $(tail -c +"$log_start" "$ELOG" | grep -c 'verify: timed out')"
        tail -c +"$log_start" "$ELOG" | grep -E 'prompt [0-9]+ tokens =|KV streaming|verify: timed out|expert cache [0-9]+ slots|pre-filled|fixed tier:|handed back|VRAM free with everything loaded|OVERFLOW' | tail -20
    } | tee -a "$RES"
    stop_arm
    return 0
}

run_arm p0  strata-iq3_s.json.p0-backup /home/ai/Strata/engine/strata.pre-p2
run_arm p4b strata-iq3_s.json           /home/ai/Strata/engine/strata
log "window closed; swift15 left stopped (user: no restore within 8h)"
