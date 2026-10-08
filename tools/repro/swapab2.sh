#!/bin/bash
# Repeatable prefill comparison: whole-cache adaptive (fixed 0) vs the 50/50 fixed tier, on two workload
# shapes (random-word salad and natural-language text), 3 fresh conversations each, medians reported.
#   Question: the 11% prefill gap seen once - real geometry cost, or an artifact of the word-salad prompts
#   being adversarial to a profile-locked half?  (2026-10-08)
set -u
cd /home/ai/Strata
CTR=NInfer-kaushikvira-swift15
RES=/home/ai/Strata/tools/repro/swapab2-results.txt
SLOG=/home/ai/Strata/tools/repro/swapab2-server.log
ELOG=/home/ai/Strata/strata-iq3_s.log
PORT=8090
WORDS=8000        # ~8K tokens per prompt; the text arm takes WORDS*4 characters from the corpus
: > "$RES"; : > "$SLOG"
log() { echo "$(date +%T) $*" | tee -a "$RES"; }

cat docs/*.md AGENTS.md 2>/dev/null > /tmp/natcorpus.txt
log "corpus: $(wc -c < /tmp/natcorpus.txt) bytes"

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

run_arm() {   # $1 = fixed0|fixed50, $2 = seed base
    .venv/bin/python - "$1" "/tmp/swap2-$1.json" <<'PY'
import json, sys
c = json.load(open("/home/ai/Strata/strata-iq3_s.json"))
a = c["args"]
i = a.index("--expert-cache-fixed")
if sys.argv[1] == "fixed0":
    del a[i:i+2]
json.dump(c, open(sys.argv[2], "w"), indent=2, ensure_ascii=False)
PY
    log_start=$(stat -c %s "$ELOG" 2>/dev/null || echo 0)
    .venv/bin/python serve/server.py --engine strata --config "/tmp/swap2-$1.json" --port $PORT > "$SLOG" 2>&1 &
    sp=$!
    ok=0
    for i in $(seq 1 400); do
        kill -0 "$sp" 2>/dev/null || { log "[$1] server died early"; break; }
        curl -s -m 2 -o /dev/null "http://127.0.0.1:$PORT/" && { ok=1; break; }
        sleep 2
    done
    [ "$ok" != 1 ] && { log "[$1] NOT ready"; stop_arm; return 1; }
    log "[$1] engine ready: $(tail -c +"$log_start" "$ELOG" | grep -oE 'expert cache [0-9]+ slots' | head -1)"
    # 3 word-salad conversations, then 3 natural-text conversations (fresh seeds each)
    for kind in rand text; do
        if [ "$kind" = text ]; then export CORPUS=/tmp/natcorpus.txt; else unset CORPUS; fi
        seed=$2
        [ "$kind" = text ] && seed=$(( $2 + 500 ))
        SEED0=$seed TIMEOUT=240 CONC=1 \
            .venv/bin/python tools/repro/kv-multi-smoke.py "$WORDS,$WORDS,$WORDS" 1 $PORT 512 "$1-$kind" 2>&1 | tail -4 | tee -a "$RES"
    done
    log "=== [$1] prefill per request (engine log, this run) ==="
    tail -c +"$log_start" "$ELOG" | grep -oE 'prompt [0-9]+ tokens = 0 reused \+ [0-9]+ read in [0-9]+ ms \([0-9.]+ tok/s\), [0-9]+ generated in [0-9]+ ms \([0-9.]+ tok/s\)' \
        | tee -a "$RES"
    stop_arm
}

run_arm fixed0  5100
run_arm fixed50 6100
log "window closed; swift15 left stopped"
