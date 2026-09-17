#!/usr/bin/env bash
#
# ZeekrDash 服务端启动脚本
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/server"

# 载入本地 .env（若存在）
if [ -f .env ]; then
    echo "→ 载入 .env"
    set -a
    # shellcheck disable=SC1091
    source .env
    set +a
fi

HOST="${APP_HOST:-0.0.0.0}"
PORT="${APP_PORT:-8765}"

echo "→ ZeekrDash 服务端启动"
echo "  地址: http://${HOST}:${PORT}"
echo "  文档: http://127.0.0.1:${PORT}/docs"

if [ -z "${ZEEKR_PHONE:-}" ]; then
    echo ""
    echo "  提示: 未配置极氪账号，将以【模拟数据模式】运行"
    echo "        配置方法见 README「接入真实车辆数据」"
    echo ""
fi

exec python3 -m uvicorn app.main:app --host "$HOST" --port "$PORT"
