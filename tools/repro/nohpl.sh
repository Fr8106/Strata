#!/bin/bash
# THP 假设验证：STRATA_NO_LARGEPAGES=1 跑 base 配置。停/拉 Ninfer 同一脚本。
set -u
cd /tmp/mmtest
RES=nohpl-test.txt
: > "$RES"
restore() { docker start NInfer-kaushikvira-ajgazin >>"$RES" 2>&1; echo "Ninfer back (trap)" | tee -a "$RES"; }
trap restore EXIT

docker stop NInfer-kaushikvira-ajgazin >>"$RES" 2>&1
sleep 3

env STRATA_NO_LARGEPAGES=1 STRATA_TRACE_ADAPT=1 timeout 280 /home/ai/Strata/engine/strata --serve $(tr '\n' ' ' < args-base.txt) > /tmp/mmtest/nohpl.log 2>&1 &
ep=$!
for i in $(seq 1 280); do
  if grep -qE 'pre-filled [0-9]+ of|fill failed' /tmp/mmtest/nohpl.log 2>/dev/null; then
    sleep 5; kill $ep 2>/dev/null; wait $ep 2>/dev/null; break
  fi
  kill -0 $ep 2>/dev/null || break
  sleep 1
done
grep -E 'large pages|hugetlb|HUGETLB|transparent huge|pre-filled|fill failed|PCIe alias' /tmp/mmtest/nohpl.log | tail -6 | tee -a "$RES"
pkill -f 'engine/strata --serve' 2>/dev/null
sleep 5

trap - EXIT
docker start NInfer-kaushikvira-ajgazin >>"$RES" 2>&1
echo "Ninfer back (explicit)" | tee -a "$RES"
