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
import json
import logging
import re
from datetime import datetime, timedelta
from hashlib import md5
from typing import Any

import httpx

from ..core.config import ZeekrConfig
from .base import ZeekrClient
from .zeekr_signing import (
    COMMAND_MAP,
    GW1_HOST,
    GW2_HOST,
    GW3_HOST,
    build_control_body,
    build_gw3_headers,
    build_login_device_id,
    compact_json,
    encrypt_vin,
    is_verified_command,
    sign_gw1,
    sign_gw2,
)

logger = logging.getLogger(__name__)

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
    """把能力集报文映射成「功能 → 是否支持」。

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

    async def send_sms_code(self, phone: str) -> dict[str, Any]:
        """请求短信验证码（GW1）。"""
        # 官方 App 的登录入口只有 `/zeekrlife-app-user/v1/user/pub/login/mobile`
        # 一条（同族另有 `/bind`、`/oneClick`、`/platform`），
        # **不存在 `/sendCode` 后缀** —— 该串在官方 APK 中 0 命中。
        # 发码与校验共用这一条路径，靠 body 是否携带 `code` 区分阶段：
        # 不带 code = 请求下发验证码；带 code = 校验登录（见 `_login_gw1`）。
        path = "/zeekrlife-app-user/v1/user/pub/login/mobile"
        params = {"mobile": phone, "areaCode": "86"}
        headers = sign_gw1(params)

        try:
            resp = await self._http.post(
                f"{GW1_HOST}{path}", json=params, headers=headers
            )
            payload = resp.json()
        except (httpx.HTTPError, json.JSONDecodeError) as exc:
            logger.error("请求验证码失败：%s", exc)
            return {"success": False, "message": f"网络请求失败：{exc}"}

        if payload.get("success") or payload.get("code") in ("0", "000000", 0, None):
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

        # 第二级：GW2 换取 ecar accessToken
        try:
            await self._login_gw2()
        except ZeekrAPIError as exc:
            logger.warning("GW2 登录失败（将仅用 GW1 能力）：%s", exc)
            self._session["gw2_token"] = ""

        # 第三级：GW3 登录（失败不阻断，读取会回退 GW2）
        try:
            await self._login_gw3()
        except ZeekrAPIError as exc:
            logger.warning("GW3 登录失败（将回退 GW2）：%s", exc)
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

        与 `send_sms_code` 是同一条路径，区别只在 body 里**带 code**。
        """
        path = "/zeekrlife-app-user/v1/user/pub/login/mobile"
        params = {"mobile": phone, "areaCode": "86", "code": code}
        headers = sign_gw1(params)

        resp = await self._http.post(f"{GW1_HOST}{path}", json=params, headers=headers)
        payload = self._unwrap(resp.json())

        token = (
            payload.get("jwtToken")
            or payload.get("token")
            or (payload.get("data") or {}).get("jwtToken")
        )
        if not token:
            raise ZeekrAPIError(
                str(payload.get("code", "unknown")),
                payload.get("msg") or "登录失败：未返回令牌",
                payload,
            )

        self._session["gw1_jwt"] = token

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

    async def _login_gw3(self) -> None:
        """GW3 登录（HMAC-SHA256 签名 + 加密 VIN）。

        路径候选说明同 `_login_gw2`：新版把 `/api` 段补上，并把官方包中
        已验证的 `/app/login/v1/getTokenByCode` 放在首选。
        """
        candidates = (
            "/app/login/v1/getTokenByCode",
        )

        body = compact_json({
            "loginDeviceId": build_login_device_id(),
            # 跟随官方 APK 实测版本（本次审计样本 com.zeekrlife.mobile v5.0.7 / 221）
            "appVersion": APP_VERSION,
            "refreshToken": self._session.get("gw2_refresh", ""),
        })

        last_error: ZeekrAPIError | None = None

        for path in candidates:
            # GW3 登录不带 Authorization，但带 X-VIN
            headers = build_gw3_headers(
                prod_secret=self.cfg.prod_secret,
                method="POST",
                path=path,
                body=body,
            )

            try:
                resp = await self._http.post(
                    f"{GW3_HOST}{path}", content=body.encode("utf-8"), headers=headers
                )
                payload = self._unwrap(resp.json())
            except (ZeekrAPIError, httpx.HTTPError, json.JSONDecodeError) as exc:
                logger.warning("GW3 登录尝试失败（%s）：%s", path, exc)
                last_error = exc if isinstance(exc, ZeekrAPIError) else None
                continue

            token = (
                (payload.get("data") or {}).get("accessToken")
                or payload.get("accessToken")
            )
            if token:
                self._session["gw3_token"] = token.replace("Bearer ", "")
                logger.info("GW3 登录成功：%s", path)
                return

            last_error = ZeekrAPIError(
                str(payload.get("code", "unknown")),
                payload.get("msg") or "GW3 登录失败",
                payload,
            )
            logger.warning("GW3 登录未返回令牌（%s）：%s", path, last_error.message)

        raise last_error or ZeekrAuthError("GW3 登录全部候选失败")

        # 同上：GW3 重登（079021 自愈）换出来的新令牌也要落盘，
        # 否则重启后又回到那份旧令牌。
        self._save_session()

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

    def _encrypted_vin(self, vin: str) -> str:
        """优先使用抓包得到的 X-VIN 令牌，否则本地加密。"""
        if self.cfg.vehicle_token:
            return self.cfg.vehicle_token
        return encrypt_vin(vin, self.cfg.vin_key, self.cfg.vin_iv)

    async def _request_gw3(
        self,
        method: str,
        path: str,
        vin: str,
        body: dict[str, Any] | None = None,
        query: dict[str, str] | None = None,
        retry_on_session_conflict: bool = True,
    ) -> dict[str, Any]:
        """发起 GW3 请求，自动处理签名与令牌问题。"""
        self._assert_query_signable(query)
        body_str = compact_json(body) if body is not None else None

        headers = build_gw3_headers(
            prod_secret=self.cfg.prod_secret,
            method=method,
            path=path,
            query=query,
            body=body_str,
            authorization=f"Bearer {self._session.get('gw3_token', '')}",
            encrypted_vin=self._encrypted_vin(vin),
        )

        kwargs: dict[str, Any] = {"headers": headers}
        if body_str is not None:
            kwargs["content"] = body_str.encode("utf-8")
        if query:
            kwargs["params"] = query

        resp = await self._http.request(method, f"{GW3_HOST}{path}", **kwargs)
        payload = resp.json()
        code = str(payload.get("code", "0"))

        # 签名失败：常量 ERR_SIGNATURE 此前**定义了却从未被引用**，这条错误会被
        # _unwrap 静默放过，最终表现为误导性的「未找到车辆」。单独打一条可操作
        # 的 ERROR —— 079025 几乎总是签名串构造问题，直接指向该查哪里。
        if code == ERR_SIGNATURE:
            logger.error(
                "GW3 签名校验失败（%s）：请核对 GW3_SIGNED_HEADERS 白名单、"
                "待签名串的换行规则，以及参与签名的 body 是否与实发字节完全一致",
                ERR_SIGNATURE,
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
        """获取车辆列表（该接口不需要 X-VIN，通常最稳）。"""
        # 车辆列表。
        #
        # 原路径 `/zeekrlife-app-vehicle/v1/vehicle/list` 在官方 APK 中 **0 命中**
        # —— `zeekrlife-app-vehicle` 这个服务前缀根本不存在（官方只有
        # `zeekrlife-app-user`、`zeekrlife-mp-*` 等）。官方把车辆相关接口拆到了
        # ms-vehicle-core / ms-vehicle-account / ms-tsp-user-vehicle 等微服务下。
        #
        # ⚠️ 未定项：官方包里没有明文的"我的车辆列表"端点 —— 该步骤在官方 App
        #    里走 `com.geely.snc.basevehicle` SDK（GRIC 网关），路径可能由 native
        #    层构造，静态分析取不到。故按置信度顺序尝试，任一返回车辆即采用。
        candidates = (
            "/ms-vehicle-core/api/v1.0/vehicle/favorite-vehicles",
            "/ms-vehicle-account/api/v1.0/vehicle-detail",
            "/zeekrlife-app-vehicle/v1/vehicle/list",   # 旧路径，兜底
        )

        for path in candidates:
            for source in ("gw3", "gw2"):
                try:
                    if source == "gw3":
                        payload = await self._request_gw3(
                            "POST", path, vin="", body={"pageNum": 1, "pageSize": 20}
                        )
                    else:
                        payload = await self._request_gw2(
                            "POST", path, body={"pageNum": 1, "pageSize": 20}
                        )
                except (ZeekrAPIError, httpx.HTTPError) as exc:
                    logger.warning(
                        "%s 获取车辆列表失败（%s）：%s", source.upper(), path, exc
                    )
                    continue

                vehicles = self._extract_vehicle_list(payload)
                if vehicles:
                    logger.info("车辆列表成功：%s via %s", path, source.upper())
                    self._session["last_vehicle_list_source"] = source
                    self._session["last_vehicle_list_path"] = path
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
            series = entry.get("seriesCodeVs") or ""
            model = entry.get("modelName") or ""
            # 去掉 "-001" 这类目录编号
            if "-" in model:
                model = model.split("-")[0]

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

        # 官方 APK 中已验证的路径为 `/ms-vehicle-status/api/v2.0/vehicle/status/latest`
        # —— 注意两点：服务名是 `ms-vehicle-status`（不是 `zeekrlife-app-vehicle`），
        # 且主车况接口是 **v2.0**（v1.0 只有 vtm/qrvs/carFridge/powerMode 等子集）。
        path = "/ms-vehicle-status/api/v2.0/vehicle/status/latest"
        query = {"latest": "false", "target": "new"}

        # 优先 GW3（字段最全），失败回退 GW2
        for source in ("gw3", "gw2"):
            try:
                if source == "gw3":
                    payload = await self._request_gw3(
                        "GET", path, vin=target_vin, query=query
                    )
                else:
                    payload = await self._request_gw2("GET", path, query=query)
            except (ZeekrAPIError, httpx.HTTPError) as exc:
                logger.warning("%s 获取状态失败：%s", source.upper(), exc)
                continue

            status = self._normalize_status(payload, target_vin)
            if status.get("soc") is not None:
                self._session["last_status_source"] = source
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
        lat_raw = as_float(pick("latitude", "poslat"))
        lon_raw = as_float(pick("longitude", "poslon"))
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
            "isPlugged": as_bool(pick("statusofchargerconnection")),
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
            "doors": {
                "frontLeft": as_bool(pick("leftfrontdoorstatus", "doorstatusfrontleft")),
                "frontRight": as_bool(pick("rightfrontdoorstatus", "doorstatusfrontright")),
                "rearLeft": as_bool(pick("leftbackdoorstatus", "leftbehinddoorstatus")),
                "rearRight": as_bool(pick("rightbackdoorstatus", "rightbehinddoorstatus")),
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
            "windows": _all_or_none(
                driver=as_bool(pick("leftfrontwindowstatus")),
                passenger=as_bool(pick("rightfrontwindowstatus")),
                rearLeft=as_bool(pick("leftbackwindowstatus", "leftbehindwindowstatus")),
                rearRight=as_bool(pick("rightbackwindowstatus", "rightbehindwindowstatus")),
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
            # 前备箱：真实字段是 `frunkOpenStatus`（getter `getFrunkOpenStatus`）；
            # `frunkStatus` / `frontTrunkStatus` 均为自造名（0 命中）。
            "frunkOpen": as_bool(pick("frunkopenstatus", "frunkstatus", "fronttrunkstatus")),
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
            # 四轮胎温（官方有 `leftFrontTyreTemp` 等）
            "tyreTempFrontLeft": as_float(pick("leftfronttyretemp")),
            "tyreTempFrontRight": as_float(pick("rightfronttyretemp")),
            "tyreTempRearLeft": as_float(pick("leftbacktyretemp", "leftbehindtyretemp")),
            "tyreTempRearRight": as_float(pick("rightbacktyretemp", "rightbehindtyretemp")),
            # 胎压告警：真实字段是分轮位的 `?TyrePressureAlert`（原 `tyreWarningStatus`
            # 为自造名）。这里把四轮告警归并成一个总标志，全为 null 时返回 None。
            # 胎压告警：官方**只有** 4 个轮的独立告警字段，没有汇总字段 ——
            # tyreWarningStatus / tyrePressureWarning / tyreWarning 在 v5.0.7 里
            # 全部 0 命中（都是自造名，已移除）。归并由 _any_tyre_alert 完成。
            "tyreWarning": _any_tyre_alert(
                as_bool(pick("leftfronttyrepressurealert")),
                as_bool(pick("rightfronttyrepressurealert")),
                as_bool(pick("leftbacktyrepressurealert", "leftbehindtyrepressurealert")),
                as_bool(pick("rightbacktyrepressurealert", "rightbehindtyrepressurealert")),
            ),
            "climateOn": as_bool(pick("preclimateactive", "climatestatuspreclimateactive")),
            # 空调目标温度的真名未在官方包中确认（`climateTargetTemperature` /
            # `acTemperatureSetting` 均 0 命中），保留猜测别名并标记未验证。
            "climateTargetTemp": as_float(pick("climatetargettemperature", "actemperaturesetting")),
            # 内温：官方有 `InteriorTemperature`，与已验证的 `temInterior` 一并尝试。
            "interiorTemp": as_float(pick("interiortemperature", "teminterior")),
            # 外温真名未确认（exteriorTemperature / temExterior / temOutdoor 均 0 命中）。
            "exteriorTemp": as_float(pick("exteriortemperature", "temexterior", "temoutdoor")),
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
            "lastUpdateTs": datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
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

        try:
            payload = await self._request_gw3(
                "POST",
                path,
                vin=target_vin,
                body={
                    "startTime": start.strftime("%Y-%m-%d %H:%M:%S"),
                    "endTime": end.strftime("%Y-%m-%d %H:%M:%S"),
                    "pageNum": 1,
                    "pageSize": 100,
                },
            )
        except (ZeekrAPIError, httpx.HTTPError) as exc:
            logger.warning("获取行程失败：%s", exc)
            return []

        data = payload.get("data") or payload
        items = data.get("list") if isinstance(data, dict) else data
        if not isinstance(items, list):
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

    async def get_energy_trend(self, vin: str | None = None, days: int = 30) -> list[dict[str, Any]]:
        """获取能耗趋势。

        由行程数据按日聚合得到 —— 极氪未提供独立的能耗趋势接口。
        """
        trips = await self.get_trips(vin=vin, days=days)
        if not trips:
            return []

        buckets: dict[str, dict[str, Any]] = {}
        for trip in trips:
            start = trip.get("startTime")
            if not start:
                continue
            day = str(start)[:10]
            bucket = buckets.setdefault(day, {
                "date": day,
                "distanceKm": 0.0,
                "energyKwh": 0.0,
                "consumption": None,
                "tripCount": 0,
            })
            bucket["distanceKm"] += float(trip.get("distanceKm") or 0)
            bucket["energyKwh"] += float(trip.get("energyKwh") or 0)
            bucket["tripCount"] += 1

        for bucket in buckets.values():
            distance = bucket["distanceKm"]
            if distance > 0:
                bucket["consumption"] = round(bucket["energyKwh"] / distance * 100, 1)
            bucket["distanceKm"] = round(bucket["distanceKm"], 1)
            bucket["energyKwh"] = round(bucket["energyKwh"], 2)

        return sorted(buckets.values(), key=lambda x: x["date"])

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
        """车辆能力集 + 预约充电计划。

        官方接口（均已在 APK 中验证存在）：
            /ms-vehicle-capability-set/api/app/v1/vehicle/capability/available
            /ms-charge-manage/api/v1.0/charge/getChargingPlanNew

        ⚠️ 两个接口的**响应体结构未在真车确认**（APK 加壳，取不到 DTO），
        故这里只做"尽力而为"的归一化，并返回 `verified=False`
        明确告知调用方这不是权威结论。首次真车联通时应以原始报文为准修正映射。
        """
        target_vin = vin or self._session.get("active_vin") or ""

        capabilities: dict[str, bool] | None = None
        try:
            raw = await self._request_gw3(
                "GET",
                "/ms-vehicle-capability-set/api/app/v1/vehicle/capability/available",
                vin=target_vin,
            )
            capabilities = _map_capabilities(raw)
        except (ZeekrAPIError, httpx.HTTPError) as exc:
            logger.warning("获取车辆能力集失败：%s", exc)

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
            "chargePlan": charge_plan,
            # 能力集映射未经真车确认 —— 前端拿到 false 时不应把它当权威结论，
            # 只用来"少显示几个明显不支持的按钮"。
            "verified": False,
        }

    async def aclose(self) -> None:
        """释放底层连接。"""
        await self._http.aclose()
