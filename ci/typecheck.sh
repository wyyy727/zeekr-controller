#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
# Linux Swift 类型检查（CI 用）
# ─────────────────────────────────────────────────────────────
# 在 Linux 容器（swift:6.1 镜像）上，用真实 Swift 6.1 编译器对
# 全部源码做 -typecheck。SwiftUI/Charts 由 ci/ 桩替代。
#
# 能抓：语法错误、类型不匹配、参数错误、拼写错误、
#       访问控制错误、MainActor 隔离错误等。
# 抓不了：仅 iOS SDK 存在的 API 语义（真机编译由 GitHub Actions
#         macos-26 工作流覆盖）。
# ─────────────────────────────────────────────────────────────
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUN_DIR="$(mktemp -d /tmp/zeekr-typecheck.XXXXXX)"
trap 'rm -rf "$RUN_DIR"' EXIT

# swift 官方镜像一般自带 python3（lldb 依赖），缺则现装
command -v python3 >/dev/null 2>&1 || { apt-get update -qq && apt-get install -y -qq python3; }

python3 "$REPO_ROOT/ci/prepare.py" "$REPO_ROOT/ZeekrDash" "$RUN_DIR" "$REPO_ROOT/ci"

echo "── Swift 版本 ──"
swiftc --version

echo "── 语法解析（-parse）──"
cd "$RUN_DIR"
swiftc -parse *.swift
echo "parse: OK"

echo "── 类型检查（-typecheck）──"
swiftc -typecheck *.swift
echo "typecheck: OK"

echo "✅ Linux 类型检查通过 ($(ls *.swift | wc -l) 个文件)"
