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
#
# 查找顺序与 app/core/config.py 保持一致：server/.env → 仓库根目录/.env。
# 之前只看 server/.env，而 README 教的是 `cd .. && cp .env.example .env`
# （落在仓库根目录）→ 两处对不上，HOST/PORT 会静默用默认值。
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
for env_file in "$SERVER_DIR/.env" "$REPO_DIR/.env"; do
  if [[ -f "$env_file" ]]; then
    set -a
    # shellcheck disable=SC1091
    source "$env_file"
    set +a
    HOST="${APP_HOST:-$HOST}"
    PORT="${APP_PORT:-$PORT}"
    break
  fi
done

port_alive() {
  curl -sf "http://127.0.0.1:$PORT/api/health" > /dev/null 2>&1
}

is_running() {
  # `kill -0` 在 Windows 的 Git Bash 下对原生进程不可靠（通常直接返回失败），
  # 只靠它会把「明明在跑」判成「未运行」，进而重复启动、撞端口。
  # 故双判据：PID 存活 **或** 健康检查端口有响应。
  if [[ -f "$PID_FILE" ]] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
    return 0
  fi
  port_alive
}

start() {
  if is_running; then
    echo "服务已在运行（PID $(cat "$PID_FILE")）"
    return 0
  fi

  # 优先用服务端自己的虚拟环境解释器 —— 依赖（fastapi/uvicorn 等）装在
  # server/.venv 里，直接用 PATH 上的 python3 会 import 失败。
  local py="python3"
  if [[ -x "$SERVER_DIR/.venv/Scripts/python.exe" ]]; then
    py="$SERVER_DIR/.venv/Scripts/python.exe"      # Windows
  elif [[ -x "$SERVER_DIR/.venv/bin/python" ]]; then
    py="$SERVER_DIR/.venv/bin/python"              # Linux / macOS
  fi

  # setsid 用于让服务脱离当前终端；但 Windows 的 Git Bash **没有**这个命令，
  # 直接调用会 "command not found" 而导致整个启动失败。故按可用性选择。
  local launcher=()
  if command -v setsid >/dev/null 2>&1; then
    launcher=(setsid nohup)
  else
    launcher=(nohup)
  fi

  echo "启动 ZeekrDash 服务 → http://$HOST:$PORT"
  echo "  解释器：$py"
  cd "$SERVER_DIR"
  "${launcher[@]}" "$py" -m uvicorn app.main:app \
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
