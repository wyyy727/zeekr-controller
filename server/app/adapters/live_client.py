"""极氪国区真实客户端。

实现流程参考 RexzeLu/zeekr_ha 的国区方案：

    登录链路：GW1 请求短信码 → GW1 手机号登录（JWT）
              → GW2 换取 ecar accessToken → GW3 登录（HMAC-SHA256）

    读取链路：优先 GW3 取最新状态；GW3 被拒（079001）则回退 GW2
    控制链路：优先 GW3 远程控制；被拒则回退 GW2 telematics

设计要点：
- **会话持久化**：JWT / accessToken / refreshToken 落盘，避免每次都收验证码
- **单会话约束**：极氪每个账号只保留一个会话，新登录会顶掉旧令牌。
  遇到 `079021 logged in elsewhere` 时自动重登并重试一次。
- **容错解析**：网关在不同车型/固件下字段名不一致，采用叶子节点索引 + 别名匹配
"""

from __future__ import annotations

import base64
import calendar
import json
import logging
import re
import time
import uuid
from datetime import datetime, timedelta
from hashlib import md5
from typing import Any

import httpx

from ..core.config import ZeekrConfig
from ..core.coords import wgs84_to_gcj02
from .base import ZeekrClient
from .zeekr_signing import (
    COMMAND_MAP,
    GW1_DEVICE_MODEL,
    GW1_HOST,
    GW2_HOST,
    GW3_HOST,
    build_control_body,
    build_gw1_headers,
    build_gw3_headers,
    build_login_device_id,
    compact_json,
    encrypt_vin,
    is_verified_command,
    sign_gw2,
)

logger = logging.getLogger(__name__)

# 官方「行程与能耗」日统计（官方 App「行程统计」页的数据源）。
# 注意命名空间是 **h5** 而不是 phone —— phone 下只有 `protocolConfirm` 一条协议确认，
# 按 phone + 名词词根去枚举会全部 404（踩过，别再按名字猜）。
ENERGY_DAILY_PATH = "/journey-statistics-service/api/v2.0/h5/getDailyStatisticsInfo"
# 服务端硬限制：一次最多查询 31 个自然日，超了报 A008。
ENERGY_MAX_DAYS = 31
# 可选月份清单 + 车辆总里程（同服务的 mileageBaseInfo）
ENERGY_MONTHS_PATH = "/journey-statistics-service/api/v2.0/h5/mileageBaseInfo"
# 月度报告：日统计接口 A010「只允许查询 60 天内数据」，
# 更早的月份只能走这条（支持约两年，`existingMonth` 就是它的可查清单）
ENERGY_MONTHLY_PATH = "/journey-statistics-service/api/v2.0/h5/getMonthlyStatisticsInfo"

# 官方「充电记录」：按年 → 月分组，一次给出约两年全部流水。
#
# 三个必踩的坑（都是实测，别改）：
#   1. 除了 GW3 的签名头，还必须带 `X-TENANT-ID: ZEEKR` 与 `X-VEHICLE-BRAND: ZEEKR`，
#      缺一个就 `079001`，看起来像"没权限"，其实是缺头；
#   2. `X-VIN` 必须是**加密后的** VIN（明文报 `079025 Decrypt X-VIN failed.`）；
#   3. body 里 `startTimeStart` 可传 null（表示不限起点）、`chargeType` 传空串表示不筛。
#
# 它**没有**金额、单价、站点名 —— 车不知道电价，站点也不在这条链路上。
CHARGE_LOG_PATH = "/ms-charge-manage/api/v2.0/charge/log/queryGroupMouth"

# 会话被顶替
ERR_LOGGED_IN_ELSEWHERE = "079021"
# 接口未被授权（通常是令牌代际不对，应回退 GW2 而非重登）
ERR_UNAUTHORIZED = "079001"
# 签名校验失败
ERR_SIGNATURE = "079025"

# 已知的网关业务错误码。
#
# 国区网关的**错误信封并不总是带 `success` 字段** —— 常见形态是只有
# `{"code": "...", "msg": "..."}`。所以不能只靠 `success` 判断成败，
# 否则这些错误会被当成正常响应、被后续解析当成"数据"，最终表现为
# 「账号下未找到车辆」这类误导性的结论，而真正的原因（签名算错、
# 令牌无权）完全看不见。这些码一旦出现，无论有没有 success 都算失败。
KNOWN_ERROR_CODES = frozenset({ERR_LOGGED_IN_ELSEWHERE, ERR_UNAUTHORIZED, ERR_SIGNATURE})

# GW3 参与签名的 query 值只允许这些字符。
#
# httpx 用 `params=` 自行编码，而签名走的是 `_escape_query_value`（它会把
# `*` 编成 `%2A`、把 `%2F`/`%3F` 解回明文）—— 两者只对「无特殊字符」的值
# 一致。当前调用只有 latest=false / target=new，故相安无事；但一旦有人
# 传入含 `*` `/` `?` 空格或非 ASCII 的值，签名串与实际发送字节就会分叉，
# 网关报 079025 而看不出原因。这里显式拦住，把潜在失效变成即时可见的
# 错误，而不是静默验签失败。
_QUERY_SAFE = re.compile(r"^[A-Za-z0-9._~-]*$")

TIMEOUT = httpx.Timeout(20.0, connect=10.0)


def _jwt_expires_at(token: str) -> int | None:
    """从 JWT 中读取 `exp`（只解析，不验签）。

    用于判断本地缓存的令牌是否已经过期。解析失败返回 None —— 即
    「不知道」，此时既不乐观假设有效、也不武断判死。
    """
    try:
        payload_b64 = token.split(".")[1]
        payload_b64 += "=" * (-len(payload_b64) % 4)
        data = json.loads(base64.urlsafe_b64decode(payload_b64))
        exp = data.get("exp")
        return int(exp) if exp is not None else None
    except Exception:  # noqa: BLE001 - 令牌格式不受本服务控制
        return None



class ZeekrAuthError(Exception):
    """登录态相关错误。"""


class ZeekrAPIError(Exception):
    """网关返回的业务错误。"""

    def __init__(self, code: str, message: str, raw: Any = None) -> None:
        super().__init__(f"[{code}] {message}")
        self.code = code
        self.message = message
        self.raw = raw


def _compact(path: str) -> str:
    """把路径压缩为纯字母数字形式，用于别名匹配。

    例如 `electricVehicleStatus.chargeLevel` → `electricvehiclestatuschargelevel`。
    这样别名表可以忽略层级分隔方式，只关心字段名序列。
    """
    return "".join(ch for ch in path.lower() if ch.isalnum())


def _all_or_none(**fields: bool | None) -> dict[str, bool] | None:
    """四个值全拿到才返回字典，否则返回 None。

    用途：对外契约要求「字典里不允许出现 None 值」（iOS 侧按
    `[String: Bool]?` 解码，None 会导致整个响应解码失败）。
    因此"部分有值"只能降级成"整体未知"，不能用 False 填补 ——
    那会把"没读到"谎报成"已关好"，比没有数据更危险。
    """
    if any(v is None for v in fields.values()):
        return None
    return {k: bool(v) for k, v in fields.items()}


def _any_tyre_alert(*flags: bool | None) -> bool | None:
    """把分轮位的胎压告警归并成一个总标志。

    官方字段是分轮位的（`leftFrontTyrePressureAlert` 等），而前端只需要一个
    "有没有告警"的布尔值。语义：

    - 任一为 True → True（有告警）
    - 全部为 None → None（网关没给这个数据，**不能**谎报为"无告警"）
    - 其余（有值但都不是 True）→ False（明确无告警）

    最后一条区分很关键：把"没有数据"和"确认无告警"混为一谈，会让用户
    在胎压异常时看不到任何提示。
    """
    meaningful = [f for f in flags if f is not None]
    if not meaningful:
        return None
    return any(meaningful)


# ── 车控执行结果 / 能力集 / 预约计划的报文解析 ────────────────────
#
# 下面几个函数处理的报文结构**未在真车确认** —— 官方 APK 加壳，
# DTO 取不到，只有路径是已验证的。因此统一采取"多候选 + 保守兜底"：
#   · 能明确读出"成功"才说成功；
#   · 读不出来一律落到安全的一侧（执行结果 → pending、能力 → None）。
# 方向是不对称的：把"没执行完"说成"已执行"，用户会以为车锁好了 ——
# 这个代价远大于"多等一会儿"或"少裁剪几个按钮"。

#: 官方可能使用的"指令凭据"字段名
_COMMAND_ID_KEYS = ("processId", "commandId", "id", "requestId", "traceId")


def _extract_command_id(payload: Any) -> str:
    """从指令下发响应里取出查询执行结果所需的凭据。取不到给空串。"""
    if not isinstance(payload, dict):
        return ""
    for scope in (payload, payload.get("data"), payload.get("result")):
        if not isinstance(scope, dict):
            continue
        for key in _COMMAND_ID_KEYS:
            value = scope.get(key)
            if value not in (None, ""):
                return str(value)
    return ""


def _map_command_status(payload: Any) -> str:
    """把 `queryProcessResult` 的响应映射成 pending / done / failed。

    保守方向：**任何读不出来的情况都返回 pending**，绝不返回 done。
    """
    if not isinstance(payload, dict):
        return "pending"
    scope = payload.get("data") if isinstance(payload.get("data"), dict) else payload

    for key in ("processStatus", "status", "state", "result", "processResult"):
        if key not in scope:
            continue
        value = scope[key]
        if isinstance(value, bool):
            return "done" if value else "failed"
        text = str(value).strip().lower()
        if text in ("1", "success", "done", "finished", "complete", "completed", "true", "ok"):
            return "done"
        if text in ("2", "3", "-1", "fail", "failed", "error", "false"):
            return "failed"
        if text in ("0", "pending", "processing", "running", "in_progress"):
            return "pending"
    return "pending"


def _map_capabilities(raw: Any) -> dict[str, bool] | None:
    """把 `/ms-vehicle-capability-set/...` 形态的报文映射成「功能 → 是否支持」。

    ⚠️ 该接口当前**用不上**：它在 snc-tsp-api 上是网关级 404（路由未注册），
    能力已改由 `_map_permissions` 从权限包推导。此函数保留是为了——
    万一该服务日后上线，解析逻辑已经写好且有测试守着，不必重写。

    兼容两种常见形态：
      ① 本身就是 `{键: 布尔}` 的扁平字典；
      ② `{list|records|items: [{code/name, available/support}, ...]}`。
    两种都对不上就返回 None —— 前端会退回"全部显示"，
    这比给出一个错误的裁剪结果安全得多。
    """
    if not isinstance(raw, dict):
        return None
    scope = raw.get("data") if isinstance(raw.get("data"), dict) else raw

    # 形态①：扁平布尔字典
    flat = {k: v for k, v in scope.items() if isinstance(v, bool)}
    if flat:
        return flat

    # 形态②：能力项列表
    for key in ("list", "records", "items", "capabilities", "available"):
        items = scope.get(key)
        if not isinstance(items, list):
            continue
        mapped: dict[str, bool] = {}
        for item in items:
            if not isinstance(item, dict):
                continue
            name = (item.get("code") or item.get("name")
                    or item.get("key") or item.get("capability"))
            if not name:
                continue
            flag = item.get("available", item.get("support",
                   item.get("supported", item.get("enable"))))
            mapped[str(name)] = bool(flag) if flag is not None else False
        if mapped:
            return mapped
    return None


#: 官方「权限包」→ 本项目「功能可用性」的映射。
#
# 2026-10-16 真车实测：`GET /ms-app-bff/api/1.0/permissions` 返回的是
# **服务 / 功能权限包 ID 列表**（`charge-manage` / `vehicle-defence` /
# `owner-vehicle-trail` …），**不是**逐项硬件能力表。
#
# 因此这里划一条硬边界 —— 只允许隐藏「由权限接口管辖」的功能：
#   · 映射表里出现过的 cap key：未命中就置 False
#     （权限清单是完整清单，缺了就是确实没开通）；
#   · 不在映射表里的 cap key（胎压 / 空调 / 车窗 / 门锁 / 后备箱 /
#     除霜 / 座椅加热 …）：**一个字都不写** —— 前端 `cap()` 对缺失键
#     返回 true，照常显示。
#
# 依据：权限接口不回答硬件问题，拿它去隐藏硬件按钮就是臆测。
# 宁可多显示一个"按了没反应"的按钮，也不能把真车有的功能藏起来。
_PERMISSION_TO_CAPABILITY: dict[str, tuple[str, ...]] = {
    "charge-manage": ("chargingPlan",),
    "vehicle-defence": ("sentinel", "sentinelPhoto"),
    "owner-vehicle-trail": ("travelPlan", "tripTrack"),
    "journey-h5-owner": ("travelPlan", "tripTrack"),
    "Rear_seat_ventilation": ("seatVent",),
}


def _extract_permissions(raw: Any) -> list[str] | None:
    """取出权限包 ID 列表。

    真车实测形态（2026-10-16，`GET /ms-app-bff/api/1.0/permissions`）::

        {"code": "000000", "msg": "ok", "success": true,
         "data": ["vehicle-share", "vehicle-defence", ...]}

    结构不认识时返回 None —— 前端退回"全部显示"。
    注意 `data: []`（该平台下无权限）与 None 语义不同：前者是"确认没有"，
    会原样返回空列表，不会被误当成"解析失败"。
    """
    if not isinstance(raw, dict):
        return None
    scope: Any = raw.get("data") if "data" in raw else raw
    if isinstance(scope, list):
        items = scope
    elif isinstance(scope, dict):
        items = None
        for key in ("list", "records", "items", "permissions", "data"):
            if isinstance(scope.get(key), list):
                items = scope[key]
                break
        if items is None:
            return None
    else:
        return None

    result: list[str] = []
    for item in items:
        if isinstance(item, str):
            text = item.strip()
        elif isinstance(item, dict):
            name = (item.get("code") or item.get("name")
                    or item.get("permission") or item.get("key"))
            text = str(name).strip() if name else ""
        else:
            text = ""
        if text:
            result.append(text)
    return result


def _map_permissions(permissions: list[str] | None) -> dict[str, bool] | None:
    """把权限包列表映射成「功能 → 是否可用」。

    只写 `_PERMISSION_TO_CAPABILITY` 里声明过的 cap key（边界说明见该表）。
    同一 cap key 可能被多个权限包覆盖（`travelPlan` 同时来自
    `owner-vehicle-trail` 与 `journey-h5-owner`）→ 取"或"。
    """
    if permissions is None:
        return None
    granted = {p.strip().lower() for p in permissions if p and p.strip()}
    mapped: dict[str, bool] = {}
    for permission, caps in _PERMISSION_TO_CAPABILITY.items():
        hit = permission.lower() in granted
        for cap_key in caps:
            mapped[cap_key] = mapped.get(cap_key, False) or hit
    return mapped


def _map_charge_plan(raw: Any) -> dict[str, Any] | None:
    """把预约充电计划映射成前端契约。

    字段名不确定 → 多候选尝试；一个都取不到就返回 None（前端不显示该卡），
    绝不编造"已启用"这种会让用户误判的值。
    """
    if not isinstance(raw, dict):
        return None
    scope = raw.get("data") if isinstance(raw.get("data"), dict) else raw
    if not scope:
        return None

    def pick(*keys: str) -> Any:
        for k in keys:
            value = scope.get(k)
            if value not in (None, ""):
                return value
        return None

    plan = {
        "enabled": bool(pick("enable", "enabled", "planEnable", "switchStatus") or False),
        "startTime": pick("startTime", "chargeStartTime", "beginTime"),
        "endTime": pick("endTime", "chargeEndTime", "stopTime"),
        "targetSoc": pick("targetSoc", "socLimit", "chargeLimit", "targetChargeSoc"),
        "mode": pick("mode", "planMode", "strategy"),
    }
    return plan if any(v is not None for v in plan.values()) else None


def _normalize_power(raw: Any) -> float | None:
    """归一化充电功率为 kW。

    网关返回的量纲在不同车型/固件下不一致：可能是瓦特（如 118000），
    也可能是 kW（如 118）或已缩放的 0.001kW（如 118000 * 0.001 前后）。
    按量级推断比硬编码缩放更稳健。

    > 真机验证建议：充电时对照官方 App 显示的功率，确认本推断是否成立。
    """
    if raw is None:
        return None
    try:
        value = float(raw)
    except (TypeError, ValueError):
        return None
    if value <= 0:
        return 0.0
    # 大于 1000 按瓦特处理，否则视为已是 kW
    return round(value / 1000.0, 2) if value > 1000 else round(value, 2)


def build_trip_id(
    raw_id: Any,
    start_time: Any,
    end_time: Any,
    distance: Any,
) -> str:
    """为一条行程生成**稳定且不碰撞**的 trip_id。

    修复背景：此前退化为 `str(raw.get("id") or raw.get("journeyId") or "")`，
    网关未返回 id 时得空串。而 `trips` 表以 `trip_id TEXT PRIMARY KEY` +
    `INSERT OR REPLACE` 写入，多条空串行程会互相覆盖 —— 实测写入 3 条，
    库里只剩 1 条（静默丢失，且丢失的恰好是后面覆盖前面的）。

    无 id 时改用业务字段派生指纹：起止时间 + 里程。同一辆车在同一秒、
    同一里程跑出两条行程的概率可忽略，而网关的行程记录天然按时间区分，
    因此该指纹足以稳定标识一条行程。

    > 有 id 时仍以 id 为准（网关给的标识优先），仅在缺失时兜底。
    """
    given = "" if raw_id is None else str(raw_id).strip()
    if given:
        return given

    fingerprint = "|".join(
        str(part if part is not None else "") for part in (start_time, end_time, distance)
    )
    return f"derived-{md5(fingerprint.encode('utf-8')).hexdigest()[:16]}"


def _map_station(raw: dict[str, Any]) -> dict[str, Any]:
    """把极氪气泡站点的 23 个字段裁剪成前端真正要用的那一小部分。

    裁剪而非透传的理由：原响应里大半是图层样式（`layer` / `reduceLevel` /
    `showSizeLevel`）、营销位（`monthCardTag` / `bubblesLeftIconUrl`）与内部
    枚举（`businessType` / `mapStationType`），透传只会让前端契约跟着网关一起漂。

    ⚠️ `lat` / `lng` 上游是**字符串**（`"31.192308"`），必须转数字 ——
    否则前端算距离会静默变成字符串运算，得到莫名其妙的排序。
    """

    def num(key: str) -> float | None:
        value = raw.get(key)
        if value in (None, ""):
            return None
        try:
            return float(value)
        except (TypeError, ValueError):
            return None

    def count(key: str) -> int | None:
        value = raw.get(key)
        return value if isinstance(value, int) else None

    return {
        "stationId": str(raw.get("stationId") or ""),
        # 站名 / 地址 / 评分上游**不给**，由浩汉 detail 补齐（见 adapters/haohan.py）
        "lat": num("lat"),
        "lng": num("lng"),
        "operatorLogo": str(raw.get("operatorAvatar") or ""),
        "selfOperate": bool(raw.get("selfOperateFlag")),
        "marketingPrice": bool(raw.get("marketingPriceFlag")),
        # 可用枪 / 总枪 / 交流枪 / 直流枪
        "availableCount": count("availableCount"),
        "totalCount": count("allConnectorCount"),
        "acCount": count("acCount"),
        "dcCount": count("dcCount"),
        # 分功率的"可用"数（`ableXxx` 是上游拼法，别"纠正"成 able）
        "ableAcCount": count("ableAcCount"),
        "ableDcCount": count("ableDcCount"),
        "stationStatus": count("stationStatus"),
    }


class LiveZeekrClient(ZeekrClient):
    """真实对接极氪国区网关。"""

    def __init__(self, cfg: ZeekrConfig) -> None:
        self.cfg = cfg
        self._session: dict[str, Any] = {}
        self._http = httpx.AsyncClient(timeout=TIMEOUT, follow_redirects=True)
        self._load_session()

    # MARK: - 会话持久化

    def _load_session(self) -> None:
        path = self.cfg.session_file
        if path.exists():
            try:
                self._session = json.loads(path.read_text("utf-8"))
                logger.info("已载入会话缓存：%s", path)
            except (json.JSONDecodeError, OSError) as exc:
                logger.warning("会话文件损坏，忽略：%s", exc)
                self._session = {}

    def _save_session(self) -> None:
        path = self.cfg.session_file
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(self._session, ensure_ascii=False, indent=2), "utf-8")
        # 会话含令牌，收紧权限
        path.chmod(0o600)

    # MARK: - 认证

    def _device_id(self) -> str:
        """设备标识（GW1 与 GW3 共用同一个值）。

        两个作用：
          - GW1：发码与登录**必须是同一个** `deviceId`，否则登录 body 会被
            以 `000005 …设备id不能为空` 拒绝；
          - GW3：作为 `X-DEVICE-ID` 头（**在签名白名单内**），且**同一会话内
            保持一致** —— 每次换新值容易被网关当成「更换设备」。
        持久化在会话里。
        """
        did = self._session.get("device_id")
        if not did:
            did = uuid.uuid4().hex
            self._session["device_id"] = did
        return did

    @staticmethod
    def _is_gw1_success(payload: dict[str, Any]) -> bool:
        """GW1 的成功判定。

        只认明确的成功码。**不能**把「没有 code 字段」当成成功 —— 原实现
        的条件里带了 `None`，任何缺 code 的响应（含错误页）都会被误判成成功。
        """
        if payload.get("success") is True:
            return True
        return str(payload.get("code", "")).strip() in ("0", "000000")

    async def send_sms_code(self, phone: str) -> dict[str, Any]:
        """请求短信验证码（GW1）。

        正确形态（2026-10-16 实测确认，此前实现的要素几乎全错）：
          - **GET**（不是 POST）
          - 路径 `/zeekrlife-app-user/v1/user/pub/sms/authCode`
            —— `/login/mobile` 是**登录**用的，不是发码
          - 参数走 **query**：`mobile` / `x_ca_time` / `regionCode`
          - 认证头为 `x_ca_*` 系列 + 安卓客户端身份（见 `build_gw1_headers`）
        """
        path = "/zeekrlife-app-user/v1/user/pub/sms/authCode"
        params = {
            "mobile": phone,
            "x_ca_time": str(int(time.time() * 1000)),
            "regionCode": "+86",
        }
        headers = build_gw1_headers(device_id=self._device_id())

        try:
            resp = await self._http.get(
                f"{GW1_HOST}{path}", params=params, headers=headers
            )
            payload = resp.json()
        except (httpx.HTTPError, json.JSONDecodeError) as exc:
            logger.error("请求验证码失败：%s", exc)
            return {"success": False, "message": f"网络请求失败：{exc}"}

        if self._is_gw1_success(payload):
            return {"success": True, "message": "验证码已发送，请查收短信"}

        return {
            "success": False,
            "message": payload.get("msg") or payload.get("message") or "验证码发送失败",
        }

    async def verify_sms_code(self, phone: str, code: str) -> dict[str, Any]:
        """校验验证码并完成三级登录。"""
        # 第一级：GW1 手机号登录，换取 JWT
        try:
            await self._login_gw1(phone, code)
        except ZeekrAPIError as exc:
            return {"success": False, "message": exc.message}

        # 第二级：GW2（`api.zeekrline.com`）**暂不尝试**。
        #
        # 实测：其换令牌候选 `/app/login/v1/getTokenByCode` 在 api-gw-toc 与
        # api.zeekrline 上**都是 404**，每次登录只是白刷两条无效请求与告警。
        # 而 GW1 → GW3 已足够读取车数据（参考实现也只走这两级）。
        # `_login_gw2` 方法保留，待日后定位到真实端点再接回。
        self._session["gw2_token"] = ""

        # 第三级：GW3 登录（失败不阻断 —— 后续读取时会另行报错）
        try:
            await self._login_gw3()
        except ZeekrAPIError as exc:
            logger.warning("GW3 登录失败：%s", exc)
            self._session["gw3_token"] = ""

        self._session["phone"] = phone
        self._save_session()

        vehicles = await self.list_vehicles()
        return {
            "success": True,
            "message": "登录成功",
            "vehicle_count": len(vehicles),
        }

    async def _login_gw1(self, phone: str, code: str) -> None:
        """GW1 手机号 + 短信验证码登录，拿到 JWT。

        与发码**不是同一条路径**（此前误以为靠 body 是否带 code 区分阶段）：
        发码 = `GET /pub/sms/authCode`，登录 = `POST /login/mobile`。

        body 的字段名以实测为准 —— 少任何一个都会得到
        `000005 ip不能为空,设备id不能为空,手机验证码不能为空,channel不能为空`。
        """
        path = "/zeekrlife-app-user/v1/user/pub/login/mobile"
        device_id = self._device_id()
        body = {
            "mobile": phone,
            "deviceId": device_id,
            "smsCode": code,
            "channel": 2,
            "x_ca_time": str(int(time.time() * 1000)),
            "deviceName": GW1_DEVICE_MODEL,
            "skipSmsCode": "0",
            "regionCode": "+86",
            # 官方 App 会带一个 ip 字段（其网络环境），网关要求非空。
            # 服务端无从得知真实客户端 IP，这里填占位值 —— 与参考实现一致。
            "ip": "192.168.1.1",
        }
        headers = build_gw1_headers(device_id=device_id)

        resp = await self._http.post(f"{GW1_HOST}{path}", json=body, headers=headers)
        payload = self._unwrap(resp.json())

        # 令牌可能落在多个位置；GW1 回的 JWT 自带 "Bearer " 前缀。
        data = payload.get("data") if isinstance(payload.get("data"), dict) else {}
        token = (
            payload.get("jwtToken")
            or payload.get("token")
            or data.get("jwtToken")
            or data.get("token")
            or data.get("tokenValue")
            or data.get("accessToken")
        )
        if not token:
            raise ZeekrAPIError(
                str(payload.get("code", "unknown")),
                payload.get("msg") or "登录失败：未返回令牌",
                payload,
            )

        self._session["gw1_jwt"] = token
        # 立即落盘。后续 GW2/GW3 只要有一步抛异常，`verify_sms_code` 末尾那次
        # 保存就执行不到 —— 这一级拿到的 JWT 会跟着丢，用户得**重新发短信**。
        # 而验证码有频率限制，丢一次的成本远高于多写一次文件。
        self._save_session()

    async def _login_gw2(self) -> None:
        """GW2 用 GW1 JWT 换取 ecar accessToken。"""
        jwt = self._session.get("gw1_jwt")
        if not jwt:
            raise ZeekrAuthError("缺少 GW1 令牌")

        # 换令牌的真实接口：官方 APK 里已验证存在 `/app/login/v1/getTokenByCode`
        # （同族还有 `/app/login/v1/getJwtAuthorizationByToken`、`/auth/login/refresh`）。
        #
        # 原实现用的 `/ms-user-auth/v1.0/auth/login` 有两处问题：
        #   ① 缺 `/api` 段 —— 官方 ms-* 路径一律是 `/ms-<服务>/api/<版本>/...`；
        #   ② 该路径**在官方 APK 中 0 命中** —— ms-user-auth 下只有
        #      `auth/scanLogin`、`auth/cloud/temp/code`，没有 `auth/login`。
        #
        # ⚠️ 未定项：该接口挂在哪个主机上，静态分析无法确定（字符串扫描只能证明
        #    路径存在，证明不了 host 绑定）。故按置信度顺序逐个尝试，任一成功即返回。
        # 只保留官方 APK 中**确实存在**的路径。原先还挂着两条兜底
        # `/ms-user-auth[/api]/v1.0/auth/login` —— 已对官方 v5.0.7 的 classes.dex
        # 做原始字节精确计数，**二者均为 0 命中**，属自造路径，留着只会白费两次
        # 必然失败的请求，故移除。ms-user-auth 下真实存在的是
        # `auth/scanLogin`、`auth/cloud/temp/code`。
        candidates = (
            (GW1_HOST, "/app/login/v1/getTokenByCode"),
            (GW2_HOST, "/app/login/v1/getTokenByCode"),
        )

        last_error: ZeekrAPIError | None = None
        payload: dict[str, Any] = {}

        for host, path in candidates:
            headers = sign_gw2(
                self.cfg.hmac_access_key, self.cfg.hmac_secret_key, "POST", path
            )
            headers["Authorization"] = f"Bearer {jwt}"

            try:
                resp = await self._http.post(f"{host}{path}", headers=headers)
                payload = self._unwrap(resp.json())
            except (ZeekrAPIError, httpx.HTTPError, json.JSONDecodeError) as exc:
                logger.warning("GW2 换令牌尝试失败（%s%s）：%s", host, path, exc)
                last_error = exc if isinstance(exc, ZeekrAPIError) else None
                continue

            token = (
                (payload.get("data") or {}).get("accessToken")
                or payload.get("accessToken")
            )
            if token:
                self._session["gw2_token"] = token.replace("Bearer ", "")
                refresh = (payload.get("data") or {}).get("refreshToken")
                if refresh:
                    self._session["gw2_refresh"] = refresh
                logger.info("GW2 换令牌成功：%s%s", host, path)
                # 立即落盘：此前只在 verify_sms_code 末尾存过一次，导致运行期间刷新出来的
                # 新令牌从不持久化 —— 重启后载入的是磁盘上那份（可能已过期）的旧令牌。
                self._save_session()
                return

            last_error = ZeekrAPIError(
                str(payload.get("code", "unknown")),
                payload.get("msg") or "GW2 登录失败",
                payload,
            )
            logger.warning("GW2 换令牌未返回令牌（%s%s）：%s", host, path, last_error.message)

        raise last_error or ZeekrAuthError("GW2 换令牌全部候选失败")

    @staticmethod
    def _bearer(token: str) -> str:
        """确保令牌带 `Bearer ` 前缀。

        GW1 返回的 JWT 有时自带前缀、有时不带，统一处理后再放进 GW3 的 body。
        """
        text = (token or "").strip()
        if not text:
            return ""
        return text if text.lower().startswith("bearer ") else f"Bearer {text}"

    def _encrypted_active_vin(self) -> str | None:
        """当前会话的 VIN（AES 加密后用于 `X-VIN` 头）；没有则返回 None。"""
        vin = self._session.get("active_vin") or ""
        if not vin:
            return None
        try:
            return encrypt_vin(vin, self.cfg.vin_key, self.cfg.vin_iv)
        except Exception:  # noqa: BLE001 - 缺密钥或格式异常时只是不带这个头
            logger.warning("VIN 加密失败，本次请求不带 X-VIN")
            return None

    async def _login_gw3(self) -> None:
        """GW3 登录：用 GW1 的 JWT 换 GW3 访问令牌。

        ⚠️ 2026-10-16 更正。此前用的是 `/app/login/v1/getTokenByCode`
        —— 那是 GW1/GW2 的换令牌路径，在 GW3 上必然 404；body 里也只有
        `loginDeviceId`/`appVersion`/`refreshToken`。

        与已验证的参考实现对照后确认的正确形态：

            路径  `POST /ms-user-auth/v1.0/auth/login`
            body  `identityType=5` + `token=<GW1 的 JWT>` ← **这两个是关键**

        少了 `identityType` 与 `token`，网关无从判断是谁在换令牌。
        """
        path = "/ms-user-auth/v1.0/auth/login"
        jwt = self._session.get("gw1_jwt") or ""
        if not jwt:
            raise ZeekrAuthError("缺少 GW1 令牌，无法换 GW3 令牌")

        body = compact_json({
            "credential": "",
            "identifier": "",
            "identityType": 5,
            "loginDeviceId": build_login_device_id(),
            "loginDeviceJgId": "",
            "loginDeviceType": 1,
            "loginPhoneBrand": "Android",
            "loginPhoneModel": GW1_DEVICE_MODEL,
            "loginSystem": "Android",
            # 直接把 GW1 返回的 JWT 放进 body（不是 Authorization 头）
            "token": self._bearer(jwt),
        })

        headers = build_gw3_headers(
            prod_secret=self.cfg.prod_secret,
            method="POST",
            path=path,
            body=body,
            encrypted_vin=self._encrypted_active_vin(),
            device_id=self._device_id(),
        )

        try:
            resp = await self._http.post(
                f"{GW3_HOST}{path}", content=body.encode("utf-8"), headers=headers
            )
            payload = self._unwrap(resp.json())
        except (httpx.HTTPError, json.JSONDecodeError) as exc:
            raise ZeekrAPIError("unknown", f"GW3 登录请求失败：{exc}", None) from exc

        data = payload.get("data") if isinstance(payload.get("data"), dict) else {}
        token = (
            data.get("accessToken")
            or payload.get("accessToken")
            or data.get("token")
            or data.get("tokenValue")
        )
        if not token:
            raise ZeekrAPIError(
                str(payload.get("code", "unknown")),
                payload.get("msg") or "GW3 登录失败：未返回令牌",
                payload,
            )

        self._session["gw3_token"] = str(token).replace("Bearer ", "")
        refresh = data.get("refreshToken") or payload.get("refreshToken")
        if refresh:
            self._session["gw3_refresh"] = refresh
        # 登录成功即落盘。原实现的 `_save_session()` 被放在 `raise` 之后，
        # 属于**不可达代码** —— 换出来的新令牌从不持久化，重启就回到旧的。
        self._save_session()
        logger.info("GW3 登录成功：%s", path)

    async def is_authenticated(self) -> bool:
        """当前是否持有**可用**的登录态。

        不能只看"令牌存在"。会话是落盘复用的，重启后磁盘上的 gw1_jwt 可能
        早已过期，此时仍返回 True 会让设置页显示「已登录」而实际点什么都失败。
        这里读 JWT 的 exp 做判断；读不出来（无 exp 或格式不标准）时按"不知道"
        处理，沿用旧行为 —— 宁可漏判过期，也不要误判成未登录把用户踢下线。
        """
        token = self._session.get("gw1_jwt")
        if not token:
            return False
        exp = _jwt_expires_at(str(token))
        if exp is None:
            return True
        # 留 30 秒余量，避免刚好卡在边界的请求
        return exp > datetime.now().timestamp() + 30

    async def logout(self) -> None:
        self._session = {}
        if self.cfg.session_file.exists():
            self.cfg.session_file.unlink()

    # MARK: - 请求辅助

    @staticmethod
    def _assert_query_signable(query: dict[str, str] | None) -> None:
        """拦住会导致「签名串与实际发送字节分叉」的 query 值。

        签名走 `zeekr_signing._escape_query_value`（`*`→`%2A`、撤销 `%2F`/`%3F`
        的编码），实际发送却交给 httpx 的 `params=` 自行编码。两者只对
        「无特殊字符」的值一致。当前只有 latest=false / target=new，相安无事；
        但以后若有人传入含 `*` `/` `?` 空格或非 ASCII 的值，网关会报 079025，
        而签名串"看起来"是对的 —— 极难定位。

        这里显式拦住，把静默失效变成即时可见的错误。真需要传特殊字符时，
        应改为自行拼好 query 字符串并让签名与发送复用同一份编码结果。
        """
        for key, value in (query or {}).items():
            if not _QUERY_SAFE.match(str(value)):
                raise ZeekrAPIError(
                    "bad_query",
                    f"query 参数 {key}={value!r} 含特殊字符，签名与实际编码会分叉；"
                    "请改用自行拼接的原始 query 字符串",
                )

    @staticmethod
    def _unwrap(payload: Any) -> dict[str, Any]:
        """解包网关响应，识别错误信封。

        网关失败时可能返回 `{"code","msg","success"}` 形式的错误信封，
        而非车辆数据 —— 必须识别出来，避免污染解析结果。

        关键点：**错误信封并不总是带 `success` 字段**，更常见的形态是只有
        `{"code": "079025", "msg": "Signature authentication failed"}`。
        此前 `success` 缺失时默认按 True 处理，于是一整类错误被当成"数据"、
        被后续解析消化成「账号下未找到车辆」—— 真正的原因（签名算错、
        令牌无权）完全看不见，排障方向被彻底带偏。这里对已知业务错误码兜底。
        """
        if not isinstance(payload, dict):
            raise ZeekrAPIError("invalid", "网关返回了非预期格式")

        code = str(payload.get("code", "0"))
        success = payload.get("success")

        if code in KNOWN_ERROR_CODES:
            # 已知业务错误码：无论有没有 success 都算失败
            ok = False
        elif success is None:
            # 确实没有 success 字段，且不属于已知错误码 —— 交给上层判断
            ok = True
        else:
            ok = bool(success)

        # 错误信封：只有 code/msg 而没有业务字段
        if not ok and code not in ("0", "000000"):
            raise ZeekrAPIError(
                code,
                payload.get("msg") or payload.get("message") or "请求失败",
                payload,
            )

        return payload

    def _encrypted_vin(self, vin: str) -> str | None:
        """优先使用抓包得到的 X-VIN 令牌，否则本地加密。

        空 VIN 返回 `None`（= **不带这个头**）。车辆列表这类接口本来就不需要
        `X-VIN`，而调用方会传空串；此前把空串直接交给 `encrypt_vin`，会抛
        `ValueError: VIN 不能为空` 并把整个登录流程带崩（2026-10-16 实测踩到）。
        """
        if self.cfg.vehicle_token:
            return self.cfg.vehicle_token
        if not vin:
            return None
        return encrypt_vin(vin, self.cfg.vin_key, self.cfg.vin_iv)

    async def _request_gw3(
        self,
        method: str,
        path: str,
        vin: str,
        body: dict[str, Any] | None = None,
        query: dict[str, str] | None = None,
        retry_on_session_conflict: bool = True,
        extra_headers: dict[str, str] | None = None,
    ) -> dict[str, Any]:
        """发起 GW3 请求，自动处理签名与令牌问题。

        Args:
            extra_headers: 个别服务的**必填但非签名**头（如充电记录的
                `X-TENANT-ID` / `X-VEHICLE-BRAND`）。它们不参与验签
                （见 `GW3_SIGNED_HEADERS` 白名单），所以可以在签名之后追加。
                不要用它在调用处覆盖签名头 —— 那样只会得到验签失败。
        """
        self._assert_query_signable(query)
        body_str = compact_json(body) if body is not None else None

        headers = build_gw3_headers(
            prod_secret=self.cfg.prod_secret,
            method=method,
            path=path,
            query=query,
            body=body_str,
            # 没有令牌时**不带这个头**（而不是发一个空的 `Bearer `）——
            # 空的令牌头可能被网关当成"无效凭据"，把错误码带到别处。
            authorization=(
                f"Bearer {self._session['gw3_token']}"
                if self._session.get("gw3_token")
                else None
            ),
            encrypted_vin=self._encrypted_vin(vin),
            device_id=self._device_id(),
        )
        if extra_headers:
            headers.update(extra_headers)

        kwargs: dict[str, Any] = {"headers": headers}
        if body_str is not None:
            kwargs["content"] = body_str.encode("utf-8")
        if query:
            kwargs["params"] = query

        resp = await self._http.request(method, f"{GW3_HOST}{path}", **kwargs)
        payload = resp.json()
        code = str(payload.get("code", "0"))

        # 079025 是一个**复用**的错误码，网关用它表示两类完全不同的问题：
        #   · "Signature authentication failed" → 签名串构造错了（查白名单/换行/body 字节）
        #   · "Decrypt X-VIN failed"            → X-VIN 解不开（查 VIN 的 AES 密钥/IV）
        # 常量 ERR_SIGNATURE 此前**定义了却从未被引用**，这条错误会被 _unwrap
        # 静默放过，最终表现为误导性的「未找到车辆」。这里按 msg 分流，把可操作
        # 的线索直接打出来 —— 只报码不报 msg 会把人引到完全错误的排查方向
        # （2026-10-16 实测：X-VIN 密钥填错时，日志却一直在说"签名有问题"）。
        if code == ERR_SIGNATURE:
            msg = str(payload.get("msg") or "").lower()
            if "x-vin" in msg or "decrypt" in msg:
                logger.error(
                    "GW3 无法解密 X-VIN（%s：%s）：请核对 .env 的 ZEEKR_VIN_KEY / "
                    "ZEEKR_VIN_IV。注意 extract_keys.py 从 APK 提取的那组值实测不可用",
                    code, payload.get("msg"),
                )
            else:
                logger.error(
                    "GW3 签名校验失败（%s：%s）：请核对 GW3_SIGNED_HEADERS 白名单、"
                    "待签名串的换行规则，以及参与签名的 body 是否与实发字节完全一致",
                    code, payload.get("msg"),
                )

        # 会话被新登录顶替：重登一次再试
        if code == ERR_LOGGED_IN_ELSEWHERE and retry_on_session_conflict:
            logger.info("会话被顶替，尝试重新登录")
            await self._login_gw3()
            return await self._request_gw3(
                method, path, vin, body, query, retry_on_session_conflict=False
            )

        # 接口未授权：属令牌代际问题，交由上层回退 GW2，**不重登**
        # （误判为重登会作废自己正在用的令牌）
        if code == ERR_UNAUTHORIZED:
            raise ZeekrAPIError(code, "GW3 接口未被授权", payload)

        return self._unwrap(payload)

    async def _request_gw2(
        self,
        method: str,
        path: str,
        body: dict[str, Any] | None = None,
        query: dict[str, str] | None = None,
        retry_on_session_conflict: bool = True,
    ) -> dict[str, Any]:
        """发起 GW2 请求。

        与 GW3 对齐：会话被新登录顶替（079021）时自动重登并重试一次。
        此前 GW2 完全没有这条自愈分支 —— 令牌一被顶替就只会失败，
        用户被迫重新走一遍短信验证。
        """
        self._assert_query_signable(query)
        body_str = compact_json(body) if body is not None else None
        headers = sign_gw2(
            self.cfg.hmac_access_key,
            self.cfg.hmac_secret_key,
            method,
            path,
            query=query,
            body=body_str,
        )
        headers["Authorization"] = f"Bearer {self._session.get('gw2_token', '')}"

        kwargs: dict[str, Any] = {"headers": headers}
        if body_str is not None:
            kwargs["content"] = body_str.encode("utf-8")
        if query:
            kwargs["params"] = query

        resp = await self._http.request(method, f"{GW2_HOST}{path}", **kwargs)
        payload = resp.json()
        code = str(payload.get("code", "0"))

        if code == ERR_LOGGED_IN_ELSEWHERE and retry_on_session_conflict:
            logger.info("GW2 会话被顶替，尝试重新登录")
            await self._login_gw2()
            return await self._request_gw2(
                method, path, body, query, retry_on_session_conflict=False
            )

        return self._unwrap(payload)

    # MARK: - 车辆数据

    async def list_vehicles(self) -> list[dict[str, Any]]:
        """获取车辆列表（该接口不需要 X-VIN，通常最稳）。

        端点取自**已验证的参考实现**：

            GET /ms-app-bff/api/v3.0/veh/vehicle-list?needSharedCar=true

        历史缺陷：此前用 `POST` + `body={pageNum,pageSize}` 去打三条候选路径
        （`ms-vehicle-core/.../favorite-vehicles`、`ms-vehicle-account/.../vehicle-detail`
        等），**全部 0 命中** —— 官方把「我的车辆」放在 `ms-app-bff` 下，
        且是 GET + 查询参数，不是 POST + body。
        """
        candidates = (
            "/ms-app-bff/api/v3.0/veh/vehicle-list",
            "/ms-app-bff/api/v4.0/veh/vehicle-list",   # 另一实现所用的版本，兜底
        )

        for path in candidates:
            try:
                payload = await self._request_gw3(
                    "GET", path, vin="", query={"needSharedCar": "true"}
                )
            except (ZeekrAPIError, httpx.HTTPError) as exc:
                logger.warning("GW3 获取车辆列表失败（%s）：%s", path, exc)
                continue

            vehicles = self._extract_vehicle_list(payload)
            if vehicles:
                logger.info("车辆列表成功：%s", path)
                self._session["last_vehicle_list_source"] = "gw3"
                self._session["last_vehicle_list_path"] = path
                # 落盘默认车的 VIN —— 很多 GW3 接口**必须带 X-VIN**
                # （权限集缺了直接 079001，车况也因此读不出来）。
                # 此前 active_vin 从未被写入，于是这些请求全都在裸奔：
                # 表现为"接口 404 / 079001"，而真正原因是**没告诉服务端是哪台车**。
                if not self._session.get("active_vin"):
                    vin = vehicles[0].get("vin") or ""
                    if vin:
                        self._session["active_vin"] = vin
                        self._save_session()
                return vehicles

        return []

    @staticmethod
    def _extract_vehicle_list(payload: dict[str, Any]) -> list[dict[str, Any]]:
        """从各代网关的响应中提取车辆列表。"""
        data = payload.get("data") or payload
        if isinstance(data, dict):
            for key in ("list", "records", "vehicleList", "vehicles", "items"):
                items = data.get(key)
                if isinstance(items, list):
                    return LiveZeekrClient._normalize_vehicles(items)
        if isinstance(data, list):
            return LiveZeekrClient._normalize_vehicles(data)
        return []

    @staticmethod
    def _normalize_vehicles(items: list[dict[str, Any]]) -> list[dict[str, Any]]:
        """归一化车辆条目。

        设备名按 `昵称 → 车牌 → 车型` 取第一个非空值；
        车型名用 `seriesCodeVs` 映射（后端的 `modelName` 是目录配置名，不可靠）。
        """
        series_names = {
            "BX1E": "极氪 X",
            "DC1E": "极氪 001",
            "EX1E": "极氪 007",
            "CM1E": "极氪 009",
            "BC1E": "极氪 7X",
        }
        result: list[dict[str, Any]] = []
        for raw in items:
            entry = raw.get("entry") or raw
            model = entry.get("modelName") or ""
            # 去掉 "-001" 这类目录编号
            if "-" in model:
                model = model.split("-")[0]

            # 车型：实报里**没有** `seriesCodeVs`（那是自造名，0 命中），
            # 真正在的是 `appModelCode` / `appInnerCode` / `appYearCode`
            # （实测值 `DC1E-A3` / `DC1E-A3-001`）—— 取 `-` 前的车型代号去查表。
            series = ""
            for key in ("appModelCode", "appInnerCode", "appYearCode", "seriesCodeVs"):
                value = str(entry.get(key) or "")
                if value:
                    series = value.split("-")[0]
                    break

            result.append({
                "vin": entry.get("vin") or entry.get("vehicleId") or "",
                "nickname": entry.get("nickName") or entry.get("nickname") or "",
                "plateNo": entry.get("plateNo") or "",
                "modelName": series_names.get(series, model or "极氪"),
                "isOwner": bool(entry.get("isOwner", False)),
            })
        return result

    async def get_vehicle_status(self, vin: str | None = None) -> dict[str, Any]:
        """获取车辆实时状态。"""
        target_vin = vin or self._session.get("active_vin") or ""
        if not target_vin:
            vehicles = await self.list_vehicles()
            if not vehicles:
                raise ZeekrAPIError("no_vehicle", "账号下未找到车辆")
            target_vin = vehicles[0]["vin"]
            self._session["active_vin"] = target_vin

        # 端点与参数取自**已验证的参考实现**，两个要点：
        #   1. `latest` 是**存在但为空**（`latest=`），不是 `"false"` —— App 就这么发；
        #   2. 版本用 v1.0（参考实现）；官方 APK 里另有 v2.0 同路径，故作候选兜底。
        candidates = (
            "/ms-vehicle-status/api/v1.0/vehicle/status/latest",
            "/ms-vehicle-status/api/v2.0/vehicle/status/latest",
        )
        query = {"latest": "", "target": "new"}

        for path in candidates:
            try:
                payload = await self._request_gw3(
                    "GET", path, vin=target_vin, query=query
                )
            except (ZeekrAPIError, httpx.HTTPError) as exc:
                logger.warning("GW3 获取状态失败（%s）：%s", path, exc)
                continue

            status = self._normalize_status(payload, target_vin)
            if status.get("soc") is not None:
                self._session["last_status_source"] = f"gw3:{path}"
                return status

        raise ZeekrAPIError("status_unavailable", "未能获取到车辆状态，请检查登录态与账号权限")

    @staticmethod
    def _normalize_status(payload: dict[str, Any], vin: str) -> dict[str, Any]:
        """容错解析车辆状态。

        策略：把报文里**所有叶子节点**建成路径索引，再按别名表匹配。
        这样少数字段名变化不会导致整体失效。
        """
        data = payload.get("data") or payload
        leaves: dict[str, Any] = {}

        def walk(node: Any, prefix: str = "") -> None:
            """递归收集叶子节点，路径用 `.` 分隔。

            分隔符很关键：早期用空串拼接会让相邻字段名粘连
            （`doorstatus` + `frontleft` → `doorstatusfrontleft`），
            虽然当时别名表恰好对应，但任何字段增删都可能产生意外匹配。
            """
            if isinstance(node, dict):
                for k, v in node.items():
                    key = str(k).lower()
                    walk(v, f"{prefix}.{key}" if prefix else key)
            elif isinstance(node, list):
                for i, v in enumerate(node):
                    walk(v, f"{prefix}[{i}]")
            else:
                # 只保留首个非空值，避免被哨兵值覆盖
                if prefix and node not in (None, "", []):
                    leaves.setdefault(prefix, node)

        walk(data)

        # 紧凑索引：剥掉 `.` 与 `[n]`，只留字母数字。
        # 别名表用连续小写字母书写即可，不受路径分隔方式影响。
        compact_leaves: dict[str, Any] = {
            _compact(path): value for path, value in leaves.items()
        }

        # 12V 电瓶电量所在的紧凑路径。动力电池 SOC 的别名匹配**必须排除它** ——
        # 两者字段名同为 chargeLevel，后缀匹配会静默取错值。
        lv_battery_charge_level = "mainbatterystatuschargelevel"

        def pick(*aliases: str, exclude: tuple[str, ...] = ()) -> Any:
            """按别名匹配叶子路径。

            匹配前把两侧的 `.` 与 `[n]` 下标都剥离，只留字母数字。
            这样别名表用「连续小写字母」书写即可，既简洁又对
            路径分隔方式的变化免疫 —— 无论网关返回的层级怎么嵌套，
            只要字段名序列一致就能命中。

            `exclude` 用于排除掉「语义上绝不该被这个别名命中」的路径。
            典型场景：动力电池 SOC 与 12V 电瓶电量都以 `chargeLevel` 结尾，
            后缀匹配会把电瓶的值填进 SOC（实测：报文缺 electricVehicleStatus
            时 soc 被解析成 88，正好等于 12V 电瓶电量）—— 用户会误以为整车满电。
            """
            excluded = tuple(_compact(item) for item in exclude)
            for alias in aliases:
                key = _compact(alias)
                if not key:
                    continue
                # 精确匹配优先（紧凑后完全相同）
                if key in compact_leaves:
                    return compact_leaves[key]
                # 退化为后缀匹配（容忍外层多包了一层）
                for compact_path, value in compact_leaves.items():
                    if any(compact_path.endswith(item) for item in excluded):
                        continue
                    if compact_path.endswith(key):
                        return value
            return None

        def as_float(value: Any, scale: float = 1.0) -> float | None:
            if value is None:
                return None
            try:
                return round(float(value) * scale, 2)
            except (TypeError, ValueError):
                return None

        def as_bool(value: Any) -> bool | None:
            if value is None:
                return None
            if isinstance(value, bool):
                return value
            if isinstance(value, (int, float)):
                return bool(value)
            text = str(value).lower()
            if text in ("true", "1", "yes", "on"):
                return True
            if text in ("false", "0", "no", "off"):
                return False
            return None

        # 注意：SOC 取 electricVehicleStatus.chargeLevel
        # mainBatteryStatus.chargeLevel 是 **12V 电瓶**，不是动力电池。
        # 光靠注释拦不住 —— 两条路径字段名相同，后缀匹配会静默取到电瓶的值，
        # 所以这里显式把 12V 那条排除掉（实测缺 EV 字段时 soc 会变成 88）。
        soc = as_float(
            pick(
                "electricvehiclestatuschargelevel",
                "chargelevel",
                exclude=(lv_battery_charge_level,),
            )
        )
        b12_level = as_float(
            pick("maintenancestatusmainbatterystatuschargelevel", "mainbatterystatuschargelevel")
        )

        # 充电状态：由电流电压推导比 isCharging 标志更可靠
        charge_current = as_float(pick("chargeiact"))
        charge_voltage = as_float(pick("chargeuact"))

        # GPS 坐标：定点整数，实测量纲为「度 × 3,600,000」。
        # 逐个尝试可能的缩放系数 —— 取第一个使纬度落在合理范围内的。
        # 坐标**不能**走 as_float —— 它会统一舍到 2 位，对经纬度来说那是
        # 约 1.1 km 的误差。这里单独转成 float，精度留到下面 round(…, 6)
        # 再定（约 0.1 m）。
        def _raw_float(value: Any) -> float | None:
            if value is None or value == "":
                return None
            try:
                return float(value)
            except (TypeError, ValueError):
                return None

        lat_raw = _raw_float(pick("latitude", "poslat"))
        lon_raw = _raw_float(pick("longitude", "poslon"))
        lat: float | None = None
        lon: float | None = None
        if lat_raw is not None and lon_raw is not None:
            for divisor in (3_600_000.0, 10_000_000.0, 1_000_000.0, 1.0):
                candidate_lat = lat_raw / divisor
                # 中国的纬度范围约 3°N–54°N
                if 3.0 < abs(candidate_lat) < 54.0:
                    lat = round(candidate_lat, 6)
                    lon = round(lon_raw / divisor, 6)
                    break

        # 坐标系：**必须看网关自报的 `marsCoordinates`**，不要凭车型硬编码。
        #   "1" → 已是 GCJ-02（火星坐标），直接给地图用就对了
        #   "0" → 原始 WGS-84，必须转换，否则在地图上偏 400~600 米
        #        （实测该停车点：WGS-84 直连腾讯会偏 485 米 —— 南 202m / 东 441m，
        #         用户反馈"位置偏移有点多"就是它）
        #   缺失 → 保持原样：没有证据就不动，宁可维持旧行为也不要过转。
        # 输出统一为 GCJ-02，前端（网页 / iOS）拿到的坐标可直接喂地图。
        if lat is not None and lon is not None:
            mars_flag = as_bool(pick("marscoordinates"))
            if mars_flag is False:
                lat, lon = wgs84_to_gcj02(lat, lon)

        # 锁车状态：0 = 未锁，非 0 = 已锁
        lock_raw = pick("lockstatus", "centrallockingstatus")
        is_locked = None
        if lock_raw is not None:
            try:
                is_locked = float(lock_raw) != 0
            except (TypeError, ValueError):
                is_locked = as_bool(lock_raw)

        # 预计充满：空闲时返回哨兵值 2047
        ttc = as_float(pick("timetofullycharged"))
        minutes_to_full = None if ttc is None or ttc >= 2047 else ttc

        is_charging = None
        if charge_current is not None and charge_voltage is not None:
            is_charging = (charge_current * charge_voltage) > 500  # 约 0.5kW 以上视为充电中

        # 充电功率：优先用网关直报的字段（经 _normalize_power 按量级归一到 kW），
        # 缺失时再由电流 × 电压推算。
        #
        # 必须用 `is None` 判断，不能用 `or` —— 网关在未充电时直报 0.0，
        # 而 0.0 是 falsy，`or` 会把它误当成"缺失"而回退到推算分支（语义错误）。
        charge_power = _normalize_power(pick("chargepowerkw", "chargepower"))
        if charge_power is None and charge_current is not None and charge_voltage is not None:
            charge_power = round(charge_current * charge_voltage / 1000.0, 2)

        return {
            "vin": vin,
            "nickname": "",
            "plateNo": "",
            "modelName": "极氪 001",
            "soc": soc,
            "rangeKm": as_float(pick("distancetoemptyonbatteryonly", "distancetoempty")),
            "odometerKm": as_float(pick("odometer", "totalmileage")),
            "battery12vVoltage": as_float(pick("mainbatterystatusvoltage", "12vvoltage")),
            "battery12vLevel": b12_level,
            "isCharging": is_charging,
            # 充电枪连接状态：官方真名是 statusOfChargerConnection（v5.0.7 命中 4 次）。
            # 原先的首选名 "chargerConnected" 是自造名 —— 官方包里 0 命中，已移除。
            # 充电枪：`statusOfChargerConnection` 来自 APK（v5.0.7 命中 4 次）；
            # `chargeGunStatus` 是参考实现实测所用的名字。两个都留作候选 ——
            # 不同接口版本（v1.0 / v2.0）的字段名可能不同。
            "isPlugged": as_bool(pick("statusofchargerconnection", "chargegunstatus")),
            # 网关的充电功率量纲在不同车型/固件下不一致（W 或 kW），
            # 已在上方由 _normalize_power 按量级归一到 kW
            "chargePowerKw": charge_power,
            "chargeVoltage": charge_voltage,
            "chargeCurrent": charge_current,
            "minutesToFull": minutes_to_full,
            "chargeLimit": as_float(pick("chargelimit", "soclimit")),  # 真名未确认，见下
            "isLocked": is_locked,
            # 车门状态：改用官方 APK 中确认的字段名（源自 getter
            # `getLeftFrontDoorStatus` / `getRightBackDoorStatus` 等）。
            # 原别名 `doorStatusFrontLeft` 系列在官方包中 0 命中 —— 是自造名，
            # 导致四个车门状态一直静默取不到值。
            # 门：v1.0 实报的是 `doorOpenStatus{Driver,Passenger,DriverRear,PassengerRear}`
            # （见 real payload 取证），APK 里的 `leftFrontDoorStatus` 系列是另一代
            # 命名。两组都留 —— 哪组命中用哪组，互不冲突（后缀匹配不会串位）。
            "doors": {
                "frontLeft": as_bool(
                    pick("dooropenstatusdriver", "leftfrontdoorstatus", "doorstatusfrontleft")
                ),
                "frontRight": as_bool(
                    pick("dooropenstatuspassenger", "rightfrontdoorstatus", "doorstatusfrontright")
                ),
                "rearLeft": as_bool(
                    pick(
                        "dooropenstatusdriverrear",
                        "leftbackdoorstatus",
                        "leftbehinddoorstatus",
                    )
                ),
                "rearRight": as_bool(
                    pick(
                        "dooropenstatuspassengerrear",
                        "rightbackdoorstatus",
                        "rightbehinddoorstatus",
                    )
                ),
            },
            # 车窗状态：官方 APK 确认**存在**该组字段（getter
            # `getLeftFrontWindowStatus` / `getRightBackWindowStatus` /
            # `getWindowStatusSupported`）—— 此前"国区没有稳定车窗字段"的判断是错的。
            #
            # ⚠️ 对外形状必须严格保持「字典 或 None」：iOS 侧把它解码为
            # `[String: Bool]?`（**值不可选**），只要有一个 None 就会
            # valueNotFound、整个 VehicleStatus 解码失败并静默回落到模拟数据
            # —— 这正是当初改成恒 None 的原因，不能倒退回去。
            #
            # 所以规则是：**四个窗都拿到值才给字典，否则整体 None**。
            # 宁可报"未知"，也不能造出一个解码不过的中间态；更不能用
            # False 填充缺失值（那是把"没读到"谎报成"已关好"）。
            # v1.0 实报的是 `climateStatus.winStatus{Driver,Passenger,DriverRear,PassengerRear}`
            # （同时还有 `winPos*`）。⚠️ 但实测驻车锁车时 `winStatus=2` / `winPos=0`
            # —— 这两个值的语义（2 是"关"还是"开"、0 是"关到位"还是"开到位"）**无法
            # 从一次快照判定**，故此处仍只登记别名、`as_bool` 解不出 2 就保持 None。
            # 验证办法：摇下一扇窗再读一次，看 winStatus / winPos 怎么变。
            # 在语义确认前保持「未知」，绝不能把 2 当成"已关"（那是谎报安全状态）。
            "windows": _all_or_none(
                driver=as_bool(pick("winstatusdriver", "leftfrontwindowstatus")),
                passenger=as_bool(pick("winstatuspassenger", "rightfrontwindowstatus")),
                rearLeft=as_bool(
                    pick("winstatusdriverrear", "leftbackwindowstatus", "leftbehindwindowstatus")
                ),
                rearRight=as_bool(
                    pick(
                        "winstatuspassengerrear",
                        "rightbackwindowstatus",
                        "rightbehindwindowstatus",
                    )
                ),
            ),
            # 后备箱：`trunkStatus` 已验证；官方另有上/下分段开启字段
            # （`trunkOpenStatus` / `trunkUpperOpenStatus` / `trunkLowerOpenStatus`）。
            # tailDoorStatus 是自造名（0 命中）。
            "trunkOpen": as_bool(
                pick(
                    "trunkstatus",
                    "trunkopenstatus",
                    "trunkupperopenstatus",
                    "trunkloweropenstatus",
                )
            ),
            # 前备箱：v1.0 实报的是 `engineHoodOpenStatus`（前舱盖）；
            # APK 里的 `frunkOpenStatus` 是另一代命名，作为次选保留。
            "frunkOpen": as_bool(pick("enginehoodopenstatus", "frunkopenstatus")),
            # 胎压：官方字段形如 `leftFrontTyrePressure`（getter
            # `getLeftFrontTyrePressure`），另有 `?Alert` 与 `?Temp` / `?TempAlert`。
            "tyreFrontLeft": as_float(
                pick("leftfronttyrepressure", "tyrestatusdriver", "tyrepressurefrontleft")
            ),
            "tyreFrontRight": as_float(
                pick("rightfronttyrepressure", "tyrestatuspassenger", "tyrepressurefrontright")
            ),
            "tyreRearLeft": as_float(
                pick("leftbacktyrepressure", "leftbehindtyrepressure", "tyrestatusdriverrear")
            ),
            "tyreRearRight": as_float(
                pick("rightbacktyrepressure", "rightbehindtyrepressure", "tyrestatuspassengerrear")
            ),
            # 四轮胎温：v1.0 实报 `tyreTemp{Driver,Passenger,DriverRear,PassengerRear}`。
            # 注意 `tyreTempDriverRear` 与 `tyreTempDriver` 的后缀关系 —— 前者更长，
            # endswith 不会互串，顺序无所谓；但**必须**写全 `rear` 后缀，
            # 否则前轮会误取到后轮的值。
            "tyreTempFrontLeft": as_float(pick("tyretempdriver", "leftfronttyretemp")),
            "tyreTempFrontRight": as_float(pick("tyretemppassenger", "rightfronttyretemp")),
            "tyreTempRearLeft": as_float(
                pick("tyretempdriverrear", "leftbacktyretemp", "leftbehindtyretemp")
            ),
            "tyreTempRearRight": as_float(
                pick("tyretemppassengerrear", "rightbacktyretemp", "rightbehindtyretemp")
            ),
            # 胎压告警：真实字段是分轮位的 `?TyrePressureAlert`（原 `tyreWarningStatus`
            # 为自造名）。这里把四轮告警归并成一个总标志，全为 null 时返回 None。
            # 胎压告警：官方**只有** 4 个轮的独立告警字段，没有汇总字段 ——
            # tyreWarningStatus / tyrePressureWarning / tyreWarning 在 v5.0.7 里
            # 全部 0 命中（都是自造名，已移除）。归并由 _any_tyre_alert 完成。
            # v1.0 实报的是 `tyrePreWarning{Driver,Passenger,DriverRear,PassengerRear}`（0/1）。
            "tyreWarning": _any_tyre_alert(
                as_bool(pick("tyreprewarningdriver", "leftfronttyrepressurealert")),
                as_bool(pick("tyreprewarningpassenger", "rightfronttyrepressurealert")),
                as_bool(
                    pick(
                        "tyreprewarningdriverrear",
                        "leftbacktyrepressurealert",
                        "leftbehindtyrepressurealert",
                    )
                ),
                as_bool(
                    pick(
                        "tyreprewarningpassengerrear",
                        "rightbacktyrepressurealert",
                        "rightbehindtyrepressurealert",
                    )
                ),
            ),
            "climateOn": as_bool(pick("preclimateactive", "climatestatuspreclimateactive")),
            # 空调目标温度的真名未在官方包中确认（`climateTargetTemperature` /
            # `acTemperatureSetting` 均 0 命中），保留猜测别名并标记未验证。
            "climateTargetTemp": as_float(pick("climatetargettemperature", "actemperaturesetting")),
            # 内温：v1.0 实报 `climateStatus.interiorTemp`（实测 25.5）。
            # 注意别写成 `interiorTemperature` —— 那是自造名，实报里没有。
            "interiorTemp": as_float(pick("climatestatusinteriortemp", "interiortemp", "teminterior")),
            # 外温：真名是 `climateStatus.exteriorTemp`（与 `interiorTemp` 同一层），
            # 实测字段存在但**当前上报为空字符串**。
            # 此前别名写成 `exteriorTemperature`（多了一截，0 命中）——
            # 即使哪天车开始给值也永远取不到，属于必须修的真缺陷。
            "exteriorTemp": as_float(
                pick("climatestatusexteriortemp", "exteriortemp", "temexterior")
            ),
            "latitude": lat,
            "longitude": lon,
            "positionTrusted": as_bool(pick("poscanbetrusted")),
            "speedKmh": as_float(pick("speed", "vehiclespeed")),
            # 能耗：官方字段为 `averPowerConsumption`（累计）/
            # `averTraPowerConsumption`（单程）/ `electricConsumption`。
            # 原 `averageEnergyConsumption` 是自造名（0 命中），导致能耗一直取不到。
            "avgConsumption": as_float(
                pick(
                    "averpowerconsumption",
                    "avertrapowerconsumption",
                    "electricconsumption",
                    "averageenergyconsumption",
                )
            ),
            # 保养里程真名未确认（maintainDistance / serviceDistance 均 0 命中）。
            "serviceDistanceKm": as_float(pick("maintaindistance", "servicedistance")),
            "serviceDays": None,
            # 优先用网关给的车辆上报时刻（毫秒）；拿不到才退回服务端当前时间。
            # 用服务端时间会让"最近更新"永远显示成"刚刚"，用户无从判断车况
            # 是不是几分钟前才上报的 —— 这正是这个字段存在的意义。
            "lastUpdateTs": (
                datetime.fromtimestamp(reported_ms / 1000).strftime("%Y-%m-%d %H:%M:%S")
                if (reported_ms := as_float(pick("updatetime"))) and reported_ms > 1e12
                else datetime.now().strftime("%Y-%m-%d %H:%M:%S")
            ),
        }

    async def get_trips(self, vin: str | None = None, days: int = 30) -> list[dict[str, Any]]:
        """获取行程记录。

        端点在官方 APK 中已确认存在（`ms-vehicle-trail`），此前"国区并无稳定端点"
        的判断是错的。仍保留失败回空列表的行为（前端展示空态），不做伪造。
        """
        target_vin = vin or self._session.get("active_vin") or ""
        if not target_vin:
            return []

        # 官方 APK 中已验证：行程走 `ms-vehicle-trail`（不是 `ms-lbs-service`）。
        # 该服务下另有 `journalLog/trackpoint/list` 可取轨迹点，可用于行程回放；
        # `ms-lbs-service` 实际只暴露了 `api/v2.0/sendToCar` 一条，与行程无关。
        path = "/ms-vehicle-trail/api/v1.0/journalLog/trip/listForPage"
        end = datetime.now()
        start = end - timedelta(days=days)

        # ⚠️ `startTime` / `endTime` 必须是**数字时间戳**（毫秒；秒也接受）。
        # 实测：传 `"2026-10-09 14:00:00"` 这类字符串一律被拒
        # `000002 The request parameter startTime type is incorrect` —— 此前正是
        # 这么发的，于是行程永远为空（且被 try/except 吞成静默失败）。
        # 请求体保持 `pageNum`、**不带 `lastId`**。
        #
        # 2026-10-19 拿真实会话把社区实现的写法（`currentPage` + `lastId: -1`）
        # 和自己这套都试了一遍，**全部 `total=0, data=null`**：
        #   · `currentPage` + `lastId`（-1 / 0 / 10^13 / 2^63-1 / 不传）
        #   · 原来这套 `pageNum` + 无 `lastId`
        #   · 连 10-16 当天窗口单独查，也是 0
        # ⇒ **参数不是原因**：网关接受请求，业务层就是没有数据。
        #
        # ⚠️ 别被 `trips` 表里那 60 条历史记录骗了 —— 那是 `mock_client` 生成的
        # 假数据（trip_id 形如 `20261016-0`、起点只有"家/公司"、终点固定 8 个地名），
        # 因为落库路径曾经没有拦 mock。**这个接口至今没有成功返回过真实行程。**
        # 官方 App 同样不展示按次行程（只给每月/每天电耗），所以这里返回空是常态。
        try:
            payload = await self._request_gw3(
                "POST",
                path,
                vin=target_vin,
                body={
                    "startTime": int(start.timestamp() * 1000),
                    "endTime": int(end.timestamp() * 1000),
                    "pageNum": 1,
                    "pageSize": 100,
                },
            )
        except (ZeekrAPIError, httpx.HTTPError) as exc:
            logger.warning("获取行程失败：%s", exc)
            return []

        # 分页信封实测形如 `{"current":1,"pageSize":50,"total":0,"pages":0,
        # "lastId":-1,"data":[...]}` —— 列表在 **`data`** 键下，不是 `list`。
        # 只看 `list` 的话，就算有行程也永远解析成空。
        data = payload.get("data") or payload
        items: Any = None
        if isinstance(data, dict):
            for key in ("list", "records", "data", "items"):
                candidate = data.get(key)
                if isinstance(candidate, list):
                    items = candidate
                    break
        elif isinstance(data, list):
            items = data
        if not isinstance(items, list):
            # 「查不到」与「请求失败」必须能区分开：两者都返回空列表，
            # 但前者是数据侧的问题（行车日志没开 / 车没跑过），后者是我们的 bug。
            # 只打一行计数，不含任何车辆数据。
            if isinstance(data, dict):
                logger.info(
                    "行程列表为空（网关 total=%s, pages=%s）—— 接口正常，是业务层没有数据",
                    data.get("total"),
                    data.get("pages"),
                )
            return []

        trips: list[dict[str, Any]] = []
        for raw in items:
            start_time = raw.get("startTime")
            end_time = raw.get("endTime")
            distance = raw.get("distance")
            trips.append({
                "tripId": build_trip_id(raw.get("id") or raw.get("journeyId"), start_time, end_time, distance),
                "startTime": start_time,
                "endTime": end_time,
                "distanceKm": distance,
                "energyKwh": raw.get("energy") or raw.get("consumeEnergy"),
                "avgSpeedKmh": raw.get("avgSpeed"),
                "maxSpeedKmh": raw.get("maxSpeed"),
                "consumption": raw.get("avgEnergyConsumption"),
                "startPlace": raw.get("startAddress") or raw.get("startName"),
                "endPlace": raw.get("endAddress") or raw.get("endName"),
                "durationMinutes": raw.get("duration"),
            })
        return trips

    async def get_daily_energy(
        self,
        vin: str | None = None,
        days: int = 30,
        scope: str = "window",
        year_month: str | None = None,
        start_ms: int | None = None,
        end_ms: int | None = None,
    ) -> dict[str, Any]:
        """官方「行程与能耗」日统计。

        端点 `POST /journey-statistics-service/api/v2.0/h5/getDailyStatisticsInfo`，
        就是官方 App「行程统计」页的数据源（同 host、同 GW3 签名，**不需要 H5 那套第三方签名**）。

        要点（都是实测踩出来的，别改）：
          - `start` / `end` 必须是**毫秒 Long**；传 `"2026-10-01"` 会 `52A02`；
          - 服务端限制**最多 31 个自然日**，超了报 `A008`。窗口按自然日算：
            `start` 取「今天-(N-1)天」的本地 00:00，`end` 取当前时刻 —— 直接用
            `now-31*86400s` 会因为多出当天已过的时分秒而变成 31.02 天，同样 `A008`；
          - 四组序列（里程/时长/动态电耗/静态电耗）**共用同一个 X 轴**，
            而且 X **只含有数据的日期**，不能按下标硬对齐到日历。
        """
        target_vin = vin or self._session.get("active_vin") or ""
        if not target_vin:
            vehicles = await self.list_vehicles()
            if not vehicles:
                raise ZeekrAPIError("no_vehicle", "账号下未找到车辆")
            target_vin = vehicles[0]["vin"]
            self._session["active_vin"] = target_vin

        now_ms = int(time.time() * 1000)
        current_month = time.strftime("%Y-%m", time.localtime(now_ms / 1000))

        if start_ms is not None and end_ms is not None:
            # 显式毫秒区间：增量同步要精确补「某一天」或「某一段」时走这条。
            # 上限仍受 ENERGY_MAX_DAYS 约束（超了服务端报 A008；这里先挡掉，
            # 让调用方拿到明确的错误码，而不是网关原文）。
            start_ms = int(start_ms)
            end_ms = int(end_ms)
            span = (end_ms - start_ms) // 86_400_000 + 1
            if span < 1 or span > ENERGY_MAX_DAYS:
                raise ZeekrAPIError(
                    "bad_window", f"start/end 需落在 1–{ENERGY_MAX_DAYS} 个自然日内"
                )
            days = int(span)
        elif (
            year_month
            and year_month not in ("currentMonth", "current")
            and year_month != current_month
        ):
            # 历史月份：日统计接口只允许回查 60 天（A010），改用月度报告接口。
            return await self.get_month_energy(year_month=year_month, vin=target_vin)
        elif year_month or scope == "month":
            # 「本月」= 当月 1 日 00:00 起 —— 官方 App 行程统计页用的就是这个区间，
            # 想和 App 的数字对上就必须用这个，而不是「近 N 天」。
            local = time.localtime(now_ms / 1000)
            start_ms = int(time.mktime((local.tm_year, local.tm_mon, 1, 0, 0, 0, 0, 0, -1)) * 1000)
            end_ms = now_ms
            # 按实际区间反算天数：本月可能是 28/30/31 天，传进来的 days 不作数
            days = max(1, min((end_ms - start_ms) // 86_400_000 + 1, ENERGY_MAX_DAYS))
        else:
            days = max(1, min(int(days), ENERGY_MAX_DAYS))
            start_ms = self._day_start_ms(now_ms) - (days - 1) * 86_400_000
            end_ms = now_ms

        payload = await self._request_gw3(
            "POST",
            ENERGY_DAILY_PATH,
            vin=target_vin,
            body={"vin": target_vin, "start": start_ms, "end": end_ms},
        )
        return self._normalize_daily_energy(payload.get("data") or {}, days)

    async def get_month_energy(self, year_month: str, vin: str | None = None) -> dict[str, Any]:
        """历史月份统计（月度报告接口）。

        日统计接口对 60 天以前的区间直接报 `A010`，所以历史月份必须走这条。
        返回字段与 `get_daily_energy` 对齐，前端不用区分来源。
        """
        target_vin = vin or self._session.get("active_vin") or ""
        if not target_vin:
            vehicles = await self.list_vehicles()
            if not vehicles:
                raise ZeekrAPIError("no_vehicle", "账号下未找到车辆")
            target_vin = vehicles[0]["vin"]
            self._session["active_vin"] = target_vin

        payload = await self._request_gw3(
            "POST", ENERGY_MONTHLY_PATH, vin=target_vin,
            body={"vin": target_vin, "yearMonth": year_month},
        )
        return self._normalize_month_energy(payload.get("data") or {}, year_month)

    @staticmethod
    def _normalize_month_energy(data: dict[str, Any], year_month: str) -> dict[str, Any]:
        """把月度报告整成与日统计一致的形状（汇总 + 逐日序列）。

        与日统计的区别：
          - 总里程字段叫 `mileage`（不是 `totalMileage`）；
          - 逐日 X 只有 `01`/`02` 这样的日号，要自己补上年月；
          - 逐日电量仍是 `dynamicEcY + staticEcY`（`ecy` 恒 0）。
        """

        def num(value: Any) -> float:
            try:
                return float(value)
            except (TypeError, ValueError):
                return 0.0

        year, month = (int(x) for x in year_month.split("-")[:2])
        xs = data.get("dailyMileageX") or []
        mileage_y = data.get("dailyMileageY") or []
        minutes_y = data.get("drivingTimeY") or []
        dynamic_y = data.get("dynamicEcY") or []
        static_y = data.get("staticEcY") or []

        def at(seq: list[Any], index: int) -> Any:
            return seq[index] if index < len(seq) else 0

        series: list[dict[str, Any]] = []
        for index, raw_day in enumerate(xs):
            day = str(raw_day).zfill(2)
            distance = num(at(mileage_y, index))
            dynamic = num(at(dynamic_y, index))
            static = num(at(static_y, index))
            energy = dynamic + static
            series.append({
                "date": f"{year:04d}-{month:02d}-{day}",
                "distanceKm": round(distance, 1),
                "energyKwh": round(energy, 2),
                "dynamicKwh": round(dynamic, 2),
                "staticKwh": round(static, 2),
                "minutes": int(num(at(minutes_y, index))),
                "consumption": round(energy / distance * 100, 1) if distance > 0 else None,
            })
        series.sort(key=lambda item: item["date"])

        distance_total = num(data.get("mileage"))
        energy_total = num(data.get("electricityConsumed"))
        return {
            "days": calendar.monthrange(year, month)[1],
            "startDate": f"{year}年{month:02d}月01日",
            "endDate": f"{year}年{month:02d}月{calendar.monthrange(year, month)[1]:02d}日",
            "distanceKm": round(distance_total, 1),
            "energyKwh": round(energy_total, 2),
            "dynamicEnergyKwh": round(num(data.get("dynamicEc")), 2),
            "staticEnergyKwh": (
                round(max(0.0, energy_total - num(data.get("dynamicEc"))), 2)
                if data.get("dynamicEc") is not None
                else None
            ),
            # 月报没有直接给「总口径」均耗，自己算，保证 总÷里程 与卡片一致
            "avgConsumption": round(energy_total / distance_total * 100, 1) if distance_total > 0 else 0.0,
            "avgDynamicConsumption": round(num(data.get("dynamicAvgEc")), 1),
            "fastChargeCount": int(num(data.get("fastChargeNum"))),
            "slowChargeCount": int(num(data.get("normalChargeNum"))),
            "series": series,
        }

    async def get_energy_months(self, vin: str | None = None) -> dict[str, Any]:
        """可选月份清单 + 车辆总里程。

        官方 `mileageBaseInfo.existingMonth` 就是 App 里月份选择器的数据源：
        第一项固定 `yearMonth: "currentMonth"`（本月），其余按月份倒序。
        """
        target_vin = vin or self._session.get("active_vin") or ""
        if not target_vin:
            vehicles = await self.list_vehicles()
            if not vehicles:
                raise ZeekrAPIError("no_vehicle", "账号下未找到车辆")
            target_vin = vehicles[0]["vin"]
            self._session["active_vin"] = target_vin

        payload = await self._request_gw3(
            "POST", ENERGY_MONTHS_PATH, vin=target_vin, body={"vin": target_vin}
        )
        data = payload.get("data") or {}

        months: list[dict[str, str]] = []
        for item in data.get("existingMonth") or []:
            if not isinstance(item, dict):
                continue
            key = item.get("yearMonth")
            if not key:
                continue
            months.append({"yearMonth": str(key), "label": str(item.get("label") or key)})

        return {
            "months": months,
            "monthMileageKm": round(self._to_float(data.get("monthTotalMileage")), 1),
            "monthEnergyKwh": round(self._to_float(data.get("monthElectricityConsumed")), 2),
        }

    @staticmethod
    def _to_float(value: Any) -> float:
        try:
            return float(value)
        except (TypeError, ValueError):
            return 0.0

    @staticmethod
    def _day_start_ms(ts_ms: int) -> int:
        """毫秒时间戳 → 当天 00:00（本地时区）的毫秒时间戳。"""
        lt = time.localtime(ts_ms / 1000)
        return int(time.mktime((lt.tm_year, lt.tm_mon, lt.tm_mday, 0, 0, 0, 0, 0, -1)) * 1000)

    @staticmethod
    def _normalize_daily_energy(data: dict[str, Any], days: int) -> dict[str, Any]:
        """把官方日统计整理成「汇总 + 逐日序列」。

        口径（用真车数据验算过）：界面上的「总电耗」= 动态 + 静态，
        所以逐日电量取 `dynamicEcY[i] + staticEcY[i]`，**不是** `ecy`（那个恒 0）。
        """

        def num(value: Any) -> float:
            try:
                return float(value)
            except (TypeError, ValueError):
                return 0.0

        xs = data.get("dailyMileageX") or data.get("ecx") or []
        mileage_y = data.get("dailyMileageY") or []
        minutes_y = data.get("drivingTimeY") or []
        dynamic_y = data.get("dynamicEcY") or []
        static_y = data.get("staticEcY") or []

        def at(seq: list[Any], index: int) -> Any:
            return seq[index] if index < len(seq) else 0

        series: list[dict[str, Any]] = []
        for index, raw_date in enumerate(xs):
            distance = num(at(mileage_y, index))
            dynamic = num(at(dynamic_y, index))
            static = num(at(static_y, index))
            energy = dynamic + static
            series.append({
                # 服务端给的是 `2026/10/06`，统一成 `2026-10-06`，前端好排序与切片
                "date": str(raw_date).replace("/", "-"),
                "distanceKm": round(distance, 1),
                "energyKwh": round(energy, 2),
                # 拆分给前端画堆叠柱：dynamicKwh + staticKwh == energyKwh
                "dynamicKwh": round(dynamic, 2),
                "staticKwh": round(static, 2),
                "minutes": int(num(at(minutes_y, index))),
                "consumption": round(energy / distance * 100, 1) if distance > 0 else None,
            })
        series.sort(key=lambda item: item["date"])

        return {
            "days": days,
            "startDate": data.get("startDate"),
            "endDate": data.get("endDate"),
            "distanceKm": round(num(data.get("totalMileage")), 1),
            "energyKwh": round(num(data.get("electricityConsumed")), 2),
            "dynamicEnergyKwh": round(num(data.get("dynamicEc")), 2),
            # 静态 = 总 - 动态；缺 dynamicEc 就算不出来，给 None（前端显示「--」）
            "staticEnergyKwh": (
                round(
                    max(0.0, num(data.get("electricityConsumed")) - num(data.get("dynamicEc"))),
                    2,
                )
                if data.get("dynamicEc") is not None and data.get("electricityConsumed") is not None
                else None
            ),
            # 官方两个口径：avgEc 含静态耗电，avgDynamicEc 只算行驶中（App 展示的是后者）
            "avgConsumption": round(num(data.get("avgEc")), 1),
            "avgDynamicConsumption": round(num(data.get("dynamicAvgEc")), 1),
            "fastChargeCount": int(num(data.get("fastChargeNum"))),
            "slowChargeCount": int(num(data.get("normalChargeNum"))),
            "series": series,
        }

    async def get_energy_trend(self, vin: str | None = None, days: int = 30) -> list[dict[str, Any]]:
        """获取逐日能耗趋势。

        数据源是官方 `getDailyStatisticsInfo`（见 `get_daily_energy`）。
        历史上这里拿行程明细聚合，而行程明细服务端恒为空 ⇒ 永远返回空列表；
        现在改走官方统计，字段保持原样（`date`/`distanceKm`/`energyKwh`/`consumption`）以免破坏调用方。
        """
        stats = await self.get_daily_energy(vin=vin, days=days)
        return [
            {
                "date": item["date"],
                "distanceKm": item["distanceKm"],
                "energyKwh": item["energyKwh"],
                "consumption": item["consumption"],
                "tripCount": 0,
            }
            for item in stats["series"]
        ]

    # MARK: - 充电流水

    async def get_charge_sessions(self, vin: str | None = None) -> list[dict[str, Any]]:
        """拉取官方「充电记录」（按年 → 月分组，一次给约两年）。

        这就是 App「充电记录」页的数据源，也是**唯一**能自动拿到"充了多少度"的接口。

        上游只有电量/时长/交直流，没有金额、单价、站点名：
          · 车端不知道电价 ⇒ 金额只能来自支付侧（截图 OCR / 手工）；
          · 站点名不在这条链路上 ⇒ 只能由 OCR 的商户名反填。
        所以这里**只归一化能量相关字段**，不要试图编造金额。

        Returns:
            [{"sessionId", "source", "startTime", "endTime", "durationMin",
              "energyKwh", "chargeType", "chargeTypeName"}]
        """
        target_vin = vin or self._session.get("active_vin") or ""
        if not target_vin:
            vehicles = await self.list_vehicles()
            if not vehicles:
                raise ZeekrAPIError("no_vehicle", "账号下未找到车辆")
            target_vin = vehicles[0]["vin"]
            self._session["active_vin"] = target_vin

        payload = await self._request_gw3(
            "POST",
            CHARGE_LOG_PATH,
            vin=target_vin,
            body={"startTimeStart": None, "chargeType": ""},
            extra_headers={"X-TENANT-ID": "ZEEKR", "X-VEHICLE-BRAND": "ZEEKR"},
        )
        return self._normalize_charge_sessions(payload.get("data"))

    @staticmethod
    def _normalize_charge_sessions(raw: Any) -> list[dict[str, Any]]:
        """把「年 → 月 → 记录」三层结构摊平成一条条流水。

        幂等键用 `eventId`（回退 `id`）：实测同一笔充电的 `eventId` 稳定，
        而 `id` 是订单号形态的字符串，两者都在就用 `eventId`。
        时间戳是**毫秒**，落库前转成本地 `YYYY-MM-DD HH:MM:SS`。
        """
        if not isinstance(raw, list):
            return []

        out: list[dict[str, Any]] = []
        for year_group in raw:
            if not isinstance(year_group, dict):
                continue
            for month in year_group.get("monthList") or []:
                if not isinstance(month, dict):
                    continue
                for rec in month.get("records") or []:
                    if not isinstance(rec, dict):
                        continue

                    start_ms = rec.get("startTime")
                    if not isinstance(start_ms, (int, float)) or start_ms <= 0:
                        continue
                    end_ms = rec.get("endTime")
                    duration = rec.get("chargedTime")
                    if not isinstance(duration, (int, float)):
                        # 上游偶尔只给起止时间，用时间差补时长（分钟）
                        duration = (
                            (float(end_ms) - float(start_ms)) / 60000
                            if isinstance(end_ms, (int, float)) and end_ms > start_ms
                            else None
                        )

                    name = str(rec.get("chargeTypeName") or "")
                    if "直流" in name:
                        charge_type = "dc"
                    elif "交流" in name:
                        charge_type = "ac"
                    else:
                        charge_type = "unknown"

                    external_id = rec.get("eventId") or rec.get("id")
                    if external_id is None:
                        continue

                    power = rec.get("power")
                    out.append(
                        {
                            "sessionId": f"zeekr:{external_id}",
                            "source": "zeekr",
                            "startTime": datetime.fromtimestamp(float(start_ms) / 1000).strftime(
                                "%Y-%m-%d %H:%M:%S"
                            ),
                            "endTime": (
                                datetime.fromtimestamp(float(end_ms) / 1000).strftime(
                                    "%Y-%m-%d %H:%M:%S"
                                )
                                if isinstance(end_ms, (int, float)) and end_ms > 0
                                else None
                            ),
                            "durationMin": (
                                round(float(duration), 1)
                                if isinstance(duration, (int, float))
                                else None
                            ),
                            "energyKwh": (
                                round(float(power), 2)
                                if isinstance(power, (int, float))
                                else None
                            ),
                            "chargeType": charge_type,
                            "chargeTypeName": name or None,
                        }
                    )

        # 上游分组顺序不稳定，这里统一按开始时间倒序，落库/展示都不再依赖它
        out.sort(key=lambda item: item["startTime"], reverse=True)
        return out

    # MARK: - 车控

    async def send_command(
        self,
        command: str,
        params: dict[str, Any] | None = None,
        vin: str | None = None,
    ) -> dict[str, Any]:
        """下发车控指令。"""
        if command not in COMMAND_MAP:
            return {"success": False, "message": f"不支持的指令：{command}", "command": command}

        # 可信度闸门：serviceId 基于猜测的指令一律拒绝。
        #
        # 这些指令的 serviceId 是按拼音首字母拼的（如 ZDF/ZWH），未经真车
        # 验证。放行后果不对称：指令静默无效时用户以为「锁了车其实没锁」，
        # 本身即安全问题；更坏的情况是触发未知车端动作。
        # 详见 `zeekr_signing.py` 顶部「车控指令可信度分级」。
        if not is_verified_command(command):
            return {
                "success": False,
                "message": f"指令 {command} 未经真车验证，live 模式拒绝下发",
                "command": command,
                "reason": "unverified_command",
            }

        target_vin = vin or self._session.get("active_vin") or ""
        if not target_vin:
            vehicles = await self.list_vehicles()
            if not vehicles:
                return {"success": False, "message": "未找到车辆", "command": command}
            target_vin = vehicles[0]["vin"]
            self._session["active_vin"] = target_vin

        service_id, key, value = COMMAND_MAP[command]

        # 允许临时覆盖参数（如空调温度）
        if params:
            if "key" in params:
                key = str(params["key"])
            if "value" in params:
                value = str(params["value"])

        body = build_control_body(service_id, key, value)
        # 官方路径带 `/api` 段：`/ms-remote-control/api/v1.0/remoteControl/control`
        # （原实现漏了 `/api`，该串在官方 APK 中 0 命中）。
        path = "/ms-remote-control/api/v1.0/remoteControl/control"

        # 优先 GW3 通道。
        #
        # 注意：`_request_gw3` 内部已调用 `_unwrap`，失败信封会直接抛
        # `ZeekrAPIError`。因此「未抛异常」即代表网关接受了请求，
        # 无法也不应再去读 payload 里的 `code`（那里已不含该字段）。
        try:
            payload = await self._request_gw3("POST", path, vin=target_vin, body=body)
            return {
                "success": True,
                # 措辞保持克制：网关收下 ≠ 车端已执行
                "message": "指令已提交至车辆",
                "command": command,
                # 查车端执行结果要用它。字段名未在真车确认，故按常见命名
                # 逐个尝试；取不到就给空串 —— 前端拿到空 id 会直接判"未确认"，
                # 而不是谎报成功。
                "commandId": _extract_command_id(payload),
            }
        except (ZeekrAPIError, httpx.HTTPError) as exc:
            logger.warning("GW3 指令通道失败，回退 GW2：%s", exc)

        # 回退 GW2 telematics 通道
        fallback_path = f"/remote-control/vehicle/telematics/{target_vin}"
        try:
            await self._request_gw2("PUT", fallback_path, body={
                "command": "start",
                "serviceId": service_id,
                "setting": {"serviceParameters": [{"key": key, "value": value}]},
            })
            return {
                "success": True,
                "message": "指令已提交至车辆（GW2 通道）",
                "command": command,
            }
        except ZeekrAPIError as exc:
            return {
                "success": False,
                "message": f"指令被网关拒绝：{exc.message}",
                "command": command,
            }
        except httpx.HTTPError as exc:
            logger.error("GW2 指令通道异常：%s", exc)
            return {
                "success": False,
                "message": "指令下发失败，请检查网络与服务端日志",
                "command": command,
            }

    async def get_command_result(
        self,
        command_id: str,
        vin: str | None = None,
    ) -> dict[str, Any]:
        """查询车控指令的车端执行结果。

        对应官方接口（官方 APK 中已验证）：
            /ms-remote-control/api/v1.0/remoteControl/queryProcessResult

        ⚠️ 响应体结构未在真车确认 —— 加壳的 APK 里取不到 DTO。故这里对
        状态字段做**多候选 + 多形态**解析（布尔 / 字符串 / 数字），
        解析不出来时一律返回 `pending`，**绝不返回 done**
        —— 猜错的代价是不对称的：把"没执行完"说成"已执行"，
        用户会以为车锁好了。
        """
        if not command_id:
            return {"status": "pending", "message": "缺少指令凭据，无法确认车端执行结果"}

        target_vin = vin or self._session.get("active_vin") or ""
        path = "/ms-remote-control/api/v1.0/remoteControl/queryProcessResult"

        try:
            payload = await self._request_gw3(
                "POST", path, vin=target_vin, body={"processId": command_id}
            )
        except (ZeekrAPIError, httpx.HTTPError) as exc:
            logger.warning("查询指令执行结果失败：%s", exc)
            return {"status": "pending", "message": "查询执行结果失败，暂无法确认"}

        return {
            "status": _map_command_status(payload),
            "message": "已查询车端执行结果",
            "raw": payload,
        }

    async def get_capabilities(self, vin: str | None = None) -> dict[str, Any]:
        """车辆权限包 + 预约充电计划。

        官方接口（2026-10-16 真车实测确认）：

            GET /ms-app-bff/api/1.0/permissions?tspPlatform=<平台号>
                **必须带 X-VIN** —— 缺了返回 `079001`；
                `vin` 查询参数可有可无（服务端按 X-VIN 认车）。
                响应 `data` 是权限包 ID 字符串数组。

            GET /ms-charge-manage/api/v1.0/charge/getChargingPlanNew

        历史：APK 里另有 `/ms-vehicle-capability-set/api/app/v1/vehicle/
        capability/available`，但该服务在 snc-tsp-api 上**网关级 404**
        （`00A01` / `bizName: API Gateway`；网关、版本号、GET/POST、多个
        host 全试过），即路由未注册。已被 permissions 取代，不再调用 ——
        留着只会每次白跑一次请求并往日志里灌一行 warning。
        """
        target_vin = vin or self._session.get("active_vin") or ""
        if not target_vin:
            # 权限集**必须带 X-VIN**（缺了直接 079001）。会话里还没有就先去
            # 取一次车辆列表 —— 用户可能一进应用就打开设置页，
            # 不能假设他先看过车况页。
            vehicles = await self.list_vehicles()
            if vehicles:
                target_vin = self._session.get("active_vin") or vehicles[0].get("vin") or ""

        permissions: list[str] | None = None
        try:
            raw = await self._request_gw3(
                "GET",
                "/ms-app-bff/api/1.0/permissions",
                vin=target_vin,
                query={"tspPlatform": self.cfg.tsp_platform},
            )
            permissions = _extract_permissions(raw)
        except (ZeekrAPIError, httpx.HTTPError) as exc:
            logger.warning("获取车辆权限包失败：%s", exc)

        capabilities = _map_permissions(permissions)

        charge_plan: dict[str, Any] | None = None
        try:
            plan_raw = await self._request_gw3(
                "GET",
                "/ms-charge-manage/api/v1.0/charge/getChargingPlanNew",
                vin=target_vin,
            )
            charge_plan = _map_charge_plan(plan_raw)
        except (ZeekrAPIError, httpx.HTTPError) as exc:
            logger.warning("获取预约充电计划失败：%s", exc)

        return {
            "capabilities": capabilities,
            # 原始权限包 ID 一并返回：设置页需要如实展示"这台车开通了什么"，
            # 也让"某个按钮为什么不见了"变得可解释（否则用户以为功能丢了）。
            "permissions": permissions,
            "chargePlan": charge_plan,
            # 取到权限清单即为已验证（响应结构已真车确认）；取不到时才为 False。
            "verified": permissions is not None,
        }

    # MARK: - 附近充电站

    async def get_nearby_stations(
        self,
        lat: float,
        lng: float,
        zoom: int = 13,
    ) -> list[dict[str, Any]]:
        """附近充电站列表（坐标 + 枪数 + 运营商 logo，**无站名、无价格**）。

        官方接口（2026-10-16 实测返回 680 条真实站点）：

            POST /zeekrlife-bbs-theme/v1/discovery/pub/bubble/charge/getListV2

        走 GW1，复用登录后的 JWT 与 `x_ca_*` 签名；**不需要 X-VIN**
        （车况类接口要，这个纯公共 POI 不要）。

        三个反直觉点（都踩过，别再试）：
          - **必须 POST**：同路径用 GET 一律返回 `200 + 999999 服务异常`，
            极易被误读成"服务挂了"；
          - 7 个地理参数**全部必填**，少一个回 `000005` + 中文校验消息；
          - 路径**没有** `/toc/` 段 —— bbs-theme 下别的路径有，这族加了反而真 404。

        站名与电价都不在这里，需要按 `stationId` 另问浩汉网关
        （见 `adapters/haohan.py`）。两边 `stationId` 是**同一套**，无需映射。
        """
        token = self._session.get("gw1_jwt") or ""
        if not token:
            raise ZeekrAPIError("no_session", "未登录，无法获取附近充电站")

        # 视野右上角为必填项；给约 ±0.05°（≈5km）的框，与 mapZoomRatio=13 量级相称
        body = {
            "centerLat": lat,
            "centerLng": lng,
            "mapZoomRatio": zoom,
            "currentLat": lat,
            "currentLng": lng,
            "upperRightCornerLat": lat + 0.05,
            "upperRightCornerLng": lng + 0.05,
        }
        headers = build_gw1_headers(device_id=self._device_id(), authorization=token)

        try:
            resp = await self._http.post(
                f"{GW1_HOST}/zeekrlife-bbs-theme/v1/discovery/pub/bubble/charge/getListV2",
                json=body,
                headers=headers,
            )
            payload = resp.json()
        except (httpx.HTTPError, json.JSONDecodeError) as exc:
            raise ZeekrAPIError("network", f"获取附近充电站失败：{exc}") from exc

        if not self._is_gw1_success(payload):
            raise ZeekrAPIError(
                str(payload.get("code", "")),
                payload.get("message") or payload.get("msg") or "获取附近充电站失败",
                payload,
            )

        raw = payload.get("data")
        # 实测 `data` **直接就是站点数组**，不是分页信封（别去找 records）
        if not isinstance(raw, list):
            return []

        stations: list[dict[str, Any]] = []
        for item in raw:
            if not isinstance(item, dict):
                continue
            mapped = _map_station(item)
            if mapped["stationId"]:
                stations.append(mapped)
        return stations

    async def aclose(self) -> None:
        """释放底层连接。"""
        await self._http.aclose()
