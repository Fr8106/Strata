#!/bin/bash
set -u
cd /tmp/mmtest
RES=fix-results.txt
: > "$RES"
restore() { docker start NInfer-kaushikvira-ajgazin >>"$RES" 2>&1; echo "Ninfer back (trap)" | tee -a "$RES"; }
trap restore EXIT
docker stop NInfer-kaushikvira-ajgazin >>"$RES" 2>&1
sleep 3
env STRATA_TRACE_ADAPT=1 timeout 400 /home/ai/Strata/engine/strata --serve $(tr '\n' ' ' < args-base.txt) > /tmp/mmtest/fix-engine.log 2>&1 &
ep=$!
for i in $(seq 1 400); do
  if grep -qE 'pre-filled [0-9]+ of|fill failed|pre-fill sync' /tmp/mmtest/fix-engine.log 2>/dev/null; then
    sleep 5; kill $ep 2>/dev/null; wait $ep 2>/dev/null; break
  fi
  kill -0 $ep 2>/dev/null || break
  sleep 1
done
grep -E 'pre-filled|fill failed|pre-fill sync|PCIe alias|large pages' /tmp/mmtest/fix-engine.log | tail -6 | tee -a "$RES"
pkill -f 'engine/strata --serve' 2>/dev/null
sleep 5
trap - EXIT
docker start NInfer-kaushikvira-ajgazin >>"$RES" 2>&1
echo "Ninfer back (explicit)" | tee -a "$RES"
