#!/bin/bash
# T7-3 night soak (docs/HARDENING-PLAN-2026-10-08.md): >=30 sequences against the LIVE strata.service
# (:8088) - the target IS production, nothing is stopped.  Metrics = the acceptance table: verify
# timeouts, new Xids, bounce-line delta, geometry bad=0 on any restart, MemAvailable floor (8 GiB line).
# 12 rounds x 3 sizes = 36 sequences (~15 min of load; ROUNDS= to go longer).
set -u
cd /home/ai/Strata
RES=tools/repro/night-soak-results.txt
ELOG=strata-iq3_s.log
PORT=8088
ROUNDS=${ROUNDS:-12}
: > "$RES"
log(){ echo "$(date '+%m-%d %T') $*" | tee -a "$RES"; }
xid0=$(sudo dmesg 2>/dev/null | grep -c 'Xid'); vt0=$(grep -c 'verify: timed out' "$ELOG"); bn0=$(grep -c 'bounced a refused' "$ELOG"); geo0=$(grep -c 'geometry:' "$ELOG")
log "soak start: rounds=$ROUNDS xids=$xid0 verify-timeouts=$vt0 bounce-lines=$bn0 geometry-lines=$geo0"
min_mem=$(awk '/MemAvailable/{print $2}' /proc/meminfo)
restarts=0
for r in $(seq 1 "$ROUNDS"); do
    if ! curl -sf -m 5 "http://127.0.0.1:$PORT/health" >/dev/null; then
        log "round $r: service not answering - systemctl restart strata"
        sudo systemctl restart strata; restarts=$((restarts+1))
        for i in $(seq 1 100); do curl -sf -m 5 "http://127.0.0.1:$PORT/health" >/dev/null && break; sleep 3; done
    fi
    # a fresh SEED0 per round: the prompts differ -> no conversation-cache hit -> every round is a
    # cold 32K/100K/160K prefill sweep, the shape #267's sequence died on (a constant prompt would
    # make rounds 2..N pure parked-cache restores: 2.8-4.0 s each, the prefill path untested).
    SEED0=$((1000 + r * 8)) TIMEOUT=240 CONC=1 .venv/bin/python tools/repro/kv-multi-smoke.py "32000,100000,160000" 1 $PORT 512 "soak-r$r" 2>&1 | grep -E 'OK|FAIL|completed' | tee -a "$RES"
    mem=$(awk '/MemAvailable/{print $2}' /proc/meminfo); [ "$mem" -lt "$min_mem" ] && min_mem=$mem
    vt=$(grep -c 'verify: timed out' "$ELOG"); xid=$(sudo dmesg 2>/dev/null | grep -c 'Xid')
    log "round $r: verify-timeouts=$((vt-vt0)) new-xids=$((xid-xid0)) MemAvail-min=$((min_mem/1048576))GiB"
    if [ "$((vt-vt0))" -gt 0 ] || [ "$((xid-xid0))" -gt 0 ]; then
        log "ABORT: a timeout or Xid appeared - stopping the soak, evidence in $ELOG + dmesg"
        break
    fi
done
vt=$(grep -c 'verify: timed out' "$ELOG"); xid=$(sudo dmesg 2>/dev/null | grep -c 'Xid'); bn=$(grep -c 'bounced a refused' "$ELOG")
bad=$(grep 'geometry:' "$ELOG" | grep -c 'bad=[1-9]')
log "SOAK DONE rounds=$ROUNDS restarts=$restarts verify-timeouts=$((vt-vt0)) new-xids=$((xid-xid0)) bounce-lines=+$((bn-bn0)) geometry-bad-lines=$bad MemAvail-min=$((min_mem/1048576))GiB"
