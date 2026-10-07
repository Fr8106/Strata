#!/bin/bash
# Closed loop: stop the ninfer swift15 container, start strata.service (current strata-iq3_s.json),
# wait for the engine to be ready, print this run's startup budget lines, smoke test.
#
# Standing rule (memory: llm-service-window-rule): stop+start in ONE script - never leave the
# machine with the LLM down if the start step has not run.
set -u
cd /home/ai/Strata
CTR=NInfer-kaushikvira-swift15
ELOG=/home/ai/Strata/strata-iq3_s.log
RES=/home/ai/Strata/tools/repro/switch-strata-results.txt
: > "$RES"
log() { echo "$(date +%T) $*" | tee -a "$RES"; }

# 1) stop the LLM container (strata takes over 8088 + the GPU)
docker stop -t 30 "$CTR" >>"$RES" 2>&1
log "swift15 stopped"
used=999999
for i in $(seq 1 60); do
    used=$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits | head -1)
    [ "$used" -lt 1024 ] && break
    sleep 2
done
if [ "$used" -ge 1024 ]; then
    log "ABORT: VRAM not released (used=${used} MiB) - strata would not fit; NOT starting it"
    exit 1
fi
log "VRAM released (used=${used} MiB)"

# 2) free the page cache: the 46.84 GiB arena pin needs real RAM headroom (the 20:49 incident)
sync
sudo sh -c 'echo 3 > /proc/sys/vm/drop_caches' 2>>"$RES"
log "page cache dropped ($(grep MemAvailable /proc/meminfo | awk '{printf "%.1f GiB available", $2/1048576}'))"

# 3) start strata.service (systemd, reads strata-iq3_s.json)
log_start=$(stat -c %s "$ELOG" 2>/dev/null || echo 0)
sudo systemctl start strata
log "strata.service starting (engine load takes ~2 min)"

ok=0
for i in $(seq 1 100); do
    b=$(curl -sf -m 5 "http://127.0.0.1:8088/health" 2>/dev/null || true)
    b=${b// /}
    [[ "$b" == *'"service":"strata"'* && "$b" == *'"loaded":true'* ]] && { ok=1; break; }
    # a dead engine means the server never comes up: surface it early
    if ! pgrep -f 'serve/server.py --engine strata' >/dev/null; then
        log "server process is gone - start failed, log tail:"
        tail -n 5 "$ELOG" | tee -a "$RES"
        break
    fi
    sleep 3
done
[ "$ok" = 1 ] && log "strata READY on :8088"

# 4) this run's startup budget lines (the proof the config took effect)
log "=== startup budget (this run) ==="
tail -c +"$log_start" "$ELOG" | grep -E 'KV streaming:.*cells per QSA|expert cache auto|expert cache [0-9]+ slots|of VRAM free with everything loaded|INFO context=' | tee -a "$RES"

# 5) smoke: one short completion (the model id comes from the config, not a hardcoded name)
MODEL=$(python3 -c 'import json; print(json.load(open("strata-iq3_s.json"))["model_name"])')
out=$(curl -s -m 60 -H "Authorization: Bearer ninfer-local" -H 'Content-Type: application/json' \
      -d "{\"model\":\"$MODEL\",\"messages\":[{\"role\":\"user\",\"content\":\"说一句话\"}],\"max_tokens\":16}" \
      "http://127.0.0.1:8088/v1/chat/completions" 2>/dev/null)
reply=$(echo "$out" | python3 -c 'import json,sys
body = sys.stdin.read()
try:
    d = json.loads(body)
    print(d["choices"][0]["message"]["content"][:40])
except Exception:
    print("ERROR: " + body[:120])' 2>/dev/null)
if [[ "$reply" == ERROR* || -z "$reply" ]]; then
    log "SMOKE FAILED: $reply - log tail:"
    tail -n 5 "$ELOG" | tee -a "$RES"
    exit 1
fi
log "smoke OK: $reply"
log "switch to strata complete"
