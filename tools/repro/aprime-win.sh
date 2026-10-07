#!/bin/bash
# A' control window (2026-10-07 late): is the verify timeout triggered by the concurrent
# live-KV total?  Arm 1 keeps the failing setting (--conversation-cache-mib 6144: two ~120K
# conversations can be live at once); Arm 2 sets A' (3072: only one fits).  Same binary
# (P4-B), same workload (tools/repro/kv-multi-smoke.py: N conversations sent in parallel,
# R rounds).  Workload knobs via the environment: W_SIZES / W_ROUNDS / W_MAXTOK.
# First run (2 x 100K, 2 rounds, 16 out tokens) did NOT reproduce at 6144 (see
# aprime-results.txt), so both arms passed - rerun with a stronger workload.
# Closed loop per the standing rule (memory: llm-service-window-rule):
# dead-man BEFORE the stop, explicit `docker start` at the end, trap for the abort paths.
set -u
cd /home/ai/Strata
CTR=NInfer-kaushikvira-swift15
RES=/home/ai/Strata/tools/repro/aprime-results.txt
SLOG=/home/ai/Strata/tools/repro/aprime-server.log
ELOG=/home/ai/Strata/strata-iq3_s.log
CFG=/home/ai/Strata/strata-iq3_s.json
BAK=/tmp/strata-iq3_s.json.aprime-backup
PORT=8090
# workload knobs (override from the environment for a stronger reproduction)
W_SIZES=${W_SIZES:-100000,100000}
W_ROUNDS=${W_ROUNDS:-2}
W_MAXTOK=${W_MAXTOK:-16}
: > "$RES"; : > "$SLOG"
log() { echo "$(date +%T) $*" | tee -a "$RES"; }
cp "$CFG" "$BAK"

set_conv_cache() { sed -i "/\"--conversation-cache-mib\"/{n;s/\"[0-9]*\"/\"$1\"/}" "$CFG"; }

# 1) dead-man
sudo systemctl stop llm-deadman.timer llm-deadman.service >>"$RES" 2>&1
sudo systemd-run --on-active=30m --unit=llm-deadman docker start "$CTR" >>"$RES" 2>&1
log "dead-man timer set (30 min)"

restore() {
    cp "$BAK" "$CFG"
    log "RESTORE (trap): config restored, docker start $CTR"
    docker start "$CTR" >>"$RES" 2>&1
    sleep 3
    sudo systemctl stop llm-deadman.timer llm-deadman.service >>"$RES" 2>&1
}
trap restore EXIT

# 2) stop the LLM
docker stop "$CTR" >>"$RES" 2>&1
log "swift15 stopped"

# 3) VRAM pre-check (+ page cache: the 46.84 GiB pin needs real RAM headroom)
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

start_arm() {   # $1 = arm label, $2 = conversation-cache MiB
    set_conv_cache "$2"
    log_start=$(stat -c %s "$ELOG" 2>/dev/null || echo 0)
    .venv/bin/python serve/server.py --engine strata --config strata-iq3_s.json --port $PORT > "$SLOG" 2>&1 &
    sp=$!
    ok=0
    for i in $(seq 1 400); do
        kill -0 "$sp" 2>/dev/null || { log "[$1] server died early"; break; }
        tail -c +"$log_start" "$ELOG" 2>/dev/null | grep -q 'the profile fill failed' && { log "[$1] FILL FAILED"; break; }
        curl -s -m 2 -o /dev/null "http://127.0.0.1:$PORT/" && { ok=1; break; }
        sleep 2
    done
    log "[$1] engine ready (ok=$ok, conversation-cache $2 MiB, port $PORT)"
    return $((1-ok))
}

stop_arm() {
    pkill -f 'serve/server.py --engine strata' 2>/dev/null
    pkill -f 'engine/strata --serve' 2>/dev/null
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

for arm in "arm1-6144:6144" "arm2-3072:3072"; do
    label=${arm%%:*}; mib=${arm##*:}
    start_arm "$label" "$mib" || { log "[$label] engine not ready - skipping the workload"; stop_arm; continue; }
    snap "[$label] idle"
    .venv/bin/python tools/repro/kv-multi-smoke.py "$W_SIZES" "$W_ROUNDS" $PORT "$W_MAXTOK" "$label" 2>&1 | tee -a "$RES"
    snap "[$label] post-workload"
    log "=== [$label] engine evidence (this arm) ==="
    {
        echo "--- verify timeouts: $(tail -c +"$log_start" "$ELOG" | grep -c 'verify: timed out')"
        echo "--- engine restart events: $(tail -c +"$log_start" "$ELOG" | grep -c 'starting the vision encoder again')"
        tail -c +"$log_start" "$ELOG" | grep -E 'verify: timed out|KV streaming|engine stopped unexpectedly|VRAM free with everything loaded|conversation cache: parked' | tail -20
        echo "--- requests:"
        tail -c +"$log_start" "$ELOG" | grep -E '\[strata\] done:' | tail -8
    } | tee -a "$RES"
    stop_arm
done

# 4) restore the LLM (the standing rule's explicit step)
trap - EXIT
cp "$BAK" "$CFG"
if [ "$used" -ge 1024 ]; then
    log "ABORT: orphan VRAM ${used} MiB - NOT starting the LLM; find the holder with nvidia-smi and kill it"
    sudo systemctl stop llm-deadman.timer llm-deadman.service >>"$RES" 2>&1
    exit 1
fi
docker start "$CTR" >>"$RES" 2>&1
log "swift15 started (explicit)"
for i in $(seq 1 90); do
    code=$(curl -s -m 2 -o /dev/null -w '%{http_code}' "http://127.0.0.1:8088/" 2>/dev/null)
    [ "$code" != "000" ] && { log "8088 answering (HTTP $code)"; break; }
    sleep 2
done
sudo systemctl stop llm-deadman.timer llm-deadman.service >>"$RES" 2>&1
log "dead-man cancelled; A' window closed"
