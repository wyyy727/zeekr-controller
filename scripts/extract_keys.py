#!/usr/bin/env python3
"""
ZeekrDash — 从官方极氪 APK 提取 6 个网关密钥
============================================
产出 ZeekrDash 的 `server/.env` 所需的全部凭据：

    ZEEKR_HMAC_ACCESS_KEY    GW2 换令牌
    ZEEKR_HMAC_SECRET_KEY    GW2 换令牌
    ZEEKR_PASSWORD_PUBLIC_KEY RSA 加密登录密码
    ZEEKR_PROD_SECRET        GW3 车况/车控签名（最关键）
    ZEEKR_VIN_KEY            AES-128 加密 VIN
    ZEEKR_VIN_IV             AES-128 加密 VIN

**本文件是第三方代码的移植版，不是自研。**
起源：https://github.com/wysie/zeekr_key_extractor （MIT，Copyright (c) 2025）
本仓库的改动仅三处（算法一行未动）：
  1. 默认 `--region CN`（上游默认 EM），并默认输出到 `docs/zeekr_secrets.json`
  2. 新增 `--write-env` —— 直接把密钥填进 `server/.env` 的空位
  3. **默认不再回显密钥明文**（只显示掩码）。上游会原样打印到终端，
     那会把密钥留在 shell 历史、CI 日志与录屏里。要明文用 `--show`。

上游支持的两种存储代际：
  - App <= 1.5.5:  HMAC 密钥在 libenv.so 里被 OLLVM 加密；VIN key/IV 是
                   DEX 中的明文字符串。
  - App >= 1.5.7:  HMAC 密钥在 libenv.so 的 env × stage 明文表里
                   （靠 ELF 重定位 + ARM64 反汇编还原）；
                   VIN key/IV 移入 iWall ECIES（fi.a / SecuritySuiteSDK），
                   静态取不到 —— 需从 v1.5.5 的 APK 取，或用 Frida 运行时抓。

为什么能绕过加固：
官方 App 加了壳（`libconch.so` 等，见 `docs/zeekr-apk-reference.md`），
JADX 只能解析 23 个类。但本脚本**不依赖类级反编译** ——
它只扫 DEX 的明文字符串表，以及反汇编 `libenv.so` 的 ELF 数据段，
所以加固不影响它。

依赖：
    pip install capstone pyelftools

用法：
    # 最常用：整包即可，无需分片；直接写进 .env
    python scripts/extract_keys.py <apk> --write-env

    # 只提取，存 JSON（默认 docs/zeekr_secrets.json，已被 .gitignore 忽略）
    python scripts/extract_keys.py <apk>

    # 要看密钥明文（会打印到终端，注意录屏/日志）
    python scripts/extract_keys.py <apk> --show

关于 APK 从哪来：
CN 包名是 `com.zeekrlife.mobile`，PC 上从应用宝等商店直接下整包即可，
**不需要安卓设备**。上游 README 里的 `adb pull` 只是取文件的其中一种方式。
"""

import argparse
import json
import os
import re
import struct
import sys
import tempfile
import zipfile
from pathlib import Path

try:
    from capstone import CS_ARCH_ARM64, CS_MODE_ARM, Cs
except ImportError:
    print("ERROR: capstone is required. Install with: pip install capstone")
    sys.exit(1)

try:
    from elftools.elf.elffile import ELFFile
except ImportError:
    print("ERROR: pyelftools is required. Install with: pip install pyelftools")
    sys.exit(1)


# ============================================================================
# Constants
# ============================================================================

# Region indices in the legacy (<= 1.5.5) OLLVM pointer tables
REGION_INDICES = {"CN": 0, "SEA": 1, "EU": 3, "EM": 3}
REGIONS_PER_ENV = 4
PROD_ENV_GROUP = 1
PROD_ENV_GROUP_EU = 0

# New (>= 1.5.7) libenv.so layout: 15 environment rows x 4 stage columns.
# Stage column 3 is always production (verified: col order is dev/test/uat/prod
# across every row, e.g. gateway-int-dev | gateway-int-test | *-uat | *-prod).
PROD_STAGE_INDEX = 3

# How to find the production row for each --region value in the new layout:
# match against the gateway hostnames of each env row.
REGION_HOST_PATTERNS = {
    "EM": "gateway-pub-em.zeekrlife.com/",
    "EU": "gateway-pub-azure.zeekr.eu/",
    "CN": "gateway-pub.zeekrlife.com/",
    "SEA": "gateway-pub-hw-em-sg.zeekrlife.com/",
}

# Known non-secret 16-char hex strings to filter out
TRIVIAL_HEX16 = {
    "0000000000000000",
    "0123456789012345",
    "0123456789abcdef",
    "9774d56d682e549c",
}


# ============================================================================
# 输出脱敏
# ============================================================================

# 上游会把密钥明文打到 stdout。这里默认掩码 —— 终端输出常被录屏、贴进
# issue、或被 CI 留档，而真正的落点 .env 是不入库的（见 .gitignore）。
SHOW_SECRETS = False


def mask(value):
    """把密钥缩成「前 4 位…后 4 位（长度）」；缺失时返回 NOT FOUND。

    刻意保留前后各 4 位：全打码的话不同密钥看起来完全一样，
    使用者就无法核对「这次是不是换了一把钥匙」。
    """
    if not value:
        return "NOT FOUND"
    if SHOW_SECRETS or len(value) <= 8:
        return value
    return f"{value[:4]}…{value[-4:]}  (len={len(value)})"


# ============================================================================
# Shared ELF helpers
# ============================================================================

class ElfHelper:
    def __init__(self, so_path: str):
        self.so_path = so_path
        with open(so_path, "rb") as f:
            self.data = f.read()
        self._parse_elf()

    def _parse_elf(self):
        with open(self.so_path, "rb") as f:
            elf = ELFFile(f)
            self.elf = elf
            self.segments = []
            for seg in elf.iter_segments():
                if seg.header.p_type == "PT_LOAD":
                    self.segments.append(
                        (
                            seg.header.p_vaddr,
                            seg.header.p_offset,
                            seg.header.p_filesz,
                            seg.header.p_memsz,
                        )
                    )
            self.relocs = {}
            for section in elf.iter_sections():
                if section.header.sh_type in ("SHT_RELA", "SHT_REL"):
                    for rel in section.iter_relocations():
                        self.relocs[rel["r_offset"]] = rel.entry.get("r_addend", 0)
            self.symbols = {}
            dynsym = elf.get_section_by_name(".dynsym")
            if dynsym:
                for sym in dynsym.iter_symbols():
                    if sym.name and sym["st_value"]:
                        self.symbols[sym.name] = sym["st_value"]

    def vaddr_to_offset(self, vaddr: int) -> int | None:
        for seg_vaddr, seg_offset, seg_filesz, seg_memsz in self.segments:
            if seg_vaddr <= vaddr < seg_vaddr + seg_memsz:
                off = vaddr - seg_vaddr + seg_offset
                if off < seg_offset + seg_filesz:
                    return off
        return None

    def cstr(self, vaddr: int) -> str | None:
        off = self.vaddr_to_offset(vaddr)
        if off is None:
            return None
        end = self.data.find(b"\x00", off)
        if end < 0:
            return None
        return self.data[off:end].decode("utf-8", "replace")

    def deref_str(self, vaddr: int) -> str | None:
        """Pointer at vaddr -> string (via relocation addend or raw pointer)."""
        if vaddr in self.relocs:
            return self.cstr(self.relocs[vaddr])
        off = self.vaddr_to_offset(vaddr)
        if off is None:
            return None
        ptr = struct.unpack_from("<Q", self.data, off)[0]
        return self.cstr(ptr)


# ============================================================================
# New-style libenv.so resolver (app >= 1.5.7, plaintext env x stage tables)
# ============================================================================

class EnvTableResolver(ElfHelper):
    """Resolve the plaintext env x stage string tables in libenv.so (v1.5.7+).

    The JNI wrappers (getNativeApplicationId / getNativeSecret / getNativeHost)
    call small helper functions that switch on the stage index (stored by
    upDateNativeEnvironment) through a 15-entry jump table; each case loads a
    4-entry pointer table (one per brand/area) or a fixed string. All strings
    are plaintext in .rodata; pointer tables live in .data.rel.ro and are
    resolvable through the ELF relocation table.
    """

    JNI_APPID = "Java_com_zeekr_env_ServerUtils_getNativeApplicationId"
    JNI_SECRET = "Java_com_zeekr_env_ServerUtils_getNativeSecret"
    JNI_HOST = "Java_com_zeekr_env_ServerUtils_getNativeHost"

    def __init__(self, so_path: str):
        super().__init__(so_path)
        self.md = Cs(CS_ARCH_ARM64, CS_MODE_ARM)
        self.md.detail = True

    @staticmethod
    def looks_like_new_format(so_path: str) -> bool:
        data = open(so_path, "rb").read()
        if b"getNativeApplicationId" not in data:
            return False
        # new format keeps >= 3 plaintext 32-hex app ids in .rodata
        return len(re.findall(rb"^[0-9a-f]{32}$", data, re.M)) >= 3 or \
               len(re.findall(rb"\x00[0-9a-f]{32}\x00", data)) >= 3

    def _disas(self, start: int, n: int = 60):
        off = self.vaddr_to_offset(start)
        if off is None:
            return []
        return list(self.md.disasm(self.data[off : off + n * 4], start))[:n]

    def _helper_addr(self, jni_name: str) -> int | None:
        """A JNI wrapper's first `bl` targets its lookup helper."""
        wrapper = self.symbols.get(jni_name)
        if wrapper is None:
            return None
        for insn in self._disas(wrapper, 24):
            if insn.mnemonic == "bl":
                return insn.operands[0].imm
        return None

    def _parse_helper(self, start: int) -> dict:
        """Return {stage_idx: ('table', va) | ('str', va)} for a lookup helper."""
        ins = self._disas(start, 30)
        jt_va = case_base = None
        for x in ins:
            if x.mnemonic == "adr" and jt_va is None:
                jt_va = x.operands[1].imm
            elif x.mnemonic == "adr" and jt_va is not None:
                case_base = x.operands[1].imm
                break
        if jt_va is None or case_base is None:
            return {}
        # number of stages from `cmp w9, #N` guarding the jump table
        count = 15
        for x in ins:
            if x.mnemonic == "cmp" and "#0x" in x.op_str:
                try:
                    count = int(x.op_str.split("#")[1].rstrip("]"), 0) + 1
                except ValueError:
                    pass
                break
        res = {}
        jt_off = self.vaddr_to_offset(jt_va)
        for stage in range(count):
            ca = case_base + self.data[jt_off + stage] * 4
            tbl = sva = None
            bins = self._disas(ca, 12)
            for j, x in enumerate(bins):
                if x.mnemonic == "adr" and "x10" in x.op_str:
                    tbl = x.operands[1].imm
                if (
                    x.mnemonic == "adrp"
                    and j + 1 < len(bins)
                    and bins[j + 1].mnemonic == "add"
                ):
                    sva = x.operands[1].imm + bins[j + 1].operands[2].imm
            res[stage] = ("table", tbl) if tbl else ("str", sva)
        return res

    def resolve_grid(self, jni_name: str) -> dict:
        """Return {stage_idx: [4 strings]} (or {stage_idx: [string]} for fixed)."""
        helper = self._helper_addr(jni_name)
        if helper is None:
            return {}
        grid = {}
        for stage, (kind, va) in self._parse_helper(helper).items():
            if kind == "table" and va:
                grid[stage] = [self.deref_str(va + i * 8) for i in range(4)]
            elif va:
                grid[stage] = [self.cstr(va)]
        return grid

    def find_hmac_keys(self, region: str = "EM"):
        """Return (access_key, secret_key, debug_info) for the requested region."""
        appid_grid = self.resolve_grid(self.JNI_APPID)
        secret_grid = self.resolve_grid(self.JNI_SECRET)
        host_grid = self.resolve_grid(self.JNI_HOST)
        if not appid_grid or not secret_grid:
            return None, None, {"error": "no plaintext tables resolved"}

        pattern = REGION_HOST_PATTERNS.get(region, REGION_HOST_PATTERNS["EM"])

        # find env row whose prod host matches the region pattern
        matches = []
        for stage, hosts in host_grid.items():
            prod_host = hosts[PROD_STAGE_INDEX] if len(hosts) > PROD_STAGE_INDEX else hosts[0]
            if prod_host and pattern in prod_host:
                matches.append(stage)

        debug = {"host_grid": host_grid, "matches": matches, "pattern": pattern}

        if not matches:
            return None, None, debug

        # prefer the first matching row that has both tables populated
        for stage in matches:
            appids = appid_grid.get(stage, [])
            secrets = secret_grid.get(stage, [])
            if len(appids) > PROD_STAGE_INDEX and len(secrets) > PROD_STAGE_INDEX:
                access_key = appids[PROD_STAGE_INDEX]
                secret_key = secrets[PROD_STAGE_INDEX]
                if access_key and secret_key:
                    return access_key, secret_key, debug
        return None, None, debug


# ============================================================================
# Legacy native library analyzer (app <= 1.5.5, OLLVM-encrypted libenv.so)
# ============================================================================

class NativeLibAnalyzer(ElfHelper):
    """Analyze ARM64 native libraries to decrypt OLLVM-encrypted strings."""

    def decrypt_strings(self) -> dict:
        """Decrypt all OLLVM-encrypted strings using ARM64 disassembly."""
        code_end = 0
        for seg_vaddr, seg_offset, seg_filesz, seg_memsz in self.segments:
            if seg_offset == 0:
                code_end = seg_filesz
                break

        if code_end == 0:
            return {}

        md = Cs(CS_ARCH_ARM64, CS_MODE_ARM)
        md.detail = True

        best_offset = None
        best_density = 0
        chunk_size = 0x200

        for offset in range(0, min(code_end, len(self.data)) - chunk_size, 0x100):
            chunk = self.data[offset : offset + chunk_size]
            eor_count = sum(1 for i in md.disasm(chunk, offset) if i.mnemonic == "eor")
            density = eor_count / (chunk_size / 4)
            if density > best_density:
                best_density = density
                best_offset = offset

        if best_offset is None or best_density < 0.05:
            return {}

        func_start = best_offset
        for offset in range(best_offset, max(0, best_offset - 0x1000), -4):
            word = struct.unpack_from("<I", self.data, offset)[0]
            if (word & 0xFFE00000) == 0xA9800000:
                func_start = offset
                break

        func_data = self.data[func_start:code_end]
        instructions = list(md.disasm(func_data, func_start))

        xor_ops = []
        current_base = None

        for i in range(len(instructions)):
            insn = instructions[i]

            if insn.mnemonic == "adr" and len(insn.operands) == 2:
                current_base = insn.operands[1].imm
                continue

            if insn.mnemonic == "adrp" and i + 1 < len(instructions):
                next_insn = instructions[i + 1]
                if next_insn.mnemonic == "add":
                    current_base = insn.operands[1].imm + next_insn.operands[2].imm
                    continue

            if (
                insn.mnemonic == "ldrb"
                and i + 2 < len(instructions)
                and instructions[i + 1].mnemonic == "mov"
                and instructions[i + 2].mnemonic == "eor"
            ):
                mem = insn.operands[1]
                if mem.type == 3 and current_base is not None:
                    target_addr = current_base + mem.mem.disp
                    xor_val = instructions[i + 1].operands[1].imm & 0xFF
                    xor_ops.append((target_addr, xor_val))
                continue

            if (
                insn.mnemonic == "ldrb"
                and i + 1 < len(instructions)
                and instructions[i + 1].mnemonic == "eor"
            ):
                eor_insn = instructions[i + 1]
                if len(eor_insn.operands) == 3 and eor_insn.operands[2].type == 2:
                    mem = insn.operands[1]
                    if mem.type == 3 and current_base is not None:
                        target_addr = current_base + mem.mem.disp
                        xor_val = eor_insn.operands[2].imm & 0xFF
                        xor_ops.append((target_addr, xor_val))
                continue

        if not xor_ops:
            return {}

        extended = bytearray(self.data) + bytearray(0x10000)
        for addr, xor_val in xor_ops:
            off = self.vaddr_to_offset(addr)
            if off is not None and off < len(extended):
                extended[off] ^= xor_val

        addr_min = min(a for a, _ in xor_ops)
        addr_max = max(a for a, _ in xor_ops)
        off_start = self.vaddr_to_offset(addr_min)
        off_end = self.vaddr_to_offset(addr_max)

        if off_start is None or off_end is None:
            return {}

        off_end += 100

        strings = {}
        current = []
        str_start = off_start
        for j in range(off_start, min(off_end, len(extended))):
            b = extended[j]
            if b == 0:
                if len(current) >= 2:
                    s = bytes(current).decode("utf-8", errors="replace")
                    vaddr = addr_min + (str_start - off_start)
                    strings[vaddr] = s
                current = []
                str_start = j + 1
            elif 32 <= b < 127:
                current.append(b)
            else:
                current = []
                str_start = j + 1

        return strings

    @staticmethod
    def _split_into_tables(entries, max_gap=8):
        if not entries:
            return []
        tables = []
        current = [entries[0]]
        for i in range(1, len(entries)):
            gap = entries[i][0] - entries[i - 1][0]
            if gap > max_gap:
                tables.append(current)
                current = [entries[i]]
            else:
                current.append(entries[i])
        tables.append(current)
        return tables

    def find_hmac_keys(self, region: str = "EM") -> tuple:
        """Find HMAC access key and secret key (legacy OLLVM layout)."""
        strings = self.decrypt_strings()
        if not strings:
            return None, None, strings

        hex32 = re.compile(r"^[0-9a-f]{32}$")
        alnum40 = re.compile(r"^[0-9a-z]{40}$")

        region_idx = REGION_INDICES.get(region, 3)
        env_group = PROD_ENV_GROUP_EU if region == "EU" else PROD_ENV_GROUP
        target_idx = env_group * REGIONS_PER_ENV + region_idx

        appid_entries = []
        secret_entries = []

        for reloc_off in sorted(self.relocs.keys()):
            target_vaddr = self.relocs[reloc_off]
            if target_vaddr in strings:
                s = strings[target_vaddr]
                if hex32.match(s):
                    appid_entries.append((reloc_off, s))
                elif alnum40.match(s):
                    secret_entries.append((reloc_off, s))

        access_key = None
        appid_tables = self._split_into_tables(appid_entries)
        if appid_tables:
            main_table = max(appid_tables, key=len)
            if target_idx < len(main_table):
                access_key = main_table[target_idx][1]

        secret_key = None
        secret_tables = self._split_into_tables(secret_entries)
        if secret_tables:
            main_table = max(secret_tables, key=len)
            if target_idx < len(main_table):
                secret_key = main_table[target_idx][1]
            else:
                for table in secret_tables:
                    if target_idx < len(table):
                        secret_key = table[target_idx][1]
                        break

        return access_key, secret_key, strings


# ============================================================================
# DEX Secret Extraction
# ============================================================================

def extract_dex_files(apk_path: str, output_dir: str) -> list:
    """Extract all DEX files from an APK."""
    dex_files = []
    with zipfile.ZipFile(apk_path, "r") as z:
        for name in z.namelist():
            if name.endswith(".dex"):
                z.extract(name, output_dir)
                dex_files.append(os.path.join(output_dir, name))
    return sorted(dex_files)


def extract_native_libs(apk_path: str, output_dir: str) -> list:
    """Extract ARM64 native libraries from an APK."""
    so_files = []
    with zipfile.ZipFile(apk_path, "r") as z:
        for name in z.namelist():
            if "arm64" in name and name.endswith(".so"):
                z.extract(name, output_dir)
                so_files.append(os.path.join(output_dir, name))
    return so_files


def find_rsa_public_key(dex_files: list) -> str | None:
    """Find the RSA public key for password encryption."""
    base64_chars = set(
        b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/="
    )
    prefix = b"MIGfMA0GCSq"

    for dex_path in dex_files:
        try:
            with open(dex_path, "rb") as f:
                data = f.read()

            idx = 0
            while True:
                idx = data.find(prefix, idx)
                if idx == -1:
                    break

                end = idx
                while end < len(data) and data[end] in base64_chars:
                    end += 1

                key = data[idx:end].decode("ascii")
                if 200 <= len(key) <= 400:
                    return key
                idx = end
        except Exception:
            continue
    return None


def find_prod_secret(dex_files: list) -> list:
    """Find all prod secret candidates for X-SIGNATURE HMAC computation."""
    pattern = re.compile(rb"\x20([0-9a-f]{32})\x00")
    sig_candidates = []
    other_candidates = []

    for dex_path in dex_files:
        try:
            with open(dex_path, "rb") as f:
                data = f.read()
            has_sig = b"X-SIGNATURE" in data
            for match in pattern.finditer(data):
                val = match.group(1).decode("ascii")
                if has_sig:
                    if val not in sig_candidates:
                        sig_candidates.append(val)
                else:
                    if val not in other_candidates:
                        other_candidates.append(val)
        except Exception:
            continue

    all_candidates = sig_candidates + [v for v in other_candidates if v not in sig_candidates]
    return all_candidates


def find_vin_keys(dex_files: list) -> tuple:
    """Find the VIN encryption key and IV (plaintext, app <= 1.5.5 only)."""
    per_dex = {}
    for dex_path in dex_files:
        try:
            with open(dex_path, "rb") as f:
                data = f.read()

            if b"AES/CBC/PKCS5Padding" not in data:
                continue

            pattern = re.compile(rb"\x10([0-9a-f]{16})\x00")
            vals = []
            seen = set()
            for match in pattern.finditer(data):
                val = match.group(1).decode("ascii")
                if val not in TRIVIAL_HEX16 and val not in seen:
                    seen.add(val)
                    vals.append(val)
            if vals:
                per_dex[os.path.basename(dex_path)] = vals
        except Exception:
            continue

    if not per_dex:
        return None, None

    for dex_name, vals in sorted(per_dex.items()):
        if len(vals) == 2:
            return vals[0], vals[1]

    for dex_name, vals in sorted(per_dex.items()):
        if len(vals) >= 2:
            return vals[0], vals[1]
        elif len(vals) == 1:
            for other_name, other_vals in sorted(per_dex.items()):
                if other_name != dex_name:
                    for v in other_vals:
                        if v != vals[0]:
                            return vals[0], v
            return vals[0], None

    return None, None


def uses_iwall_ecies(dex_files: list) -> bool:
    """Detect the >= 1.5.7 iWall ECIES setup (fi.a + SecuritySuiteSDK)."""
    for dex_path in dex_files:
        try:
            with open(dex_path, "rb") as f:
                data = f.read()
            if b"Lfi/a;" in data and b"SecuritySuiteSDK" in data:
                return True
        except Exception:
            continue
    return any(
        b"SecuritySuiteSDK" in open(p, "rb").read() for p in dex_files[:20]
    )


FRIDA_HINT = """
  Runtime alternative (Frida, rooted device or emulator):

    // vin_hook.js - prints VIN AES key/IV at runtime
    Java.perform(function () {
      var A = Java.use('cj.a');
      A.h.implementation = function (content, key, iv) {
        console.log('VIN key: ' + key);
        console.log('VIN IV:  ' + iv);
        return this.h(content, key, iv);
      };
    });

    frida -U -l vin_hook.js com.zeekr.global
    (then trigger any vehicle API call in the app)
"""


# ============================================================================
# Main Extraction Pipeline
# ============================================================================

# secrets 字典的键 → .env 的键
ENV_MAPPING = {
    "hmac_access_key": "ZEEKR_HMAC_ACCESS_KEY",
    "hmac_secret_key": "ZEEKR_HMAC_SECRET_KEY",
    "password_public_key": "ZEEKR_PASSWORD_PUBLIC_KEY",
    "prod_secret": "ZEEKR_PROD_SECRET",
    "vin_key": "ZEEKR_VIN_KEY",
    "vin_iv": "ZEEKR_VIN_IV",
}


def write_env(secrets: dict, env_path: Path) -> None:
    """把密钥填进 .env 的**空位**。

    只替换 `KEY=` 后面为空的行，已有值的一律不动 ——
    重跑脚本不会覆盖你手工修正过的值（例如从候选里试出来的 prod_secret）。
    """
    if not env_path.is_file():
        print(f"\n  [!!] 找不到 {env_path} —— 请先 cp .env.example .env")
        return

    text = env_path.read_text(encoding="utf-8")
    filled, skipped = [], []

    for src, dst in ENV_MAPPING.items():
        value = (secrets.get(src) or "").strip()
        if not value:
            skipped.append((dst, "本次未提取到"))
            continue
        # 用函数式替换：密钥里可能出现反斜杠或 \g，当替换串会出错
        new_text, n = re.subn(
            rf"(?m)^{re.escape(dst)}=[ \t]*$",
            lambda _m, _k=dst, _v=value: f"{_k}={_v}",
            text,
        )
        if n == 0:
            skipped.append((dst, "无空位（可能已有值）"))
            continue
        text = new_text
        filled.append(dst)

    env_path.write_text(text, encoding="utf-8")
    print(f"\n  已写入 {env_path}：")
    for k in filled:
        print(f"    ✓ {k}")
    for k, why in skipped:
        print(f"    - {k}  ({why})")


def extract_secrets(
    base_apk: str,
    arm64_apk: str = None,
    region: str = "CN",
    out_path: str | None = None,
    env_path: str | None = None,
):
    """提取全部 6 个密钥，按需落盘 JSON 与写入 .env。"""
    secrets = {
        "hmac_access_key": None,
        "hmac_secret_key": None,
        "password_public_key": None,
        "prod_secret": None,
        "prod_secret_candidates": [],
        "vin_key": None,
        "vin_iv": None,
    }

    with tempfile.TemporaryDirectory() as tmpdir:
        print(f"\n{'=' * 60}")
        print(f"  Zeekr APK Secret Extractor")
        print(f"  Target region: {region}")
        print(f"{'=' * 60}\n")

        # Step 1: Extract DEX files
        print("[1/4] Extracting DEX files from base APK...")
        dex_files = extract_dex_files(base_apk, tmpdir)
        print(f"      Found {len(dex_files)} DEX files")

        # Step 2: Extract native libraries
        print("[2/4] Extracting native libraries...")
        so_files = []
        if arm64_apk:
            so_files = extract_native_libs(arm64_apk, tmpdir)
        if not so_files:
            so_files = extract_native_libs(base_apk, tmpdir)
        print(f"      Found {len(so_files)} native libraries")

        # Step 3: Extract Java-level secrets from DEX files
        print("[3/4] Searching DEX files for secrets...")

        print("      Looking for RSA password public key...")
        key = find_rsa_public_key(dex_files)
        if key:
            secrets["password_public_key"] = key
            print(f"      [OK] Password Public Key ({len(key)} chars)")
        else:
            print("      [!!] Password Public Key: NOT FOUND")

        print("      Looking for prod secret...")
        prod_candidates = find_prod_secret(dex_files)
        if prod_candidates:
            secrets["prod_secret"] = prod_candidates[0]
            secrets["prod_secret_candidates"] = prod_candidates
            if len(prod_candidates) == 1:
                print(f"      [OK] Prod Secret: {mask(prod_candidates[0])}")
            else:
                print(f"      [OK] Prod Secret: {mask(prod_candidates[0])} (primary)")
                for i, c in enumerate(prod_candidates[1:], 2):
                    print(f"      [OK] Prod Secret candidate {i}: {mask(c)}")
        else:
            print("      [!!] Prod Secret: NOT FOUND")

        print("      Looking for VIN encryption key and IV...")
        vin_key, vin_iv = find_vin_keys(dex_files)
        if vin_key and vin_iv:
            secrets["vin_key"] = vin_key
            secrets["vin_iv"] = vin_iv
            print(f"      [OK] VIN Key: {mask(vin_key)}")
            print(f"      [OK] VIN IV:  {mask(vin_iv)}")
        else:
            print("      [!!] VIN Key/IV: NOT FOUND in plaintext DEX")
            if uses_iwall_ecies(dex_files):
                print("      [..] This APK stores the VIN key/IV as iWall ECIES-encrypted")
                print("           blobs (fi.a / SecuritySuiteSDK) - static extraction is not")
                print("           possible. Options:")
                print("           1) Extract VIN key/IV from a v1.5.5 APK instead - those")
                print("              values are still accepted by the Zeekr API")
                print("           2) Hook the running app with Frida (see README)")

        # Step 4: Extract HMAC keys from native library
        print("[4/4] Resolving HMAC keys from libenv.so...")

        libenv_path = None
        for so_path in so_files:
            if "libenv.so" in so_path:
                libenv_path = so_path
                break

        if libenv_path is None:
            print("      [!!] libenv.so not found!")
            print("      Make sure to provide the ARM64 split APK")
        elif EnvTableResolver.looks_like_new_format(libenv_path):
            print("      Detected new plaintext table layout (app >= 1.5.7)")
            resolver = EnvTableResolver(libenv_path)
            access_key, secret_key, debug = resolver.find_hmac_keys(region)
            if access_key and secret_key:
                secrets["hmac_access_key"] = access_key
                secrets["hmac_secret_key"] = secret_key
                print(f"      [OK] HMAC Access Key: {mask(access_key)}")
                print(f"      [OK] HMAC Secret Key: {mask(secret_key)}")
            else:
                print("      [!!] Could not resolve keys for this region.")
                print(f"      Searched host pattern: {debug.get('pattern')}")
                grid = debug.get("host_grid", {})
                if grid:
                    print("      Available environment rows (stage -> prod host):")
                    for stage, hosts in sorted(grid.items()):
                        prod = hosts[PROD_STAGE_INDEX] if len(hosts) > PROD_STAGE_INDEX else hosts
                        print(f"        stage {stage}: {prod}")
        else:
            print("      Detected legacy OLLVM layout (app <= 1.5.5)")
            print("      Disassembling and decrypting libenv.so...")
            analyzer = NativeLibAnalyzer(libenv_path)
            access_key, secret_key, all_strings = analyzer.find_hmac_keys(region)

            if access_key:
                secrets["hmac_access_key"] = access_key
                print(f"      [OK] HMAC Access Key: {mask(access_key)}")
            else:
                print("      [!!] HMAC Access Key: NOT FOUND")
                hex32 = re.compile(r"^[0-9a-f]{32}$")
                candidates = [
                    (a, s) for a, s in sorted(all_strings.items()) if hex32.match(s)
                ]
                if candidates:
                    print(f"      {len(candidates)} potential candidates found:")
                    for addr, val in candidates:
                        print(f"        0x{addr:x}: {mask(val)}")

            if secret_key:
                secrets["hmac_secret_key"] = secret_key
                print(f"      [OK] HMAC Secret Key: {mask(secret_key)}")
            else:
                print("      [!!] HMAC Secret Key: NOT FOUND")
                alnum40 = re.compile(r"^[0-9a-z]{40}$")
                candidates = [
                    (a, s) for a, s in sorted(all_strings.items()) if alnum40.match(s)
                ]
                if candidates:
                    print(f"      {len(candidates)} potential candidates found:")
                    for addr, val in candidates:
                        print(f"        0x{addr:x}: {mask(val)}")

    # Print summary
    print(f"\n{'=' * 60}")
    print(f"  RESULTS")
    print(f"{'=' * 60}\n")

    all_found = True
    for key, value in secrets.items():
        if key == "prod_secret_candidates":
            continue
        status = "[OK]" if value else "[MISSING]"
        if value:
            display = mask(value)
        else:
            display = "NOT FOUND"
            if key not in ("vin_key", "vin_iv"):
                all_found = False
        print(f"  {status} {key}: {display}")
    candidates = secrets.get("prod_secret_candidates", [])
    if len(candidates) > 1:
        print(f"\n  NOTE: Multiple prod_secret candidates found. If the primary")
        print(f"  value does not work, try the others:")
        for i, c in enumerate(candidates, 1):
            print(f"    {i}. {mask(c)}")

    if all_found and secrets["vin_key"]:
        print(f"\n  All 6 secrets extracted successfully!")
    elif all_found:
        print(f"\n  4 of 6 secrets extracted. VIN key/IV require a v1.5.5 APK")
        print(f"  or runtime extraction (see notes above).")
    else:
        print(f"\n  Some secrets could not be extracted automatically.")
        print(f"  You may need to use JADX for manual inspection.")

    # 落盘
    output_path = (
        Path(out_path) if out_path
        else Path(base_apk).resolve().parent / "zeekr_secrets.json"
    )
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(
        json.dumps(secrets, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    print(f"\n  密钥已写入：{output_path}")
    print("  （该文件名已被 .gitignore 忽略，不会进版本库）")

    if env_path:
        write_env(secrets, Path(env_path))

    return secrets


def main():
    parser = argparse.ArgumentParser(
        description="ZeekrDash：从官方极氪 APK 提取 6 个网关密钥（不需要安卓设备）",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
例子：
  # 最常用：整包 + 直接写进 .env（从项目根运行）
  %(prog)s ~/Downloads/com.zeekrlife.mobile-*.apk --write-env

  # 分片包（base.apk + split_config.arm64_v8a.apk）
  %(prog)s base.apk split_config.arm64_v8a.apk --write-env

  # 要看密钥明文（会打印到终端，注意录屏与 shell 历史）
  %(prog)s <apk> --show

APK 从哪来：
  CN 包名 com.zeekrlife.mobile。PC 上从应用宝等商店下整包即可 ——
  整包里已含 lib/arm64-v8a/libenv.so，所以不必再传第二个分片参数。
        """,
    )
    parser.add_argument("base_apk", type=Path, help="官方 APK 路径（整包即可）")
    parser.add_argument(
        "arm64_apk",
        nargs="?",
        type=Path,
        help="ARM64 分片 APK（可选；整包时无需提供）",
    )
    parser.add_argument(
        "--region",
        default="CN",
        choices=["CN", "SEA", "EU", "EM"],
        help="目标区域（默认 CN —— 本项目场景）",
    )
    parser.add_argument(
        "-o",
        "--out",
        type=Path,
        default=Path("docs/zeekr_secrets.json"),
        help="提取结果落盘位置（默认 docs/zeekr_secrets.json，已被 .gitignore 忽略）",
    )
    parser.add_argument(
        "--write-env",
        nargs="?",
        const="server/.env",
        type=Path,
        default=None,
        metavar="PATH",
        help="把密钥填进 .env 的空位（不带值时用默认的 server/.env）",
    )
    parser.add_argument(
        "--show",
        action="store_true",
        help="回显密钥明文（默认只显示掩码，避免留在终端日志与录屏里）",
    )
    args = parser.parse_args()

    global SHOW_SECRETS
    SHOW_SECRETS = args.show

    if not args.base_apk.is_file():
        print(f"ERROR: File not found: {args.base_apk}")
        sys.exit(1)
    if args.arm64_apk and not args.arm64_apk.is_file():
        print(f"ERROR: File not found: {args.arm64_apk}")
        sys.exit(1)

    extract_secrets(
        str(args.base_apk),
        str(args.arm64_apk) if args.arm64_apk else None,
        args.region,
        str(args.out),
        str(args.write_env) if args.write_env else None,
    )


if __name__ == "__main__":
    main()
