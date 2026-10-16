#!/usr/bin/env python3
"""实时跟随日志文件，类似 `tail -f`。

用法：
    python scripts/logs_tail.py <日志文件> [初始显示行数]

为什么要单独一个脚本：
在 Windows 批处理里实现「只显示新增的行」非常脆 ——
  · `find /c /v "" < file` 的输出是 "---- 文件名: 123"，数字落在第 3 个
    token 上，直接 `set /a` 会拿到 "----"；
  · `more +N` 需要交互式控制台，stdout 一旦被重定向就报「管道不存在」；
  · 用 `for /f "skip=N"` 又要把行号传进子过程，LF 换行的脚本下会丢参数。
所以交给 Python 做。

编码：**不写死**。日志可能是 GBK 也可能是 UTF-8 ——
Windows 下 Python 默认按 locale 写 stdout（中文系统 = GBK），
而设了 PYTHONUTF8 / PYTHONIOENCODING 的环境会写 UTF-8。
这里先探测，再转成当前控制台的编码输出，两种来源都能正常显示。
"""

from __future__ import annotations

import io
import os
import sys
import time

POLL_SECONDS = 0.4
SNIFF_BYTES = 65536


def console_encoding() -> str:
    if os.name != "nt":
        return "utf-8"
    # 控制台代码页对应的编码，拿不到就按中文 Windows 的默认值
    try:
        return "cp%d" % __import__("ctypes").windll.kernel32.GetConsoleOutputCP()
    except Exception:
        return "gbk"


def detect_encoding(sample: bytes, fallback: str) -> str:
    """判断日志文件用的是哪种编码。

    先严格试 UTF-8，失败才落到 fallback。顺序不能反 ——
    任意 GBK 字节几乎都能被 UTF-8 的宽松解码吞下去，会误判。
    """
    if not sample:
        return fallback
    try:
        sample.decode("utf-8")
        return "utf-8"
    except UnicodeDecodeError:
        return fallback


def main() -> int:
    if len(sys.argv) < 2:
        print("usage: logs_tail.py <logfile> [initial_lines]", file=sys.stderr)
        return 2

    path = sys.argv[1]
    initial = int(sys.argv[2]) if len(sys.argv) > 2 else 25
    out_enc = console_encoding()

    # 看日志的工具自己不能崩：任何解码异常都用 replace 兜住。
    try:
        out = io.TextIOWrapper(
            sys.stdout.buffer, encoding=out_enc, errors="replace", line_buffering=True
        )
    except AttributeError:
        out = sys.stdout

    with open(path, "rb") as f:
        head = f.read()
        enc = detect_encoding(head[:SNIFF_BYTES], "gbk" if os.name == "nt" else "utf-8")

        lines = head.decode(enc, errors="replace").splitlines(keepends=True)
        for line in lines[-initial:]:
            out.write(line)
        out.flush()

        # 文件是被另一个进程追加写的。EOF 时 read() 返回空，
        # 等一会儿重试即可 —— 不需要重开文件。
        try:
            while True:
                chunk = f.read()
                if chunk:
                    out.write(chunk.decode(enc, errors="replace"))
                    out.flush()
                else:
                    time.sleep(POLL_SECONDS)
        except KeyboardInterrupt:
            out.write("\n")
            out.flush()

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
