#!/usr/bin/env bash
# ZeekrDash 服务管理脚本
#
# 用法（在**仓库根目录**执行）：
#   ./scripts/server.sh start|stop|restart|status|logs
#
# 注意脚本在 scripts/ 下，不在仓库根 —— 写成 ./server.sh 会 "No such file"。
# （本注释原先就漏了 scripts/ 前缀，会误导人。）
# 脚本内部用 SCRIPT_DIR 定位，因此从任何目录调用都可以，只要路径写对。

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

# 监听该端口的进程 PID（拿不到则输出空）。
#
# 为什么不直接用 PID 文件：`nohup "$py" ... &` 记下的 $! 是 **nohup 包装 shell**
# 的 PID，与真正的 python 进程不是同一个。Git Bash + Windows 原生 python 下，
# 杀包装 shell 完全不会影响 python —— 表现为 stop 谎报「已停止」，服务照跑，
# 随后 start 又因端口被占而拒绝启动。所以进程定位一律以端口反查为准。
listen_pid() {
  local pid=""
  if command -v netstat >/dev/null 2>&1; then
    # Windows / Git Bash：netstat -ano 的最后一列是 PID。
    # tr -d '\r' 不可省 —— Windows 输出是 CRLF，PID 会带上 \r 让 taskkill 失败。
    pid="$(netstat -ano 2>/dev/null | tr -d '\r' \
           | grep -E "[:.]${PORT}[[:space:]].*LISTENING" \
           | awk '{print $NF}' | head -1 || true)"
    if [[ -n "$pid" ]]; then echo "$pid"; return 0; fi
  fi
  if command -v lsof >/dev/null 2>&1; then
    pid="$(lsof -ti tcp:"$PORT" -sTCP:LISTEN 2>/dev/null | head -1 || true)"
    if [[ -n "$pid" ]]; then echo "$pid"; return 0; fi
  fi
  return 0
}

is_running() {
  # 以「端口有监听」为准；拿不到端口信息时退回健康检查。
  # 不再依赖 PID 文件存活 —— 见 listen_pid 的说明。
  [[ -n "$(listen_pid || true)" ]] || port_alive
}

start() {
  if is_running; then
    local cur
    cur="$(listen_pid || true)"
    echo "服务已在运行（端口 $PORT${cur:+，PID $cur}）"
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
  # PYTHONIOENCODING=utf-8 不能省：Windows 下 Python 默认按 locale（GBK）写
  # stdout，日志里的中文会变成乱码 —— 用 UTF-8 的编辑器打开就是一片「锟斤拷」。
  env PYTHONIOENCODING=utf-8 "${launcher[@]}" "$py" -m uvicorn app.main:app \
    --host "$HOST" --port "$PORT" \
    > "$LOG_FILE" 2>&1 < /dev/null &
  # 这只是 nohup 包装 shell 的 PID，仅供粗查；真正的进程 PID 在下面的就绪
  # 检测里用 listen_pid 回填 —— 别拿这里的值去 kill（见 listen_pid 的说明）。
  echo $! > "$PID_FILE"

  # 等待端口就绪
  for _ in $(seq 1 20); do
    if curl -sf "http://127.0.0.1:$PORT/api/health" > /dev/null 2>&1; then
      local real
      real="$(listen_pid || true)"
      if [[ -n "$real" ]]; then
        echo "$real" > "$PID_FILE"
        echo "✓ 服务已就绪（PID $real）"
      else
        echo "✓ 服务已就绪（端口 $PORT）"
      fi
      return 0
    fi
    sleep 0.5
  done

  echo "✗ 启动超时，请查看日志：$LOG_FILE"
  tail -20 "$LOG_FILE"
  return 1
}

stop() {
  local pid
  pid="$(listen_pid || true)"

  if [[ -z "$pid" ]]; then
    echo "服务未在运行（端口 $PORT 无监听）"
    rm -f "$PID_FILE"
    return 0
  fi

  echo "停止服务（PID $pid，端口 $PORT）"

  # Windows 下 kill 对原生进程无效，必须用 taskkill。
  # Git Bash 会把 /PID 误当路径，故写成 //PID 转义。
  if command -v taskkill >/dev/null 2>&1; then
    taskkill //PID "$pid" //F > /dev/null 2>&1 || true
  fi
  kill "$pid" 2>/dev/null || true          # 非 Windows 走这条

  # 以「端口是否真的没了」为准，而不是「杀过命令了」——
  # 旧实现只管发 kill，于是出现了「报已停止、服务照跑」的假成功。
  for _ in $(seq 1 20); do
    [[ -z "$(listen_pid || true)" ]] && break
    sleep 0.3
  done
  if [[ -n "$(listen_pid || true)" ]]; then
    kill -9 "$pid" 2>/dev/null || true
    sleep 0.5
  fi

  if [[ -n "$(listen_pid || true)" ]]; then
    echo "✗ 端口 $PORT 仍被占用，未能停止（占用进程 PID $(listen_pid)）"
    return 1
  fi

  rm -f "$PID_FILE"
  echo "✓ 已停止"
}

status() {
  if is_running; then
    local cur
    cur="$(listen_pid || true)"
    echo "✓ 运行中（端口 $PORT${cur:+，PID $cur}）"
    curl -s "http://127.0.0.1:$PORT/api/health" 2>/dev/null | python3 -m json.tool 2>/dev/null || true
  else
    echo "✗ 未运行（端口 $PORT 无监听）"
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
