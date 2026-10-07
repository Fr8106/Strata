#!/usr/bin/env bash
# 实际使用测试看门狗：每 60s 往 data/usage-watch.log 追加一行健康状态。
# ok   = 一切正常；WARN = 有新错误行/固定区被侵犯/固定区份额过低(建议重启换 profile)；CRIT = 引擎或 /health 没了。
# 48 小时后自行退出。用法: nohup 后台跑即可，别与 switch-llm.sh restart 冲突（它不重启任何东西）。
set -u
OUT=/home/ai/Strata/data/usage-watch.log
LOG=/home/ai/Strata/strata-iq3_s.log
END=$(( $(date +%s) + 48*3600 ))
prev_err=0
while [ "$(date +%s)" -lt "$END" ]; do
  ts=$(date '+%F %T')
  eng=$(pgrep -f 'engine/strata --serve' | head -1 || true)
  if [ -z "$eng" ]; then echo "$ts CRIT engine not running (staying up for the restart)" >> "$OUT"; sleep 30; continue; fi
  hb=$(curl -sf -m 5 http://127.0.0.1:8088/health 2>/dev/null | tr -d ' ' || true)
  err=$(grep -c -E 'copy failed|refill failed|reached fixed slot|CUDA error' "$LOG" 2>/dev/null || true)
  breach=$(grep -c 'reached fixed slot' "$LOG" 2>/dev/null || true)
  err=${err:-0}; breach=${breach:-0}
  last=$(grep 'routes fixed' "$LOG" | tail -1)
  fs=$(echo "$last" | sed -n 's/.*routes fixed \([0-9.]*\)%.*/\1/p')
  mem=$(awk '/MemAvailable/{print int($2/1048576)}' /proc/meminfo)
  d=$((err - prev_err)); prev_err=$err
  level=ok
  case "$hb" in *'"service":"strata"'*) case "$hb" in *'"loaded":true'*) ;; *) level=CRIT_HEALTH;; esac ;; *) level=CRIT_HEALTH;; esac
  [ "$d" -gt 0 ] && level=WARN_new_errors+$d
  [ "$breach" -gt 0 ] && level=WARN_FIXED_BREACH=$breach
  [ -n "$fs" ] && [ "$(echo "$fs < 40" | bc -l 2>/dev/null || echo 0)" = 1 ] && level="$level RENEW_PROFILE(fixed_share=$fs)"
  echo "$ts $level pid=$eng mem_avail=${mem}GiB errors_total=$err fixed_breach=$breach fixed_share=${fs:-n/a}" >> "$OUT"
  sleep 60
done
echo "$(date '+%F %T') watchdog done (48h)" >> "$OUT"
