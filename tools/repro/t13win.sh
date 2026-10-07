#!/bin/bash
set -u
cd /tmp/mmtest
RES=t13-results.txt
: > "$RES"
restore() { docker start NInfer-kaushikvira-ajgazin >>"$RES" 2>&1; echo "Ninfer back (trap)" | tee -a "$RES"; }
trap restore EXIT
docker stop NInfer-kaushikvira-ajgazin >>"$RES" 2>&1
sleep 3
./t13 | tee -a "$RES"
pkill -f 'engine/strata --serve' 2>/dev/null
trap - EXIT
docker start NInfer-kaushikvira-ajgazin >>"$RES" 2>&1
echo "Ninfer back (explicit)" | tee -a "$RES"
