#!/usr/bin/env bash
# LLM 服务切换：ninfer（docker 容器，27B）<-> Strata（strata-iq3_s），共用 8088 端口。
# 用法: switch-llm.sh strata | ninfer | status
# 切换 = 停一方 + 起另一方 + 等 /health 就绪 + 一次真实补全冒烟。
set -euo pipefail

CONTAINER=NInfer-kaushikvira-ajgazin
PORT=8088
KEY=ninfer-local
STRATA_DIR=/home/ai/Strata
STRATA_CFG=$STRATA_DIR/strata-iq3_s.json
STRATA_OUT=$STRATA_DIR/strata-serve.out
STRATA_PIDFILE=/tmp/strata-serve.pid
HEALTH=http://127.0.0.1:$PORT/health

log() { printf '[switch-llm] %s\n' "$*"; }

container_running() { [ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null || echo false)" = "true" ]; }
strata_pid() { pgrep -f 'serve/server.py --engine strata' | head -1 || true; }

health_body() { curl -sf -m 5 "$HEALTH" 2>/dev/null || true; }
# 就绪判据：strata 的 /health 带 "service":"strata" 且 "loaded":true；ninfer 的只有 {"status":"ok"}
strata_ready() { local b; b=$(health_body); b=${b// /}; [[ "$b" == *'"service":"strata"'* && "$b" == *'"loaded":true'* ]]; }
ninfer_ready() { local b; b=$(health_body); b=${b// /}; [[ "$b" == *'"status":"ok"'* && "$b" != *strata* ]]; }

smoke() { # 一次真实补全，证明 LLM 能出字
  local model
  model=$(curl -sf -m 5 -H "Authorization: Bearer $KEY" "http://127.0.0.1:$PORT/v1/models" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["data"][0]["id"])' 2>/dev/null) || { log "冒烟失败：拿不到模型列表"; return 1; }
  local out
  out=$(curl -sf -m 120 -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' \
        -d "{\"model\":\"$model\",\"messages\":[{\"role\":\"user\",\"content\":\"说一句话\"}],\"max_tokens\":48}" \
        "http://127.0.0.1:$PORT/v1/chat/completions") || { log "冒烟失败：补全请求失败"; return 1; }
  log "冒烟通过（模型 $model）: $(echo "$out" | python3 -c 'import json,sys; m=json.load(sys.stdin)["choices"][0]["message"]; print(((m.get("content") or "") + (m.get("reasoning_content") or ""))[:60])' 2>/dev/null || echo '<无法解析响应>')"
}

wait_ready() { # $1=strata|ninfer  $2=超时秒
  local which=$1 t=0
  while :; do
    if { [ "$which" = strata ] && strata_ready; } || { [ "$which" = ninfer ] && ninfer_ready; }; then
      log "$which 就绪（${t}s）"; return 0
    fi
    [ "$t" -ge "$2" ] && { log "$which 未在 ${2}s 内就绪"; return 1; }
    sleep 3; t=$((t + 3))
  done
}

stop_strata() {
  local pid; pid=$(strata_pid)
  [ -n "$pid" ] || { log "Strata 未运行"; return 0; }
  log "停止 Strata（pid $pid，SIGTERM → 引擎 QUIT 落 profile）"
  kill -TERM "$pid"
  for _ in $(seq 1 60); do kill -0 "$pid" 2>/dev/null || { log "Strata 已退出"; rm -f "$STRATA_PIDFILE"; return 0; }; sleep 1; done
  log "Strata 60s 未退出，kill -9"; kill -9 "$pid"; rm -f "$STRATA_PIDFILE"; sleep 2
}

engine_pid() { pgrep -f 'engine/strata --serve' | head -1 || true; }   # 注意别匹配到 strata-vision

start_strata() {
  local py=$STRATA_DIR/.venv/bin/python
  [ -x "$py" ] || { log "失败：找不到 $py（Strata 的 venv）"; return 1; }
  local e; e=$(engine_pid)
  if [ -n "$e" ]; then log "失败：Strata 引擎已在运行（pid $e，占着显存），先停掉它"; return 1; fi
  log "启动 Strata（$STRATA_CFG，端口 $PORT）"
  ( cd "$STRATA_DIR" && "$py" serve/server.py --engine strata --config "$STRATA_CFG" --port "$PORT" </dev/null >>"$STRATA_OUT" 2>&1 & echo $! > "$STRATA_PIDFILE" )
}

# 启动失败的收尾：连引擎子进程一起清掉，不留占显存/内存的孤儿
cleanup_strata() {
  local pid; pid=$(strata_pid)
  [ -n "$pid" ] && kill -TERM "$pid" 2>/dev/null
  for _ in $(seq 1 30); do
    [ -z "$(strata_pid)" ] && [ -z "$(engine_pid)" ] && { log "已清理 server + 引擎进程"; return 0; }
    sleep 1
  done
  pkill -9 -f 'serve/server.py --engine strata' 2>/dev/null; pkill -9 -f 'Strata/engine/strata' 2>/dev/null   # 含 vision
  log "强杀收尾"
}

stop_ninfer() {
  container_running || { log "ninfer 容器未运行"; return 0; }
  log "停止 ninfer 容器"
  docker stop -t 30 "$CONTAINER"
  for _ in $(seq 1 20); do curl -sf -m 2 "$HEALTH" >/dev/null 2>&1 || { log "端口 $PORT 已释放"; return 0; }; sleep 1; done
  log "警告：容器已停但端口 $PORT 仍被占"; return 1
}

start_ninfer() {
  log "启动 ninfer 容器"
  docker start "$CONTAINER"
}

status() {
  local b; b=$(health_body)
  if strata_ready; then echo "当前服务: Strata (pid $(strata_pid))"
  elif ninfer_ready; then echo "当前服务: ninfer (容器 $CONTAINER)"
  elif [ -n "$b" ]; then echo "端口 $PORT 有响应但非预期服务: $b"
  else echo "端口 $PORT 无服务"; fi
  container_running && echo "ninfer 容器: running" || echo "ninfer 容器: stopped"
  [ -n "$(strata_pid)" ] && echo "Strata: running (pid $(strata_pid))" || echo "Strata: stopped"
}

case "${1:-}" in
  strata)
    if strata_ready; then log "Strata 已在服务，无需切换"; exit 0; fi
    stop_ninfer; start_strata
    wait_ready strata 300 || { log "失败。strata 日志尾部:"; tail -n 5 "$STRATA_DIR/strata-iq3_s.log"; tail -n 5 "$STRATA_OUT"; cleanup_strata; exit 1; }
    smoke; log "已切到 Strata";;
  ninfer)
    if ninfer_ready && [ -z "$(strata_pid)" ]; then log "ninfer 已在服务，无需切换"; exit 0; fi
    stop_strata; start_ninfer
    wait_ready ninfer 600 || { log "失败：ninfer 未就绪"; docker logs --tail 5 "$CONTAINER"; exit 1; }
    smoke; log "已切到 ninfer";;
  restart)
    [ -n "$(strata_pid)" ] || { echo "Strata 未运行，用 $0 strata"; exit 1; }
    stop_strata; start_strata
    wait_ready strata 300 || { log "失败。strata 日志尾部:"; tail -n 5 "$STRATA_DIR/strata-iq3_s.log"; tail -n 5 "$STRATA_OUT"; cleanup_strata; exit 1; }
    smoke; log "已重启 Strata";;
  status) status;;
  *) echo "用法: $0 strata | ninfer | restart | status"; exit 2;;
esac
