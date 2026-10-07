#!/bin/bash
# 配置 bisection：逐个去掉子系统，看 fill 何时通过。停/拉 Ninfer 在同一脚本内。
set -u
cd /tmp/mmtest
RES=bisect-results.txt
: > "$RES"
restore() { docker start NInfer-kaushikvira-ajgazin >>"$RES" 2>&1; echo "Ninfer back (trap)" | tee -a "$RES"; }
trap restore EXIT

python3 - <<'PY'
import json
c = json.load(open('/home/ai/Strata/strata-iq3_s.json'))
args = c['args']
def drop(a, *flags):
    out, i = [], 0
    while i < len(a):
        if a[i] in flags:
            i += 1
            if i < len(a) and not a[i].startswith('--'): i += 1
            continue
        out.append(a[i]); i += 1
    return out
variants = {
  'base': args,
  'no-vision': drop(args, '--vision'),
  'no-mtp': drop(args, '--mtp'),
  'no-ple': drop(args, '--ple-gguf'),
  'no-kv-res': drop(args, '--kv-resident'),
  'no-convcache': drop(args, '--conversation-cache-mib', '--conversation-cache-slots', '--conversation-cache-min-free-mib'),
}
for name, a in variants.items():
    open(f'/tmp/mmtest/args-{name}.txt', 'w').write('\n'.join(a))
PY

docker stop NInfer-kaushikvira-ajgazin >>"$RES" 2>&1
sleep 3

for v in base no-vision no-mtp no-ple no-kv-res no-convcache; do
  echo "=== bisect $v ===" | tee -a "$RES"
  env STRATA_TRACE_ADAPT=1 timeout 240 /home/ai/Strata/engine/strata --serve $(tr '\n' ' ' < args-$v.txt) > /tmp/mmtest/bisect-$v.log 2>&1 &
  ep=$!
  for i in $(seq 1 240); do
    if grep -qE 'pre-filled [0-9]+ of|fill failed|pre-fill sync' /tmp/mmtest/bisect-$v.log 2>/dev/null; then
      sleep 3; kill $ep 2>/dev/null; wait $ep 2>/dev/null; break
    fi
    kill -0 $ep 2>/dev/null || break
    sleep 1
  done
  grep -E 'pre-filled|fill failed|pre-fill sync|PCIe alias' /tmp/mmtest/bisect-$v.log | tail -4 | tee -a "$RES"
  pkill -f 'engine/strata --serve' 2>/dev/null
  sleep 5
done

trap - EXIT
docker start NInfer-kaushikvira-ajgazin >>"$RES" 2>&1
echo "Ninfer back (explicit)" | tee -a "$RES"
