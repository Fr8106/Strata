#!/bin/bash
# Verify the gap-page registration fix (2026-10-08): the 100K -> 160K sequence that killed the
# P4-B build with #267 at 63 s, now three times with fresh conversations, plus the Option B
# acceptance invariants from the startup block (L0 canary, full fill, real release).
# Closed loop: VRAM pre-check + orphan guard; swift15 left stopped (user: no restore within 8h).
set -u
cd /home/ai/Strata
CTR=NInfer-kaushikvira-swift15
RES=/home/ai/Strata/tools/repro/gapwin-results.txt
SLOG=/home/ai/Strata/tools/repro/gapwin-server.log
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

log_start=$(stat -c %s "$ELOG" 2>/dev/null || echo 0)
.venv/bin/python serve/server.py --engine strata --config strata-iq3_s.json --port $PORT > "$SLOG" 2>&1 &
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
    log "ABORT: engine never came up"; exit 1
fi
log "=== startup invariants (this run) ==="
tail -c +"$log_start" "$ELOG" | grep -E 'tier-ordered layout|PCIe alias registered|canary|pre-filled|handed back|fixed tier:|VRAM free with everything loaded|expert cache [0-9]+ slots' | tee -a "$RES"

for rep in 1 2 3; do
    SEED0=$((100 + 200 * rep)) TIMEOUT=240 CONC=1 .venv/bin/python tools/repro/kv-multi-smoke.py \
        "100000,160000" 1 $PORT 512 "gap-r$rep" 2>&1 | tee -a "$RES"
done

log "=== request evidence (this run) ==="
{
    echo "--- verify timeouts: $(tail -c +"$log_start" "$ELOG" | grep -c 'verify: timed out')"
    echo "--- PCIe share copy failures: $(tail -c +"$log_start" "$ELOG" | grep -c 'PCIe share copy')"
    tail -c +"$log_start" "$ELOG" | grep -E 'prompt [0-9]+ tokens =|KV streaming|verify: timed out|PCIe share copy|conversation cache: parked' | tail -20
} | tee -a "$RES"
{
    echo "=== memory after (idle) ==="
    grep -E 'MemAvailable:|SwapFree:' /proc/meminfo
    echo "vram: $(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits | head -1) MiB"
} | tee -a "$RES"

pkill -f 'serve/server.py --engine strata' 2>/dev/null
pkill -f 'engine/strata' 2>/dev/null
pkill -f 'strata-vision' 2>/dev/null
for i in $(seq 1 60); do
    used=$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits | head -1)
    [ "$used" -lt 1024 ] && break
    sleep 2
done
log "engine stopped (VRAM $used MiB); swift15 left stopped"
