#!/bin/bash
# Vision encoder on the GPU vs on the CPU: what does it actually cost?  (2026-10-08)
#   arm gpu : the config as it is (vision.gpu = true)
#   arm cpu : the same config with vision.gpu = false (the same binary, run without --gpu)
# Each arm: start the server on 8090 (encoder + engine), capture the engine's cache/VRAM numbers and the
# totals, send one text request and one image request (timed), then stop.  Closed loop: no LLM restore.
set -u
cd /home/ai/Strata
CTR=NInfer-kaushikvira-swift15
RES=/home/ai/Strata/tools/repro/visionwin-results.txt
SLOG=/home/ai/Strata/tools/repro/visionwin-server.log
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

stop_arm() {
    pkill -f 'serve/server.py --engine strata' 2>/dev/null
    pkill -f 'engine/strata' 2>/dev/null
    pkill -f 'strata-vision' 2>/dev/null
    sleep 3
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

run_arm() {   # $1 = gpu|cpu
    .venv/bin/python - "$1" "/tmp/vision-$1.json" <<'PY'
import json, sys
c = json.load(open("/home/ai/Strata/strata-iq3_s.json"))
c["vision"]["gpu"] = (sys.argv[1] == "gpu")
json.dump(c, open(sys.argv[2], "w"), indent=2, ensure_ascii=False)
PY
    log "[$1] vision.gpu=$(python3 -c "import json;print(json.load(open('/tmp/vision-$1.json'))['vision']['gpu'])")"
    log_start=$(stat -c %s "$ELOG" 2>/dev/null || echo 0)
    .venv/bin/python serve/server.py --engine strata --config "/tmp/vision-$1.json" --port $PORT > "$SLOG" 2>&1 &
    sp=$!
    ok=0
    for i in $(seq 1 400); do
        kill -0 "$sp" 2>/dev/null || { log "[$1] server died early"; break; }
        curl -s -m 2 -o /dev/null "http://127.0.0.1:$PORT/" && { ok=1; break; }
        sleep 2
    done
    [ "$ok" != 1 ] && { log "[$1] NOT ready"; stop_arm; return 1; }
    sleep 5
    {
        echo "=== [$1] startup (everything loaded) ==="
        tail -c +"$log_start" "$ELOG" | grep -E 'expert cache [0-9]+ slots|expert cache auto:|VRAM free with everything loaded|KV streaming: [0-9]+ of' | tail -4
        echo "nvidia-smi used: $(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits | head -1) MiB"
        vp=$(pgrep -f 'strata-vision' | head -1)
        [ -n "$vp" ] && grep -E 'VmRSS' "/proc/$vp/status"
        ep=$(pgrep -f 'engine/strata --serve' | head -1)
        [ -n "$ep" ] && grep -E 'VmRSS' "/proc/$ep/status"
    } | tee -a "$RES"
    # one text request (sanity) and one image request (timed)
    SEED0=11 TIMEOUT=180 CONC=1 .venv/bin/python tools/repro/kv-multi-smoke.py "2000" 1 $PORT 16 "text-$1" 2>&1 | tail -1 | tee -a "$RES"
    TIMEOUT=300 .venv/bin/python - "$1" "$RES" <<'PY'
import base64, json, sys, time, urllib.request
arm, res = sys.argv[1], sys.argv[2]
img = base64.b64encode(open("/tmp/vision-test.png", "rb").read()).decode()
body = json.dumps({"model": "qwen3.8-flash-next-iq3_s",
                   "messages": [{"role": "user", "content": [
                       {"type": "text", "text": "Describe this image in one short sentence."},
                       {"type": "image_url", "image_url": {"url": "data:image/png;base64," + img}}]}],
                   "max_tokens": 64}).encode()
r = urllib.request.Request("http://127.0.0.1:8090/v1/chat/completions", data=body,
                           headers={"Content-Type": "application/json", "Authorization": "Bearer ninfer-local"})
t0 = time.time()
try:
    with urllib.request.urlopen(r, timeout=300) as f:
        d = json.loads(f.read().decode())
    u = d.get("usage", {})
    line = f"image-{arm}: OK in {time.time()-t0:.1f}s usage={u}"
except Exception as e:
    line = f"image-{arm}: FAILED after {time.time()-t0:.1f}s: {e}"
print(line, flush=True)
open(res, "a").write(line + "\n")
PY
    {
        echo "--- [$1] after the image request:"
        echo "nvidia-smi used: $(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits | head -1) MiB"
        tail -c +"$log_start" "$ELOG" | grep -E 'expert cache hit rate|prompt .* tokens =|VRAM free' | tail -3
    } | tee -a "$RES"
    stop_arm
}

run_arm gpu
run_arm cpu
log "window closed; swift15 left stopped"
