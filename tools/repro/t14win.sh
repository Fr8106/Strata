#!/bin/bash
set -u
cd /tmp/mmtest
RES=t14-results.txt
: > "$RES"
restore() { docker start NInfer-kaushikvira-ajgazin >>"$RES" 2>&1; echo "Ninfer back (trap)" | tee -a "$RES"; }
trap restore EXIT
docker stop NInfer-kaushikvira-ajgazin >>"$RES" 2>&1
sleep 3
./t14 | tee -a "$RES"
trap - EXIT
docker start NInfer-kaushikvira-ajgazin >>"$RES" 2>&1
echo "Ninfer back (explicit)" | tee -a "$RES"
