#!/usr/bin/env python3
"""
prepare.py — 为 Linux Swift 类型检查准备源码副本。

把 ZeekrDash/ 下的 Swift 源码复制到目标目录，并做平台无关化处理：
1. 注释掉 Linux 上不存在的框架导入（SwiftUI/Charts/UniformTypeIdentifiers 等），
   由 ci/SwiftUIShim.swift 桩模块替代（声明相同的 API 签名）。
2. 保证每个文件都有 `import Foundation`，并注入
   `#if canImport(FoundationNetworking)` 块（Linux 上 URLSession 在此模块）。
3. 使用 @Observable 宏的文件保证有 `import Observation`（Linux 上该模块
   独立存在，iOS 上由 SDK 隐式提供）。
4. 注释掉 `config.waitsForConnectivity = false`（Linux Foundation 把该属性
   实现为只读）。
5. 把桩文件（ci/SwiftUIShim.swift、ci/LinuxShim.swift）一并复制进目标目录。

用法:
    python3 ci/prepare.py <ZeekrDash源码目录> <输出目录> <本脚本所在目录>
"""
import re
import shutil
import sys
from pathlib import Path

# Linux 上不存在（或由桩替代）的框架导入
SHIMMED_IMPORTS = {
    "SwiftUI",
    "Charts",
    "UniformTypeIdentifiers",
    "UIKit",
    "Combine",
    "WidgetKit",
    "ActivityKit",
}

NET_BLOCK = [
    "#if canImport(FoundationNetworking)",
    "import FoundationNetworking",
    "#endif",
]

IMPORT_RE = re.compile(r"^import\s+([A-Za-z_][A-Za-z0-9_.]*)")

PREVIEW_RE = re.compile(r"^\s*#Preview\b")


def strip_previews(lines: list[str]) -> list[str]:
    """剥离顶层 #Preview { ... } 块（仅 IDE 预览用；Linux 无法展开该宏）。

    按花括号配平找到块尾，忽略块内字符串里的花括号（预览代码极简，够用）。
    """
    out: list[str] = []
    i = 0
    n = len(lines)
    while i < n:
        if PREVIEW_RE.match(lines[i]):
            depth = 0
            started = False
            j = i
            while j < n:
                for ch in lines[j]:
                    if ch == "{":
                        depth += 1
                        started = True
                    elif ch == "}":
                        depth -= 1
                        if started and depth == 0:
                            break
                if started and depth == 0:
                    break
                j += 1
            out.append("// #Preview 块已剥离（仅 IDE 预览用，不影响编译）")
            i = j + 1
            continue
        out.append(lines[i])
        i += 1
    return out


def transform(content: str) -> str:
    lines = strip_previews(content.split("\n"))
    out: list[str] = []
    has_foundation = False
    has_net_block = False
    has_observation = False
    uses_observable = "@Observable" in content

    for line in lines:
        m = IMPORT_RE.match(line)
        if m:
            mod = m.group(1)
            if mod == "Foundation":
                has_foundation = True
                out.append(line)
                if not has_net_block:
                    out.extend(NET_BLOCK)
                    has_net_block = True
                if uses_observable and not has_observation:
                    out.append("import Observation  // Linux 需显式导入（@Observable 宏）")
                    has_observation = True
                continue
            if mod == "Observation":
                has_observation = True
                out.append(line)
                continue
            if mod in SHIMMED_IMPORTS:
                out.append(f"// {line}  (由桩替代)")
                continue
            out.append(line)
            continue

        # Linux Foundation 的 waitsForConnectivity 为只读
        if "config.waitsForConnectivity = false" in line and not line.lstrip().startswith("//"):
            out.append("// " + line.strip() + "  // Linux 只读")
            continue

        out.append(line)

    if not has_foundation:
        prefix = ["import Foundation"] + NET_BLOCK
        if uses_observable and not has_observation:
            prefix.append("import Observation  // Linux 需显式导入（@Observable 宏）")
        out = prefix + out

    return "\n".join(out)


def main() -> None:
    src_dir = Path(sys.argv[1]).resolve()
    dst_dir = Path(sys.argv[2]).resolve()
    ci_dir = Path(sys.argv[3]).resolve()

    dst_dir.mkdir(parents=True, exist_ok=True)

    n_files = 0
    for swift in sorted(src_dir.rglob("*.swift")):
        rel = swift.relative_to(src_dir)
        target = dst_dir / rel.name  # 拍平：swiftc -typecheck 不需要目录结构
        target.write_text(transform(swift.read_text(encoding="utf-8")), encoding="utf-8")
        n_files += 1

    # 桩文件一并复制（LinuxShim.swift 提供平台差异兜底）
    for shim in ("SwiftUIShim.swift", "LinuxShim.swift"):
        shutil.copy2(ci_dir / shim, dst_dir / shim)
        n_files += 1

    print(f"prepared {n_files} swift files -> {dst_dir}")


if __name__ == "__main__":
    main()
