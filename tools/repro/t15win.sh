#!/bin/bash
set -u
cd /tmp/mmtest
RES=t15-results.txt
: > "$RES"
restore() { docker start NInfer-kaushikvira-ajgazin >>"$RES" 2>&1; echo "Ninfer back (trap)" | tee -a "$RES"; }
trap restore EXIT
docker stop NInfer-kaushikvira-ajgazin >>"$RES" 2>&1
sleep 3
for v in m1 m48 p1; do
  echo "=== t15 $v ===" | tee -a "$RES"
  stdbuf -o0 -e0 ./t15 $v > t15-$v.log 2>&1
  echo "  t15 exit=$?" | tee -a "$RES"
  tail -4 t15-$v.log | tee -a "$RES"
  sleep 2
done
trap - EXIT
docker start NInfer-kaushikvira-ajgazin >>"$RES" 2>&1
echo "Ninfer back (explicit)" | tee -a "$RES"
