#!/usr/bin/env bash
# ZeekrDash 服务管理脚本
# 用法：./server.sh start|stop|restart|status|logs

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVER_DIR="$(cd "$SCRIPT_DIR/../server" && pwd)"
PID_FILE="$SERVER_DIR/.server.pid"
LOG_FILE="$SERVER_DIR/.server.log"
HOST="${APP_HOST:-0.0.0.0}"
PORT="${APP_PORT:-8765}"

# 读取 .env（若存在）
if [[ -f "$SERVER_DIR/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "$SERVER_DIR/.env"
  set +a
  HOST="${APP_HOST:-$HOST}"
  PORT="${APP_PORT:-$PORT}"
fi

is_running() {
  [[ -f "$PID_FILE" ]] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null
}

start() {
  if is_running; then
    echo "服务已在运行（PID $(cat "$PID_FILE")）"
    return 0
  fi

  echo "启动 ZeekrDash 服务 → http://$HOST:$PORT"
  cd "$SERVER_DIR"
  setsid nohup python3 -m uvicorn app.main:app \
    --host "$HOST" --port "$PORT" \
    > "$LOG_FILE" 2>&1 < /dev/null &
  echo $! > "$PID_FILE"

  # 等待端口就绪
  for _ in $(seq 1 20); do
    if curl -sf "http://127.0.0.1:$PORT/api/health" > /dev/null 2>&1; then
      echo "✓ 服务已就绪（PID $(cat "$PID_FILE")）"
      return 0
    fi
    sleep 0.5
  done

  echo "✗ 启动超时，请查看日志：$LOG_FILE"
  tail -20 "$LOG_FILE"
  return 1
}

stop() {
  if ! is_running; then
    echo "服务未在运行"
    rm -f "$PID_FILE"
    return 0
  fi

  local pid
  pid="$(cat "$PID_FILE")"
  echo "停止服务（PID $pid）"
  kill "$pid" 2>/dev/null || true

  for _ in $(seq 1 20); do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.3
  done

  kill -9 "$pid" 2>/dev/null || true
  rm -f "$PID_FILE"
  echo "✓ 已停止"
}

status() {
  if is_running; then
    echo "✓ 运行中（PID $(cat "$PID_FILE")）"
    curl -s "http://127.0.0.1:$PORT/api/health" 2>/dev/null | python3 -m json.tool 2>/dev/null || true
  else
    echo "✗ 未运行"
    return 1
  fi
}

case "${1:-}" in
  start)   start   ;;
  stop)    stop    ;;
  restart) stop; sleep 1; start ;;
  status)  status  ;;
  logs)    tail -f "$LOG_FILE" ;;
  *)
    echo "用法：$0 {start|stop|restart|status|logs}"
    exit 1
    ;;
esac
