#!/bin/bash
# Capture the verify handshake trace at the moment of the 100K->160K #267 (2026-10-08).
# Runs the failing config (fixed tier + kv-resident 131072) with STRATA_VERIFY_TRACE=1,
# which dumps the last 160 handshake events + the GPU breadcrumbs on the timeout path.
set -u
cd /home/ai/Strata
CTR=NInfer-kaushikvira-swift15
RES=/home/ai/Strata/tools/repro/verifytrace-results.txt
SLOG=/home/ai/Strata/tools/repro/verifytrace-server.log
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

.venv/bin/python - <<'PY'
import json
c = json.load(open("/home/ai/Strata/strata-iq3_s.json"))
c.setdefault("env", {})["STRATA_VERIFY_TRACE"] = "1"
json.dump(c, open("/tmp/verifytrace.json", "w"), indent=2, ensure_ascii=False)
PY
log "config: strata-iq3_s.json + STRATA_VERIFY_TRACE=1"
.venv/bin/python serve/server.py --engine strata --config /tmp/verifytrace.json --port $PORT > "$SLOG" 2>&1 &
sp=$!
ok=0
for i in $(seq 1 400); do
    kill -0 "$sp" 2>/dev/null || { log "server died early"; break; }
    curl -s -m 2 -o /dev/null "http://127.0.0.1:$PORT/" && { ok=1; break; }
    sleep 2
done
log "engine ready (ok=$ok)"
if [ "$ok" != 1 ]; then
    pkill -f 'serve/server.py --engine strata'; pkill -f 'engine/strata'; pkill -f 'strata-vision'
    exit 1
fi
SEED0=1700 TIMEOUT=240 CONC=1 .venv/bin/python tools/repro/kv-multi-smoke.py "100000,160000" 1 $PORT 512 trace 2>&1 | tee -a "$RES"

log "=== verify trace dump (server stderr) ==="
grep -A 170 "strata verify trace" "$SLOG" | head -180 | tee -a "$RES"

pkill -f 'serve/server.py --engine strata' 2>/dev/null
pkill -f 'engine/strata' 2>/dev/null
pkill -f 'strata-vision' 2>/dev/null
for i in $(seq 1 60); do
    used=$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits | head -1)
    [ "$used" -lt 1024 ] && break
    sleep 2
done
log "engine stopped (VRAM $used MiB); swift15 left stopped"
