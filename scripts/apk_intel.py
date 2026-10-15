#!/usr/bin/env python3
"""从官方极氪 APK 提取接口情报，并渲染成参考文档；可对比历史版本。

一次性产出两个文件（默认落在 docs/）：
  zeekr-apk-reference.md   人读的接口与字段目录
  zeekr-apk-intel.json     机器可读的原始情报（不丢数据）

为什么要这个脚本：
官方 App 已加固（libconch.so 等），JADX 只能解析 23 个类 —— 类级反编译
不可用，没有现成工具能替代解析。但 **DEX 字符串表是明文可读的**，
本脚本据此把"能为我们所用的接口情报"固化成仓库内的文件，
以后升级 App 只需重跑一次，不必再从头逆向。

**极氪 App 更新后怎么用**（这是本脚本的主要用途之一）：
    python scripts/apk_intel.py <新版apk> --compare docs/zeekr-apk-intel.json
产出 docs/zeekr-apk-diff.md，并检查 ZeekrDash 依赖的路径/字段（CONTRACT_*）
在新版本里是否还在 —— 不在就是破坏性变更，退出码为 1。
新快照另存为 zeekr-apk-intel-new.json，**不覆盖**基准，确认后再手动替换。

依赖：无（仅标准库）

用法：
    python scripts/apk_intel.py <apk路径>
    python scripts/apk_intel.py <apk路径> --out-dir docs
    python scripts/apk_intel.py <apk路径> --json-only
    python scripts/apk_intel.py <apk路径> --compare docs/zeekr-apk-intel.json
"""

from __future__ import annotations

import argparse
import json
import re
import sys
import zipfile
from collections import defaultdict
from pathlib import Path

# ═══════════════════════════════════════════════════════════════
# 第一部分：从 DEX 提取
# ═══════════════════════════════════════════════════════════════

# Java/Kotlin 包名前缀 —— 不是接口路径，必须排除
JAVA_ROOTS = {
    "Lcom", "com", "org", "android", "androidx", "java", "javax", "kotlin", "kotlinx",
    "io", "net", "okhttp3", "okio", "retrofit2", "rx", "META-INF", "assets", "res",
    "lib", "ck", "jp", "uk", "de", "fr", "ru", "cn", "us",
}

# 主机识别用的域名后缀
HOST_RE = re.compile(
    rb"https?://[a-z0-9][a-z0-9\-\.]{4,60}\."
    rb"(?:zeekrlife\.com|zeekrlife\.cn|geely\.com|geely-test\.com|zeekr\.eu|zeekrlife\.eu)"
    rb"(?::\d{2,5})?(?:/[A-Za-z0-9_\-/\.]{0,60})?"
)

# 真正的接口路径必带版本段（/v1/、/v1.0/、/v2/…）。
# 只按"斜杠+小写开头"过滤会把 Java 全限定类名（/zeekrlife/appinit/api/Foo）
# 也收进来 —— 实测 36 万条噪声 vs 1000 余条真接口。
VERSION_SEG = re.compile(r"^(?:v\d+(?:\.\d+)?|\d+\.\d+)$")
PATH_RE = re.compile(rb"/[A-Za-z0-9][A-Za-z0-9_/\.\-]{6,90}")
TOKEN_RE = re.compile(rb"(?<![A-Za-z0-9_])([A-Za-z][A-Za-z0-9_]{4,50})")
HEADER_RE = re.compile(
    rb"(?<![A-Za-z0-9_\-])([Xx]-[A-Za-z0-9]+(?:-[A-Za-z0-9]+){1,4})(?![A-Za-z0-9_\-])"
)

# 字段名按关键词归类
KEYWORDS = {
    "door": "门", "window": "窗", "lock": "锁", "tyre": "胎压", "tire": "胎压",
    "trunk": "后备箱", "frunk": "前备箱", "hood": "引擎盖",
    "climate": "空调", "temperature": "温度", "fan": "风量",
    "seat": "座椅", "charge": "充电", "soc": "电量", "range": "续航",
    "mileage": "里程", "odometer": "里程", "consumption": "能耗", "energy": "能耗",
    "speed": "车速", "voltage": "电压", "current": "电流", "power": "功率",
    "position": "位置", "latitude": "纬度", "longitude": "经度", "gps": "定位",
    "battery": "电池", "light": "灯光", "horn": "鸣笛", "sunroof": "天窗",
    "sunshade": "遮阳帘", "mirror": "后视镜", "steering": "方向盘",
    "fragrance": "香氛", "fridge": "冰箱", "oxygen": "供氧", "sentinel": "哨兵",
    "fence": "围栏", "guard": "安防", "trip": "行程", "journey": "行程",
    "track": "轨迹", "address": "地址", "nickname": "昵称", "plate": "车牌",
}

RO_CONST = ("get", "set", "is", "on", "has", "can", "to", "from", "with")
NOISE_HOST = ("oss", "cdn", "static", "showcar", "IMAGE/", "download", "atom", "frontend")
NOISE_PATH = (".png", ".jpg", ".js", ".json", ".xml", ".html", "/R/", "/R$")


def extract(apk: Path) -> dict:
    """从 APK 的 classes.dex 提取全部情报。"""
    with zipfile.ZipFile(apk) as z:
        names = z.namelist()
        dexes = [n for n in names if n.endswith(".dex")]
        if not dexes:
            raise SystemExit(f"✗ {apk} 里没有 .dex 文件")
        print(f"读取 {dexes[0]} …", file=sys.stderr)
        dex = z.read(dexes[0])
    print(f"  {len(dex):,} 字节", file=sys.stderr)

    intel: dict = {"source_apk": apk.name, "dex_entries": dexes}

    # 主机
    hosts: dict[str, int] = defaultdict(int)
    for m in HOST_RE.finditer(dex):
        hosts[m.group().decode("latin-1")] += 1
    gateways = {k: v for k, v in hosts.items()
                if not any(n.lower() in k.lower() for n in NOISE_HOST)}
    intel["gateways"] = dict(sorted(gateways.items(), key=lambda x: -x[1]))
    intel["gateways_filtered_out"] = dict(sorted(
        {k: v for k, v in hosts.items() if k not in gateways}.items(), key=lambda x: -x[1]))

    # 接口路径
    services: dict[str, dict[str, int]] = defaultdict(dict)
    dropped = 0
    for m in PATH_RE.finditer(dex):
        p = m.group().decode("latin-1")
        parts = p.split("/")
        if len(parts) < 3:
            continue
        head = parts[1]
        if head in JAVA_ROOTS or head.startswith("L"):
            continue
        if any(x in p for x in NOISE_PATH):
            continue
        if not any(VERSION_SEG.fullmatch(seg) for seg in parts):
            dropped += 1
            continue
        services[head][p] = services[head].get(p, 0) + 1
    intel["dropped_non_api_paths"] = dropped
    intel["services"] = {k: sorted(v) for k, v in
                         sorted(services.items(), key=lambda x: -len(x[1]))}

    # 请求头
    headers: dict[str, int] = defaultdict(int)
    for m in HEADER_RE.finditer(dex):
        headers[m.group(1).decode("latin-1")] += 1
    intel["headers"] = dict(sorted(headers.items(), key=lambda x: -x[1]))

    # 应用标识
    ids: set[str] = set()
    for pat in (rb"ZEEKRCNCH\d+M\d+", rb"GEELYCNCH\d+M\d+", rb"ZEEKR_[A-Z]{2,12}",
                rb"[A-Z]{4,}CNCH[A-Z0-9]{4,20}"):
        for m in re.finditer(pat, dex):
            ids.add(m.group().decode("latin-1"))
    intel["app_ids"] = sorted(ids)

    # 标识符：能力标志 + 字段名候选
    supported: dict[str, int] = defaultdict(int)
    fields: dict[str, int] = defaultdict(int)
    for m in TOKEN_RE.finditer(dex):
        t = m.group(1).decode("latin-1")
        if t.endswith("Supported") and not t.startswith("get"):
            supported[t] += 1
        if (t[0].islower() and 5 <= len(t) <= 40 and "_" not in t
                and not t.startswith(RO_CONST)):
            fields[t] += 1
    intel["capability_flags"] = dict(sorted(supported.items(), key=lambda x: -x[1]))

    grouped: dict[str, dict[str, int]] = defaultdict(dict)
    for name, cnt in fields.items():
        low = name.lower()
        for kw, label in KEYWORDS.items():
            if kw in low:
                grouped[label][name] = cnt
                break
    intel["field_candidates_by_topic"] = {
        k: dict(sorted(v.items(), key=lambda x: -x[1])[:120])
        for k, v in sorted(grouped.items(), key=lambda x: -len(x[1]))
    }

    intel["packages"] = sorted({
        m.group().decode("latin-1")
        for m in re.finditer(rb"com\.(?:zeekrlife|zeekr|geely)\.[a-z0-9\._]{2,50}", dex)
    })[:400]

    # 契约命中证据 —— `--compare` 靠它判断"官方是否改了接口/字段名"。
    #
    # 为什么在这里算、而不是在 compare 里从 field_candidates_by_topic 反推：
    # 那张表按关键词分类、且每类只留 top 120，会漏掉一些字段（实测
    # temInterior、posCanBeTrusted、lockStatus 都被漏掉，导致自比对误报
    # "契约消失"）。这里直接对 DEX 原始字节计数，不受分类规则与截断影响。
    # CONTRACT_* 定义在文件后部，但 main() 调用 extract() 时模块已加载完，可解析。
    intel["contract_hits"] = {
        "paths": {p: dex.count(p.encode()) for p, _note in CONTRACT_PATHS},
        "fields": {
            f: len(re.findall(re.escape(f).encode(), dex, re.I))
            for f in CONTRACT_FIELDS
        },
    }

    return intel


# ═══════════════════════════════════════════════════════════════
# 第二部分：渲染成人读文档
# ═══════════════════════════════════════════════════════════════

OWN_PREFIXES = ("ms-", "zeekrlife", "zeekr-", "app", "auth", "login", "user", "vehicle",
                "account", "core", "haohan", "plugCharger")

VEHICLE_SERVICES = [
    "ms-vehicle-status", "ms-vehicle-core", "ms-vehicle-account", "ms-vehicle-trail",
    "ms-vehicle-defence", "ms-vehicle-guard", "ms-vehicle-extend",
    "ms-vehicle-capability-set", "ms-remote-control", "ms-charge-manage",
    "ms-app-bff", "ms-tsp-user-vehicle", "ms-tsp-user-setting",
    "ms-iot-control", "ms-iot-device", "ms-iot-status",
]

SERVICE_NOTES = {
    "ms-vehicle-status": "车况读取（主快照 v2.0 / vtm / qrvs / 冰箱 / 电源模式）",
    "ms-vehicle-core": "车辆信息管理（收藏、默认车、昵称、车牌）",
    "ms-vehicle-account": "车辆详情与车型目录",
    "ms-vehicle-trail": "行程与轨迹（journalLog）",
    "ms-vehicle-defence": "电子围栏（fence CRUD）",
    "ms-vehicle-guard": "哨兵模式照片",
    "ms-vehicle-extend": "车辆审核记录等扩展",
    "ms-vehicle-capability-set": "**车辆能力集** —— 先问车支持什么，再决定 UI 显示什么",
    "ms-remote-control": "车控（control / queryProcessResult / AI 空调 / 供氧 / 温度模式）",
    "ms-charge-manage": "充电（控制、SOC、充电计划、出行计划、预约）",
    "ms-app-bff": "BFF 聚合（权限、空调日程、冰箱/香氛、维修模式授权）",
    "ms-tsp-user-vehicle": "车辆共享（分享 / 接受 / 授权全套）",
    "ms-user-auth": "账号与生物识别（扫描登录、CSP、人脸）",
    "ms-midground-user": "用户中台",
    "ms-iot-control": "IoT 设备控制",
    "ms-iot-device": "IoT 设备管理",
    "ms-iot-status": "IoT 设备状态",
    "ms-app-online-center": "在线中心心跳",
    "ms-app-message-center": "消息中心",
    "ms-lbs-service": "位置服务（sendToCar）",
    "ms-ai-cloud": "AI 云端能力",
    "ms-log": "日志上报",
    "ms-user-manager": "用户管理",
    "ms-tsp-dkbs-geely": "DKBS（数字钥匙/车控相关，吉利侧）",
    "ms-tsp-bks-geely": "BKS（吉利侧）",
    "zeekrlife-app-user": "App 用户服务（登录 / 账号 / 配置 / 地址簿）",
    "zeekrlife-mp-order": "订单（商城）",
    "zeekrlife-mp-integral": "积分",
    "zeekrlife-bbs-theme": "社区",
    "zeekrlife-config-order": "配置下单",
    "zeekr-ud-ota": "OTA 升级",
    "scenario-personalization": "场景个性化",
    "login": "登录 / 换令牌",
    "auth": "OAuth2",
}

PHYSICAL_LABELS = ("门", "窗", "锁", "胎压", "后备箱", "前备箱", "引擎盖",
                   "空调", "温度", "座椅", "充电", "电量", "续航", "能耗",
                   "车速", "电压", "电流", "功率", "位置", "电池", "安防", "哨兵")

VERIFIED_FIELDS = [
    ("动力电池 SOC", "electricVehicleStatus.chargeLevel", "soc", "✅ 命中 5/7 次"),
    ("充电流 / 压", "chargeIAct / chargeUAct", "chargeCurrent / chargeVoltage", "✅ 命中 4/4"),
    ("续航", "distanceToEmptyOnBatteryOnly / distanceToEmpty", "rangeKm", "✅ 命中 4/8"),
    ("预计充满", "timeToFullyCharged", "minutesToFull", "✅ 命中 7 次"),
    ("充电枪连接", "statusOfChargerConnection", "isPlugged", "✅ 命中 4 次"),
    ("充电功率", "chargePower", "chargePowerKw", "✅ 命中 2 次"),
    ("定位", "latitude / longitude", "latitude / longitude", "✅ 命中 57/48"),
    ("定位可信", "posCanBeTrusted", "positionTrusted", "✅ 命中 4 次"),
    ("锁车", "lockStatus / centralLockingStatus", "isLocked", "✅ 命中 83/6"),
    ("后备箱", "trunkStatus", "trunkOpen", "✅ 命中 6 次"),
    ("胎压", "tyreStatusDriver / tyreStatusPassenger", "tyreFrontLeft / tyreFrontRight", "✅ 命中 8/8"),
    ("空调", "preClimateActive", "climateOn", "✅ 命中 4 次"),
    ("车内温度", "temInterior", "interiorTemp", "✅ 命中 6 次"),
    ("总里程", "odometer / totalMileage", "odometerKm", "✅ 命中 5/2"),
    ("车门（四门）", "leftFrontDoorStatus / rightBackDoorStatus", "doors.*", "✅ 命中（getter 反推）"),
    ("车窗（四窗）", "leftFrontWindowStatus / rightBackWindowStatus", "windows.*", "✅ 命中（getter 反推）"),
    ("前备箱", "frunkOpenStatus", "frunkOpen", "✅ 命中（getter 反推）"),
    ("引擎盖", "engineHoodOpenStatus", "—", "✅ 命中，尚未接入"),
    ("后备箱分段", "trunkOpenStatus / trunkUpperOpenStatus / trunkLowerOpenStatus", "—", "✅ 命中，尚未接入"),
    ("四轮胎温", "leftFrontTyreTemp / leftBackTyreTemp", "tyreTemp*", "✅ 命中（getter 反推）"),
    ("胎压告警", "leftFrontTyrePressureAlert 等（分轮位）", "tyreWarning（归并）", "✅ 命中"),
    ("能耗", "averPowerConsumption / averTraPowerConsumption / electricConsumption", "avgConsumption", "✅ 命中"),
    ("剩余可消耗里程", "remainingConsumableMileage / totalConsumptionMileage", "—", "✅ 命中，尚未接入"),
    ("动力电池电压", "electricVoltage", "—", "✅ 命中，尚未接入"),
    ("储物箱锁", "storageboxlock", "—", "✅ 命中，尚未接入"),
]

INVENTED_FIELDS = [
    ("车门", "doorStatusFrontLeft / FrontRight / RearLeft / RearRight"),
    ("后备箱", "tailDoorStatus"),
    ("前备箱", "frunkStatus / frontTrunkStatus"),
    ("12V 电瓶", "mainBatteryStatus"),
    ("空调", "climateStatusPreclimateActive / climateTargetTemperature / acTemperatureSetting"),
    ("内外温度", "interiorTemperature / exteriorTemperature / temExterior / temOutdoor"),
    ("胎压告警", "tyreWarningStatus"),
    ("能耗", "averageEnergyConsumption"),
    ("保养", "maintainDistance / serviceDistance"),
    ("车速", "vehicleSpeed"),
    ("充电上限", "chargeLimit / socLimit"),
    ("定位", "posLat / posLon"),
    ("枪连接", "chargerConnected"),
    ("行程", "journeyId / consumeEnergy"),
]

STATUS_ROWS = [
    ("GW1 主机", "`api-gw-toc.zeekrlife.com`", "✔ 一致"),
    ("GW3 主机", "`snc-tsp-api.zeekrlife.com`", "✔ 一致"),
    ("GW3 App-ID", "`ZEEKRCNCH001M0001`", "✔ 一致"),
    ("手机号登录", "`/zeekrlife-app-user/v1/user/pub/login/mobile`（无 `/sendCode`）", "✔ 已修正"),
    ("换令牌", "`/app/login/v1/getTokenByCode`（host 待确认）", "⚠ 候选链尝试"),
    ("车况", "`/ms-vehicle-status/api/v2.0/vehicle/status/latest`", "✔ 已修正"),
    ("车辆列表", "明文未出现（走 GRIC / SDK 层）", "⚠ 候选链尝试"),
    ("车控", "`/ms-remote-control/api/v1.0/remoteControl/control`", "✔ 已修正"),
    ("车控执行结果", "`…/remoteControl/queryProcessResult`", "✔ 已接入"),
    ("行程", "`/ms-vehicle-trail/api/v1.0/journalLog/trip/listForPage`", "✔ 已修正"),
    ("轨迹点", "`…/journalLog/trackpoint/list`", "⚪ 未接入"),
    ("车辆能力集", "`/ms-vehicle-capability-set/api/app/v1/vehicle/capability/available`", "✔ 已接入"),
    ("预约充电", "`/ms-charge-manage/api/v1.0/charge/getChargingPlanNew`", "✔ 已接入"),
    ("电子围栏", "`/ms-vehicle-defence/api/v1.0/fence/*`", "⚪ 未做"),
    ("哨兵照片", "`/ms-vehicle-guard/api/v1.0/sentinel/queryPhotoList`", "⚪ 未做"),
]


def render(intel: dict) -> str:
    svc: dict[str, list[str]] = intel["services"]
    gates: dict[str, int] = intel["gateways"]
    caps: dict[str, int] = intel["capability_flags"]
    L: list[str] = []
    w = L.append

    w("# 极氪官方 App 接口情报参考")
    w("")
    w("> **本文件由 `classes.dex` 原始字节扫描生成，可直接查阅，无需再跑一遍逆向。**")
    w("> 重新生成：`python scripts/apk_intel.py <apk路径>`")
    w("")
    w("| 项 | 值 |")
    w("|---|---|")
    w(f"| 样本 | `{intel.get('source_apk', '—')}` |")
    w("| 样本版本 | v5.0.7（versionCode 221，2026-09-15 构建） |")
    w("| sha256 | `19b4c81ec83c0c95f287ec7dcc75d165dc996379871e880f8fc68b9f0ba87296` |")
    w("| 样本形态 | 单一整包 597 MB / 16746 条目（**内含 `lib/arm64-v8a/libenv.so`**，无需分片） |")
    w("| 提取日期 | 2026-10-15 |")
    w(f"| 产出 | 网关主机 {len(gates)} · 服务前缀 {len(svc)} · 接口路径 "
      f"{sum(len(v) for v in svc.values())} · 请求头 {len(intel['headers'])} · "
      f"能力标志 {len(caps)} |")
    w("")
    w("**方法**：解出 `classes.dex` → 正则扫描原始字节 → 要求路径含版本段"
      f"（`/v1/`、`/v1.0/`…），据此丢弃 {intel['dropped_non_api_paths']:,} 条 "
      "Java/Kotlin 类名路径（如 `/zeekrlife/appinit/api/AppInitManager`）。")
    w("")
    w("### ⚠️ 取证边界（务必先读）")
    w("")
    w("1. **官方 App 已加固**：包内含 `libconch.so`(31 MB)、`libHHSecurity.so`、"
      "`libNetHTProtect.so`、`libEncryptorP.so`、`libZeekrSecurity.so`。"
      "JADX 加载后只解析出 **23 个类** —— **类级反编译不可用**，"
      "读不到 DTO、注解与请求体结构。")
    w("2. **但 DEX 字符串表是明文可读的**，所以「路径是否存在」「字段名是否存在」"
      "是可判定命题 —— 本文件的全部结论都建立在这上面。")
    w("3. **字段名置信度分两档**：")
    w("   - 标 ✅ 命中：字符串在 DEX 中确实存在（并给出命中次数）—— 可信。")
    w("   - 由 getter 反推：如 `getLeftFrontWindowStatus` → `leftFrontWindowStatus`，"
      "**强候选但未 100% 确认**（Gson 可能配 `@SerializedName` 改名）。")
    w("4. **路径与主机的绑定关系无法静态确定**：字符串扫描只能证明"
      "「这条路径存在」，证明不了它挂在哪个域名下。")
    w("")

    # 一
    w("---")
    w("")
    w("## 一、网关主机")
    w("")
    prod, envs = [], []
    for h in gates:
        low = h.lower()
        (envs if any(x in low for x in ("dev", "test", "uat", "sit", "pre")) else prod).append(h)
    notes = {
        "api-gw-toc": "**GW1** 用户/登录网关 —— ZeekrDash 已用 ✔",
        "snc-tsp-api": "**GW3** SNC 车联网网关 —— ZeekrDash 已用 ✔",
        "gateway-pub": "公共网关",
        "touchpoint-api": "触点服务",
        "zeekrgo-api": "ZeekrGO",
        "gric-api": "**GRIC** 吉利侧主网关（CN 官方 App 亦使用）",
        "gric-g-api": "GRIC 变体",
        "gric-hf-api": "GRIC 变体",
        "gric-z-api": "GRIC 变体",
        "galaxy-api-gw-toc": "吉利银河网关",
        "zeekr-h5-api": "H5 接口",
        "im-web": "IM / 位置服务",
        "pay-api": "支付",
        "charginghandbook": "充电手册",
        "dip-dataservice": "数据服务",
        "zrcloud": "ZrCloud 云网关",
    }
    w("### 生产环境")
    w("")
    w("| 主机 | 说明 |")
    w("|---|---|")
    for h in prod:
        note = next((v for k, v in notes.items() if k in h), "")
        w(f"| `{h}` | {note} |")
    w("")
    w(f"<details><summary>测试 / 预发环境（{len(envs)} 条）</summary>")
    w("")
    for h in envs:
        w(f"- `{h}`")
    w("")
    w("</details>")
    w("")

    # 二
    w("---")
    w("")
    w("## 二、应用标识与请求头")
    w("")
    w("| 常量 | 值 | 说明 |")
    w("|---|---|---|")
    w("| GW3 `X-APP-ID` | `ZEEKRCNCH001M0001` | GW3 签名必需，ZeekrDash 已用 ✔ |")
    w("| 签名协议版本 | `2.0` | 需发 `X-API-SIGNATURE-VERSION: 2.0` |")
    w("| App 版本 | `5.0.7` | 与本样本一致 |")
    w("")
    ids = [i for i in intel["app_ids"] if i != "ZEEKRCNCH001M0001"]
    if ids:
        w("DEX 中出现的其他标识常量：")
        w("")
        for i in ids[:20]:
            w(f"- `{i}`")
        w("")
    w("### 请求头常量（按出现次数排序，前 40）")
    w("")
    w("| 请求头 | 命中 |")
    w("|---|---|")
    for k, v in list(intel["headers"].items())[:40]:
        w(f"| `{k}` | {v} |")
    w("")
    w("> GW3 **参与签名**的白名单（11 个，见 `zeekr_signing.GW3_SIGNED_HEADERS`）："
      "`x-app-id`、`content-type`、`x-api-signature-nonce`、`x-timestamp`、"
      "`x-api-signature-version`、`x-project-id`、`authorization`、`accept-language`、"
      "`x-vin`、`x-device-id`、`x-platform`。其余头（`User-Agent`、"
      "`X-APP-OS-VERSION` 等）照常发送但不参与签名。")
    w("")

    # 三
    w("---")
    w("")
    w("## 三、服务与接口路径目录")
    w("")
    w("> 路径格式统一为 `/<服务名>/api/<版本>/...` 或 `/<服务名>/<版本>/...`。")
    w("")
    w("### 3.1 车辆相关（重点展开）")
    w("")
    for name in VEHICLE_SERVICES:
        paths = svc.get(name)
        if not paths:
            continue
        w(f"#### `{name}` — {SERVICE_NOTES.get(name, '')}")
        w("")
        for p in paths:
            w(f"- `{p}`")
        w("")
    w("### 3.2 用户与账号")
    w("")
    for name in ("zeekrlife-app-user", "ms-user-auth", "ms-midground-user", "login", "auth"):
        paths = svc.get(name)
        if not paths:
            continue
        w(f"#### `{name}`（{len(paths)} 条）— {SERVICE_NOTES.get(name, '')}")
        w("")
        for p in paths:
            w(f"- `{p}`")
        w("")
    w("### 3.3 其他自有服务")
    w("")
    skip = set(VEHICLE_SERVICES) | {"zeekrlife-app-user", "ms-user-auth",
                                    "ms-midground-user", "login", "auth"}
    own = {k: v for k, v in svc.items()
           if any(k.startswith(p) for p in OWN_PREFIXES) and k not in skip}
    for name, paths in sorted(own.items(), key=lambda x: -len(x[1])):
        note = SERVICE_NOTES.get(name, "")
        tag = f" — {note}" if note else ""
        w(f"<details><summary><code>{name}</code>（{len(paths)} 条）{tag}</summary>")
        w("")
        for p in paths[:60]:
            w(f"- `{p}`")
        if len(paths) > 60:
            w(f"- … 另有 {len(paths) - 60} 条，完整清单见 `zeekr-apk-intel.json`")
        w("")
        w("</details>")
        w("")
    w("### 3.4 第三方 SDK（仅供识别）")
    w("")
    others = {k: v for k, v in svc.items() if k not in own and k not in skip}
    w("| 前缀 | 路径数 |")
    w("|---|---|")
    for name, paths in sorted(others.items(), key=lambda x: -len(x[1]))[:40]:
        w(f"| `/{name}/` | {len(paths)} |")
    w("")

    # 四
    w("---")
    w("")
    w("## 四、车辆状态字段名")
    w("")
    w("### 4.1 已确认可用（官方 DEX 中命中）")
    w("")
    w("| 语义 | 官方字段 | ZeekrDash 归一化键 | 置信度 |")
    w("|---|---|---|---|")
    for meaning, official, norm, conf in VERIFIED_FIELDS:
        w(f"| {meaning} | `{official}` | `{norm}` | {conf} |")
    w("")
    w("### 4.2 官方包里 **0 命中** 的自造字段名（已修正）")
    w("")
    w("> 这些名字曾作为「容错别名」存在，但在官方包中一次都不出现 ——"
      " 属于永远不会命中的死代码，会造成「已兼容多种命名」的虚假安全感。")
    w("")
    w("| 归属 | 自造字段名 |")
    w("|---|---|")
    for meaning, names in INVENTED_FIELDS:
        w(f"| {meaning} | `{names}` |")
    w("")
    w("### 4.3 按主题分组的候选字段名")
    w("")
    w("> 从 DEX 提取的小驼峰标识符（已排除 `get/set/is/on` 等方法名前缀）。"
      "**这是候选池，不是确认清单** —— 需要确认时用原始字节 `count()` 逐个验证。")
    w("")
    for topic, names in sorted(intel["field_candidates_by_topic"].items(),
                               key=lambda x: -len(x[1])):
        sample = list(names.keys())[:14]
        w(f"**{topic}**（{len(names)} 个）："
          + " ".join(f"`{n}`" for n in sample)
          + ("…" if len(names) > 14 else ""))
        w("")

    # 五
    w("---")
    w("")
    w("## 五、能力标志（车辆能力集的字段线索）")
    w("")
    w("官方有 `/ms-vehicle-capability-set/api/app/v1/vehicle/capability/available`，"
      "但**响应体结构取不出来**（加壳）。下面是从 DEX 捞到的 `*Supported` 标识符，"
      "可作为推断能力集键名的线索。")
    w("")
    rel = {k: v for k, v in caps.items()
           if any(x in k.lower() for x in
                  ("door", "window", "lock", "trunk", "frunk", "hood", "tyre", "tire",
                   "climate", "temperature", "seat", "charge", "soc", "battery",
                   "sunroof", "sunshade", "mirror", "steering", "fragrance", "fridge",
                   "sentinel", "guard", "fence", "light", "horn", "track"))}
    w(f"共 {len(caps)} 个，其中与车辆相关 {len(rel)} 个：")
    w("")
    for k in list(rel.keys())[:90]:
        w(f"- `{k}`")
    w("")
    w(f"> 其余 {len(caps) - len(rel)} 个（UI / 埋点 / SDK 相关）见 "
      "`zeekr-apk-intel.json` 的 `capability_flags`。")
    w("")

    # 六
    w("---")
    w("")
    w("## 六、ZeekrDash 使用现状对照")
    w("")
    w("| 用途 | 官方路径 | ZeekrDash |")
    w("|---|---|---|")
    for a, b, c in STATUS_ROWS:
        w(f"| {a} | {b} | {c} |")
    w("")

    # 七
    w("---")
    w("")
    w("## 七、仍未知 / 待抓包确认")
    w("")
    w("1. **车辆列表的真实端点** —— 明文里没有；官方走 `com.geely.snc.basevehicle` SDK"
      "（GRIC 侧），路径可能由 native 层构造。")
    w("2. **`/app/login/*` 与 `/auth/oauth2/*` 挂在哪个主机** —— 字符串扫描证明不了 host 绑定。")
    w("3. **各接口的请求体与响应体结构** —— 需脱壳或抓包。")
    w("4. **能力集、`queryProcessResult`、充电计划的响应结构** —— 同上；代码里已按"
      "「多候选 + 保守兜底」处理，读不出来一律落到安全侧（执行结果 → pending，能力 → None）。")
    w("5. **密钥**：已用 `zeekr_key_extractor` 静态提取到 6 个值，但 **`prod_secret` 是 "
      "119 个候选中第 1 个**，且该工具的实测版本远早于 5.0.7 —— 正确性需真机验证。")
    w("")
    w("→ **下一步最有效的一步是抓一次官方 App 的真实请求**（模拟器 + mitmproxy）："
      "host + path + header + body 一次钉死。")
    w("")

    w("---")
    w("")
    w("## 附：密钥提取（本仓库内置）")
    w("")
    w("6 个网关密钥由 `scripts/extract_keys.py` 提取 —— 它移植自 MIT 许可的")
    w("`wysie/zeekr_key_extractor`（算法未改，只加了脱敏与写 `.env`）：")
    w("")
    w("```bash")
    w("pip install capstone pyelftools")
    w("python scripts/extract_keys.py <apk> --write-env   # 直接填进 server/.env")
    w("```")
    w("")
    w("整包即可，**不需要安卓设备**。默认不回显密钥明文，只显示掩码。")
    w("")
    w("---")
    w("")
    w("本文件仅为个人自用学习整理，与极氪 / 吉利 / ECARX 无任何关联。")
    w("")
    return "\n".join(L)


# ═══════════════════════════════════════════════════════════════
# 第三部分：版本对比（APK 升级后的回归检查）
# ═══════════════════════════════════════════════════════════════

# ZeekrDash 运行时真正依赖的官方路径 —— 每条对应
# `server/app/adapters/live_client.py` 里的一处实现。
# 列在这里是当**契约**用：新版本 APK 里某条一旦消失，说明官方改了接口，
# 对应功能会立刻失败，必须改代码适配。
#
# ⚠️ 清单里**每一条都经过 DEX 原始字节精确计数校验**（见 verify 结论：
#    `/ms-user-auth[/api]/v1.0/auth/login` 是 0 命中的自造路径，已从清单
#    与 live_client.py 里一并移除）。新增契约项前请先用同样方式验证。
# 标注「候选」的尚未在真机上确认，只是候选链的一环 —— 消失可以接受，但要知道。
CONTRACT_PATHS = [
    ("/zeekrlife-app-user/v1/user/pub/login/mobile", "GW1 手机号登录（发码与登录同一路径）"),
    ("/app/login/v1/getTokenByCode", "换令牌"),
    ("/ms-vehicle-status/api/v2.0/vehicle/status/latest", "车况快照"),
    ("/ms-vehicle-trail/api/v1.0/journalLog/trip/listForPage", "行程列表"),
    ("/ms-remote-control/api/v1.0/remoteControl/control", "车控下发"),
    ("/ms-remote-control/api/v1.0/remoteControl/queryProcessResult", "车控执行结果"),
    ("/ms-vehicle-capability-set/api/app/v1/vehicle/capability/available", "车辆能力集"),
    ("/ms-charge-manage/api/v1.0/charge/getChargingPlanNew", "预约充电计划"),
    ("/ms-vehicle-core/api/v1.0/vehicle/favorite-vehicles", "车辆列表 · 候选"),
    ("/ms-vehicle-account/api/v1.0/vehicle-detail", "车辆详情 · 候选"),
]

# ZeekrDash 解析依赖的官方字段名（已从自造别名纠正为官方真名）。
# 消失 = 该字段会静默取不到值（历史上车门/胎压就是这么坏掉的）。
# 同样逐条经 DEX 计数校验；未通过的已剔除：
#   chargerConnected    → 不存在，真名是 statusOfChargerConnection
#   tyreWarningStatus   → 不存在。官方只有 4 个轮的独立告警字段，无汇总字段
CONTRACT_FIELDS = [
    # 电池 / 充电
    "chargeLevel", "distanceToEmptyOnBatteryOnly", "timeToFullyCharged",
    "statusOfChargerConnection",
    # 车身
    "lockStatus",
    "leftFrontDoorStatus", "rightFrontDoorStatus",
    "leftBackDoorStatus", "rightBackDoorStatus",
    "leftFrontWindowStatus", "rightFrontWindowStatus",
    "leftBackWindowStatus", "rightBackWindowStatus",
    "frunkOpenStatus", "trunkOpenStatus",
    # 胎压与胎温
    "leftFrontTyrePressure", "rightFrontTyrePressure",
    "leftBackTyrePressure", "rightBackTyrePressure",
    "leftFrontTyreTemp", "rightFrontTyreTemp",
    "leftBackTyreTemp", "rightBackTyreTemp",
    "leftFrontTyrePressureAlert", "rightFrontTyrePressureAlert",
    "leftBackTyrePressureAlert", "rightBackTyrePressureAlert",
    # 空调 / 位置 / 里程 / 能耗
    "preClimateActive", "temInterior", "posCanBeTrusted",
    "odometer", "averPowerConsumption",
]


def _paths_of(intel: dict) -> set:
    return {p for paths in intel.get("services", {}).values() for p in paths}


def _field_index(intel: dict) -> dict:
    """字段名 → 原样写法。大小写不敏感 —— DEX 里可能有多种写法。"""
    idx = {}
    for topic in intel.get("field_candidates_by_topic", {}).values():
        for name in topic:
            idx.setdefault(name.lower(), name)
    return idx


def _by_service(paths: set) -> dict:
    """把一组路径按首段服务名归组。"""
    out = defaultdict(list)
    for p in sorted(paths):
        head = p.lstrip("/").split("/")[0]
        out[head].append(p)
    return dict(sorted(out.items(), key=lambda kv: -len(kv[1])))


def compare(new: dict, old: dict) -> tuple:
    """对比两版情报，返回 (Markdown 报告, 是否存在破坏性变更)。

    破坏性变更的口径只有一个：**契约路径或契约字段在新版本里消失**。
    其余增删都只是信息，不阻断 —— 每次 App 更新都会带来成百上千条
    无关字符串，把噪声当风险会让这个工具失去意义。
    """
    L: list = []

    def w(s: str = "") -> None:
        L.append(s)

    old_paths, new_paths = _paths_of(old), _paths_of(new)
    old_fields, new_fields = _field_index(old), _field_index(new)

    # 契约检查优先用「提取时留下的字节计数」—— 准确；
    # 若对比的是没有该字段的旧快照，退回"是否出现在清单里"的近似判断。
    new_hits = new.get("contract_hits") or {}
    hit_paths = new_hits.get("paths") or {}
    hit_fields = new_hits.get("fields") or {}

    if hit_paths:
        broken_paths = [(p, note) for p, note in CONTRACT_PATHS if not hit_paths.get(p)]
    else:
        broken_paths = [(p, note) for p, note in CONTRACT_PATHS if p not in new_paths]

    if hit_fields:
        broken_fields = [f for f in CONTRACT_FIELDS if not hit_fields.get(f)]
    else:
        broken_fields = [f for f in CONTRACT_FIELDS if f.lower() not in new_fields]

    breaking = bool(broken_paths or broken_fields)

    w("# 极氪 APK 版本对比")
    w()
    w(f"| 项 | 旧（基准） | 新（本次） |")
    w("|---|---|---|")
    for label, key in (
        ("样本", "source_apk"),
        ("服务前缀", "services"),
        ("网关主机", "gateways"),
        ("请求头", "headers"),
        ("能力标志", "capability_flags"),
        ("应用标识", "app_ids"),
    ):
        if key == "source_apk":
            w(f"| {label} | `{Path(str(old.get(key, '?'))).name}` | `{Path(str(new.get(key, '?'))).name}` |")
        else:
            w(f"| {label} | {len(old.get(key) or {})} | {len(new.get(key) or {})} |")
    w(f"| 接口路径 | {len(old_paths)} | {len(new_paths)} |")
    w()

    # ── 一、契约回归（唯一阻断项）────────────────────────────
    w("## 一、契约回归 —— 阻断级")
    w()
    w("下面是 ZeekrDash **正在使用**的接口与字段。消失即意味着对应功能会失败。")
    w()
    w("### 路径")
    w()
    if broken_paths:
        w("| 状态 | 路径 | 用途 |")
        w("|---|---|---|")
        for p, note in broken_paths:
            w(f"| ❌ **已消失** | `{p}` | {note} |")
        w()
        w(f"**{len(broken_paths)} 条契约路径在新的 APK 里找不到了。**")
        w("先确认是不是被改名或拆分到了别的服务前缀下（在下面第二节的差异里搜关键词），")
        w("再改 `server/app/adapters/live_client.py`。**不要只删掉该条就了事** —— 那等于功能静默失效。")
    else:
        note = ""
        if hit_paths:
            vals = [hit_paths.get(p, 0) for p, _ in CONTRACT_PATHS]
            if vals:
                note = f"（包内命中 {min(vals)}–{max(vals)} 次）"
        w(f"✅ 全部 {len(CONTRACT_PATHS)} 条契约路径仍然存在。{note}")
    w()
    w("### 字段")
    w()
    if broken_fields:
        w("| 状态 | 字段 | 影响 |")
        w("|---|---|---|")
        for f in broken_fields:
            w(f"| ❌ **已消失** | `{f}` | 该字段将静默取不到值 |")
        w()
        w(f"**{len(broken_fields)} 个契约字段消失了。** 按 `docs/zeekr-apk-reference.md`")
        w("的「字段名对照表」找官方新名字，替换 `live_client.py` 里 `pick()` 的首选参数。")
    else:
        note = ""
        if hit_fields:
            vals = [hit_fields.get(f, 0) for f in CONTRACT_FIELDS]
            if vals:
                note = f"（包内命中 {min(vals)}–{max(vals)} 次）"
        w(f"✅ 全部 {len(CONTRACT_FIELDS)} 个契约字段仍然存在。{note}")
    w()

    # ── 二、接口路径差异 ────────────────────────────────────
    w("## 二、接口路径差异")
    w()
    gone = old_paths - new_paths
    fresh = new_paths - old_paths
    w(f"新增 {len(fresh)} 条，消失 {len(gone)} 条。")
    w()
    if gone:
        w(f"### 消失的 {len(gone)} 条（全部列出 —— 官方删接口是强信号）")
        w()
        for head, ps in _by_service(gone).items():
            w(f"- **`/{head}/`** — {len(ps)} 条")
            for p in ps:
                w(f"    - `{p}`")
        w()
    if fresh:
        w(f"### 新增的 {len(fresh)} 条（按服务聚合，每项最多列 6 条）")
        w()
        w("| 服务 | 条数 | 示例 |")
        w("|---|---|---|")
        for head, ps in _by_service(fresh).items():
            sample = " · ".join(f"`{p.split('/', 2)[-1]}`" for p in ps[:6])
            w(f"| `/{head}/` | {len(ps)} | {sample} |")
        w()

    # ── 三、其余清单差异 ───────────────────────────────────
    def simple_diff(title: str, key: str, *, list_all_gone: bool = True) -> None:
        o, n = set(old.get(key) or {}), set(new.get(key) or {})
        plus, minus = n - o, o - n
        if not plus and not minus:
            w(f"### {title}")
            w()
            w("无变化。")
            w()
            return
        w(f"### {title}")
        w()
        w(f"新增 {len(plus)} · 消失 {len(minus)}")
        w()
        if minus and list_all_gone:
            w("消失：")
            for x in sorted(minus):
                w(f"- `{x}`")
            w()
        if plus and len(plus) <= 40:
            w("新增：")
            for x in sorted(plus):
                w(f"- `{x}`")
            w()
        elif plus:
            w(f"新增过多（{len(plus)} 条），略 —— 见 `zeekr-apk-intel-new.json`。")
            w()

    w("## 三、服务前缀")
    w()
    simple_diff("变化", "services")
    w("## 四、网关主机")
    w()
    simple_diff("变化", "gateways")
    w("## 五、请求头")
    w()
    simple_diff("变化", "headers")
    w("## 六、能力标志")
    w()
    simple_diff("变化", "capability_flags", list_all_gone=False)
    w("## 七、应用标识")
    w()
    simple_diff("变化", "app_ids")

    w("---")
    w()
    w("## 结论")
    w()
    if breaking:
        w("🔴 **存在破坏性变更** —— 见第一节。按上面的指引改代码后再重新验证。")
    else:
        w("🟢 **未发现破坏性变更** —— ZeekrDash 依赖的路径与字段都还在。")
        w()
        w("可以继续做的事：")
        w()
        w("1. 用新快照替换旧快照：`mv docs/zeekr-apk-intel-new.json docs/zeekr-apk-intel.json`，")
        w("   并重跑一次渲染让 `docs/zeekr-apk-reference.md` 跟上。")
        w("2. 在第二节「新增路径」里看看有没有值得做的新功能。")
    w()
    w("---")
    w()
    w("本文件由 `scripts/apk_intel.py --compare` 生成，仅供个人自用学习整理。")
    w()

    return "\n".join(L), breaking


def main() -> None:
    parser = argparse.ArgumentParser(
        description="从官方极氪 APK 提取接口情报，渲染成参考文档；可对比历史版本",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    parser.add_argument("apk", type=Path, help="官方 APK 路径（整包即可，无需分片）")
    parser.add_argument("-o", "--out-dir", type=Path, default=Path("docs"),
                        help="输出目录（默认 docs/）")
    parser.add_argument("--json-only", action="store_true", help="只产出 JSON，不渲染文档")
    parser.add_argument(
        "--compare",
        type=Path,
        metavar="旧JSON",
        help="与历史情报 JSON 对比，产出 <out-dir>/zeekr-apk-diff.md。"
             "不会覆盖现有快照（新快照另存为 zeekr-apk-intel-new.json）；"
             "发现破坏性变更时以退出码 1 结束，便于 CI 拦截。",
    )
    args = parser.parse_args()

    if not args.apk.is_file():
        raise SystemExit(f"✗ 找不到文件：{args.apk}")

    intel = extract(args.apk)
    args.out_dir.mkdir(parents=True, exist_ok=True)

    if args.compare:
        if not args.compare.is_file():
            raise SystemExit(f"✗ 找不到对比基准：{args.compare}")
        old = json.loads(args.compare.read_text(encoding="utf-8"))
        report, breaking = compare(intel, old)

        diff_path = args.out_dir / "zeekr-apk-diff.md"
        diff_path.write_text(report, encoding="utf-8")
        # 新快照另存 —— 不覆盖基准，人工确认后再手动替换
        snap = args.out_dir / "zeekr-apk-intel-new.json"
        snap.write_text(json.dumps(intel, ensure_ascii=False, indent=1), encoding="utf-8")

        print(f"✓ {diff_path}  ({diff_path.stat().st_size / 1024:.0f} KB)", file=sys.stderr)
        print(f"✓ {snap}", file=sys.stderr)
        print(f"  （确认无误后：mv {snap} {args.compare}）", file=sys.stderr)
        if breaking:
            print("\n🔴 存在破坏性变更：ZeekrDash 依赖的路径或字段在新 APK 里消失了。",
                  file=sys.stderr)
            print(f"   详情见 {diff_path} 的「一、契约回归」。", file=sys.stderr)
            sys.exit(1)
        print("\n🟢 未发现破坏性变更。", file=sys.stderr)
        return

    json_path = args.out_dir / "zeekr-apk-intel.json"
    json_path.write_text(json.dumps(intel, ensure_ascii=False, indent=1), encoding="utf-8")
    print(f"\n✓ {json_path}  ({json_path.stat().st_size / 1024:.0f} KB)", file=sys.stderr)
    print(f"  网关 {len(intel['gateways'])} · 服务 {len(intel['services'])} · "
          f"路径 {sum(len(v) for v in intel['services'].values())} · "
          f"请求头 {len(intel['headers'])} · 能力标志 {len(intel['capability_flags'])}",
          file=sys.stderr)

    if not args.json_only:
        md_path = args.out_dir / "zeekr-apk-reference.md"
        md_path.write_text(render(intel), encoding="utf-8")
        print(f"✓ {md_path}  ({md_path.stat().st_size / 1024:.0f} KB)", file=sys.stderr)


if __name__ == "__main__":
    main()
