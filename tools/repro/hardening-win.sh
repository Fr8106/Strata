#!/bin/bash
# Hardening window (docs/HARDENING-PLAN-2026-10-08.md): the three measurements that need the GPU to
# itself, in one closed loop.  The live LLM service (strata.service :8088) is stopped for the window
# and RESTORED at the end and on every abort path (the dead-man trap).
#   1. t18: the copy-semantics matrix over registration geometries (T4) - the assumption register's blanks
#   2. baseline: seq 32K/100K/160K on the hardened build (T1) - prefill/decode must not regress, and the
#      geometry/no-alias/bounce lines are the new telemetry's first real output
#   3. injection: same sequence with STRATA_FORCE_NOALIAS_PCT=5 (T7-2) - every pinned()==false consumer
#      exercised on one run; a pass here plus a sane noalias count decides T5
# Closed loop: VRAM pre-check, orphan guard (kill -9 then ABORT), dead-man restores swift15.
set -u
cd /home/ai/Strata
RES=/home/ai/Strata/tools/repro/hardening-win-results.txt
SLOG=/home/ai/Strata/tools/repro/hardening-win-server.log
ELOG=/home/ai/Strata/strata-iq3_s.log
PORT=8090
: > "$RES"; : > "$SLOG"
log() { echo "$(date +%T) $*" | tee -a "$RES"; }
SVC=0
deadman() {   # any exit path: the LLM service must be back up before this script says goodbye
    if [ "$SVC" = 1 ]; then
        sudo systemctl start strata >>"$RES" 2>&1 || log "DEAD-MAN FAILED: systemctl start strata - bring it up by hand"
        SVC=0
        log "strata.service restored (dead-man)"
    fi
}
trap deadman EXIT INT TERM

# As of 2026-10-08 the LIVE LLM service IS strata.service (:8088, holds ~32 GiB VRAM); swift15's
# container is already down (it is not started by this window).  The window stops the service,
# measures, and the dead-man starts it again.
if systemctl is-active --quiet strata.service 2>/dev/null; then
    SVC=1
    sudo systemctl stop strata >>"$RES" 2>&1 || { log "ABORT: could not stop strata.service"; exit 1; }
    log "strata.service stopped (it will be restarted by the dead-man on any exit path)"
fi
log "=== memory: pre ($(grep MemAvailable /proc/meminfo | awk '{print $2/1048576" GiB"}') avail) ==="
used=999999
for i in $(seq 1 60); do
    used=$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits | head -1)
    [ "$used" -lt 1024 ] && break
    sleep 2
done
if [ "$used" -ge 1024 ]; then log "ABORT: VRAM not released (used=${used} MiB) - dead-man will restore swift15"; exit 1; fi
log "VRAM released (used=${used} MiB)"
sync; sudo sh -c 'echo 3 > /proc/sys/vm/drop_caches' 2>>"$RES"
log "page cache dropped ($(grep MemAvailable /proc/meminfo | awk '{print $2/1048576" GiB"}') avail)"

# ---- 1. t18: the probe matrix (needs ~2 GiB VRAM, runs before the engine) ----
log "=== t18 probe matrix ==="
./tools/repro/t18 2>&1 | tee -a "$RES" | tee tools/repro/probe-matrix-results.txt >/dev/null
log "t18 done -> tools/repro/probe-matrix-results.txt"

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
        log "engine VRAM not released after SIGTERM (used=${used} MiB) - kill -9"
        pkill -9 -f 'serve/server.py --engine strata' 2>/dev/null
        pkill -9 -f 'engine/strata' 2>/dev/null
        pkill -9 -f 'strata-vision' 2>/dev/null
        for i in $(seq 1 60); do
            used=$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits | head -1)
            [ "$used" -lt 1024 ] && break
            sleep 2
        done
    fi
    if [ "$used" -ge 1024 ]; then log "ABORT: orphan VRAM (used=${used} MiB) after kill -9"; exit 1; fi
    log "engine stopped (VRAM $used MiB)"
    for i in $(seq 1 30); do ss -ltn 2>/dev/null | grep -q ":$PORT " || break; sleep 1; done
}

run_arm() {   # $1 label, $2 extra env assignments as "NAME=VAL ..."
    log "[$1] seq 32000,100000,160000 ${2:-env: none}"
    log_start=$(stat -c %s "$ELOG" 2>/dev/null || echo 0)
    env $2 .venv/bin/python serve/server.py --engine strata --config strata-iq3_s.json --port $PORT > "$SLOG" 2>&1 &
    sp=$!
    ok=0
    for i in $(seq 1 400); do
        kill -0 "$sp" 2>/dev/null || { log "[$1] server died early"; break; }
        curl -s -m 2 -o /dev/null "http://127.0.0.1:$PORT/" && { ok=1; break; }
        sleep 2
    done
    if [ "$ok" != 1 ]; then log "[$1] engine NOT ready"; stop_arm; return 1; fi
    log "[$1] engine ready"
    TIMEOUT=240 CONC=1 .venv/bin/python tools/repro/kv-multi-smoke.py "32000,100000,160000" 1 $PORT 512 "$1" 2>&1 | tee -a "$RES"
    log "=== [$1] engine evidence ==="
    {
        echo "--- verify timeouts: $(tail -c +"$log_start" "$ELOG" | grep -c 'verify: timed out')"
        tail -c +"$log_start" "$ELOG" | grep -E 'geometry:|no PCIe alias|bounced a refused|prompt [0-9]+ tokens =|decode [0-9.]+ tok|expert cache [0-9]+ slots|OVERFLOW' | tail -20
    } | tee -a "$RES"
    grep -E 'MemAvailable:' /proc/meminfo | head -1 | tee -a "$RES"
    stop_arm
    return 0
}

# ---- 2. baseline: the hardened build, straight config ----
run_arm baseline ""

# ---- 3. injection: 5% of blobs lose their alias on purpose (T7-2 exercising T7-1's sensor) ----
run_arm noalias5 "STRATA_FORCE_NOALIAS_PCT=5"

log "=== window closed; restoring strata.service ==="
deadman
log "results: $RES"
