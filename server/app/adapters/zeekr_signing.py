"""极氪国区网关签名与加密实现。

参考实现：RexzeLu/zeekr_ha（国区 +86 短信登录）

国区共三个网关，职责与签名方式各不相同：

| 网关 | 地址 | 签名 | 用途 |
|------|------|------|------|
| GW1 | api-gw-toc.zeekrlife.com | SHA1 排序签名 | 短信验证码、手机号登录（JWT） |
| GW2 | api.zeekrline.com | HMAC-SHA1 | 换取 ecar accessToken、车辆列表/状态 |
| GW3 | snc-tsp-api.zeekrlife.com | HMAC-SHA256 + AES 加密 VIN | 最新状态、远程控制指令 |

**免责声明**：本实现基于社区公开的逆向研究成果，与极氪 / 吉利无任何关联。
仅供个人自用学习，请自行评估所在司法辖区的法律法规。

===============================================================================
⚠️ 车控指令可信度分级（安全底线，改动本文件前必读）
===============================================================================

本文件里的 `serviceId` 直接决定向**真实车辆**下发什么报文。一条错误的
serviceId 可能：① 指令静默无效（用户以为锁了车，其实没锁）；② 触发未知
含义的车端动作。因此**必须把「有逆向依据的」与「按字母缩写猜的」严格分开**：

【已验证 · OK to drive】`ServiceID` 类 —— 有公开逆向成果佐证，与官方 App
    行为一致。来源为 RexzeLu/zeekr_ha 与 borconi/openzeekr：

        RDL（锁车）/ RDU（解锁）/ ZAF（空调）/ RWS（车窗）
        RHL（鸣笛闪灯）/ RCS（充电）

【未验证 · DO NOT SHIP】`ServiceIDUnverified` 类 —— **纯属按字母缩写推断，
    没有任何逆向依据，也从未在真车上验证过**，其中的参数 key/value 同样是猜的：

        ZDF（前风挡除霜）/ ZWH（方向盘加热）/ ZSH（座椅加热）
        ZSV（座椅通风）/ ZSR（遮阳帘）/ ZSM（哨兵模式）

    ⇒ **在真车验证并回填依据之前，不得在实车模式（live）下启用这些指令。**

【务必区分「支持」与「可信」】`COMMAND_MAP` 收录某指令，只代表它**结构上
    有定义**，不代表可以安全下发。`UNVERIFIED_COMMANDS` 给出基于猜测
    serviceId 的指令集合，上层应据此决策：

    条件                                   | 允许
    ---------------------------------------|--------------------------------
    指令不在 COMMAND_MAP 中                 | 拒绝（未知指令一律拒绝）
    指令在 UNVERIFIED_COMMANDS 中           | 仅 mock 模式允许；live 模式拒绝
    其余（已验证）                          | 允许下发

【建议的验证流程】单人单车、逐条推进，切勿一次性全开：

    1. `ALLOW_COMMANDS=true` + `ZEEKR_MOCK=true` 跑通链路与 UI 反馈；
    2. 写清「验证前预期」——如 defrost 是否真的除雾、carFinder 是否只闪灯不鸣笛；
    3. 切换到 live，**一次只放开一条**，在车旁目视确认车端真实动作，
       并记录下发时间、报文、车端响应与观测结果；
    4. 验证通过后：把该 serviceId 从 `ServiceIDUnverified` 迁到 `ServiceID`，
       从 `UNVERIFIED_COMMANDS` 中移除对应指令，并在类 docstring 里补上
       逆向出处或验证记录，最后同步更新测试。

    历史教训：曾把所有 serviceId 混在一个类里，靠人肉记忆分辨「哪些能上真车」，
    结果猜的值与逆向的值看起来一模一样 —— 这种写法本身就是隐患。
"""

from __future__ import annotations

import base64
import hashlib
import hmac
import json
import time
import uuid
from typing import Any

from Crypto.Cipher import AES
from Crypto.Util.Padding import pad

# MARK: - 网关地址

GW1_HOST = "https://api-gw-toc.zeekrlife.com"
GW2_HOST = "https://api.zeekrline.com"
GW3_HOST = "https://snc-tsp-api.zeekrlife.com"

# GW3 参与签名的请求头白名单。
#
# 注意：**不是所有请求头都参与签名**，也**不是只有 x-api* 参与**。
# 必须严格按此白名单过滤，否则签名串与网关预期不一致，会返回
# `079025 Signature authentication failed`。
#
# 不在白名单内的头（如 User-Agent、X-APP-OS-VERSION）照常发送，但不参与签名。
GW3_SIGNED_HEADERS = frozenset({
    "x-app-id",
    "content-type",
    "x-api-signature-nonce",
    "x-timestamp",
    "x-api-signature-version",
    "x-project-id",
    "authorization",
    "accept-language",
    "x-vin",
    "x-device-id",
    "x-platform",
})

# 签名的 App ID —— GW3 所有端点（含登录）都必须使用此值，
# 网关按它查签名密钥，用错直接报签名失败
GW3_APP_ID = "ZEEKRCNCH001M0001"

# 签名协议版本
GW3_SIGNATURE_VERSION = "2.0"

# 与官方 App 保持一致的客户端标识
APP_VERSION = "5.0.5"
APP_OS_VERSION = "18.5"
USER_AGENT = f"ZeekrApp/{APP_VERSION} (iPhone; iOS {APP_OS_VERSION})"


# MARK: - 工具函数


def _md5_hex(data: str | bytes) -> str:
    """计算 MD5 十六进制摘要（小写）。"""
    if isinstance(data, str):
        data = data.encode("utf-8")
    return hashlib.md5(data).hexdigest()


def _nonce() -> str:
    """生成带横线的 UUID nonce（与 App 一致）。"""
    return str(uuid.uuid4())


def build_login_device_id() -> str:
    """构造登录设备档案串。

    App 发送的是 `{品牌}-{机型}-{SDK}-{系统版本}` 形式的复合串，
    SDK 会按它描述会话来源设备；早期用随机 uuid 会缺少 SDK 需要的分段。
    """
    return f"Apple-iPhone-{APP_OS_VERSION}-iOS"


# MARK: - GW1 签名（SHA1 排序签名）


def sign_gw1(params: dict[str, Any], body: str = "") -> dict[str, str]:
    """GW1 请求签名。

    GW1 用于短信验证码与手机号登录，签名方式为参数排序后 SHA1。

    Returns:
        需要附加到请求头的签名字段
    """
    ts = str(int(time.time() * 1000))
    nonce = _nonce()

    # 参与签名的字段按 key 字典序排序
    items = [f"{k}={v}" for k, v in sorted(params.items()) if v is not None]
    raw = "&".join(items) + f"&timestamp={ts}&nonce={nonce}"

    signature = hashlib.sha1(raw.encode("utf-8")).hexdigest()

    return {
        "timestamp": ts,
        "nonce": nonce,
        "signature": signature,
        "X-APP-ID": GW3_APP_ID,
        "X-APP-OS-VERSION": APP_OS_VERSION,
        "User-Agent": USER_AGENT,
        "Content-Type": "application/json; charset=utf-8",
    }


# MARK: - GW3 签名（HMAC-SHA256）


def _escape_query_value(value: Any) -> str:
    """GW3 query 值转义。

    规则（复刻官方 App 行为）：
    - `*` → `%2A`（星号必须编码）
    - `%2F` → `/`（撤销斜杠的百分号编码）
    - `%3F` → `?`（撤销问号的百分号编码）
    """
    text = str(value)
    return text.replace("*", "%2A").replace("%2F", "/").replace("%3F", "?")


def build_gw3_string_to_sign(
    method: str,
    path: str,
    headers: dict[str, str],
    query: dict[str, str] | None = None,
    body: str | None = None,
) -> str:
    """构造 GW3 待签名字符串（canonical）。

    格式为四段拼接：

        head_part + query_part + body_part + METHOD + "\\n" + path

    1. **head_part**：白名单头中每个 `小写头名:值\\n`，按头名小写排序。
       `x-vin` 与 `authorization` 为空时跳过，其余白名单头即使为空也写入。
    2. **query_part**：键排序后用 `&` 连接的 `k=v`，有值时末尾加 `\\n`。
    3. **body_part**：`base64(md5(body))`，末尾加 `\\n`；
       仅当 body 存在且 Content-Type 含 `application/json` 时写入。
    4. **method + "\\n" + path**：方法大写，无末尾换行。

    关键约束：参与签名的 body 字节必须与实际发送的字节**完全一致**，
    因此必须使用紧凑 JSON 序列化，并以 `content=` 发送原文。
    """
    # 1. 白名单头，按头名小写排序，每行 `name:value\n`
    lines: list[str] = []
    for key in sorted(headers, key=str.lower):
        lower = key.lower()
        if lower not in GW3_SIGNED_HEADERS:
            continue
        value = headers[key]
        # x-vin 与 authorization 为空时跳过（网关不要求签名空值）
        if lower in ("x-vin", "authorization") and not value:
            continue
        lines.append(f"{lower}:{value}\n")
    head_part = "".join(lines)

    # 2. query
    query_part = ""
    if query:
        escaped = {k: _escape_query_value(v) for k, v in query.items()}
        query_part = "&".join(f"{k}={escaped[k]}" for k in sorted(escaped)) + "\n"

    # 3. body（仅 JSON 请求体参与）
    body_part = ""
    content_type = (
        headers.get("Content-Type") or headers.get("content-type") or ""
    ).lower()
    if body is not None and "application/json" in content_type:
        body_md5 = hashlib.md5(body.encode("utf-8")).digest()
        body_part = base64.b64encode(body_md5).decode("ascii") + "\n"

    # 4. 方法 + 路径
    return head_part + query_part + body_part + method.upper() + "\n" + path


def sign_gw3(
    prod_secret: str,
    method: str,
    path: str,
    headers: dict[str, str],
    query: dict[str, str] | None = None,
    body: str | None = None,
) -> str:
    """GW3 请求签名。

    `X-SIGNATURE = base64(HMAC-SHA256(prod_secret, stringToSign))`
    —— 注意摘要以 **Base64** 编码（44 字符），不是 hex。

    Args:
        prod_secret: X-SIGNATURE 的 HMAC 密钥
        method: HTTP 方法
        path: URL 路径（不含 host 与 query）
        headers: 请求头（仅白名单内的参与签名）
        query: 查询参数
        body: 请求体原文（须与实际发送的字节逐字节一致）

    Returns:
        Base64 编码的签名串
    """
    canonical = build_gw3_string_to_sign(method, path, headers, query, body)

    digest = hmac.new(
        prod_secret.encode("utf-8"),
        canonical.encode("utf-8"),
        hashlib.sha256,
    ).digest()

    return base64.b64encode(digest).decode("ascii")


def build_gw3_headers(
    prod_secret: str,
    method: str,
    path: str,
    query: dict[str, str] | None = None,
    body: str | None = None,
    authorization: str | None = None,
    encrypted_vin: str | None = None,
) -> dict[str, str]:
    """构造 GW3 完整请求头（含签名）。

    仅白名单内的头参与签名（见 `GW3_SIGNED_HEADERS`）；
    `User-Agent` 等会照常发送但不参与签名。

    注意签名与发送的字节必须完全一致，因此请求体须用紧凑 JSON 序列化，
    并以 `content=` 发送原文（用 `json=` 会因序列化差异导致验签失败）。
    """
    headers: dict[str, str] = {
        "X-APP-ID": GW3_APP_ID,
        "X-API-SIGNATURE-VERSION": GW3_SIGNATURE_VERSION,
        "X-TIMESTAMP": str(int(time.time() * 1000)),
        "X-API-SIGNATURE-NONCE": _nonce(),
        "Content-Type": "application/json; charset=utf-8",
        # 以下为参与传输但不参与签名的头
        "X-APP-OS-VERSION": APP_OS_VERSION,
        "User-Agent": USER_AGENT,
    }

    if authorization:
        headers["Authorization"] = authorization
    if encrypted_vin:
        headers["X-VIN"] = encrypted_vin

    headers["X-SIGNATURE"] = sign_gw3(
        prod_secret=prod_secret,
        method=method,
        path=path,
        headers=headers,
        query=query,
        body=body,
    )

    return headers


# MARK: - GW2 签名（HMAC-SHA1）


def sign_gw2(
    hmac_access_key: str,
    hmac_secret_key: str,
    method: str,
    path: str,
    query: dict[str, str] | None = None,
    body: str | None = None,
) -> dict[str, str]:
    """GW2 请求签名（HMAC-SHA1）。

    Returns:
        需附加到请求头的签名字段
    """
    ts = str(int(time.time() * 1000))
    nonce = _nonce()

    query_part = ""
    if query:
        query_part = "&".join(f"{k}={query[k]}" for k in sorted(query))

    body_md5 = _md5_hex(body) if body else ""

    string_to_sign = "\n".join([
        f"x-hmac-access-key:{hmac_access_key}",
        query_part,
        body_md5,
        method.upper(),
        path,
    ])

    signature = hmac.new(
        hmac_secret_key.encode("utf-8"),
        string_to_sign.encode("utf-8"),
        hashlib.sha1,
    ).hexdigest()

    return {
        "X-HMAC-ACCESS-KEY": hmac_access_key,
        "X-TIMESTAMP": ts,
        "X-NONCE": nonce,
        "X-SIGNATURE": signature,
        "Content-Type": "application/json; charset=utf-8",
        "User-Agent": USER_AGENT,
    }


# MARK: - VIN 加密（AES-128-CBC）


def encrypt_vin(vin: str, vin_key: str, vin_iv: str) -> str:
    """加密 VIN，用于 GW3 的 `X-VIN` 头。

    算法：AES-128-CBC / PKCS7 / Base64。
    网关要求密文长度至少 17 字符（VIN 本身的长度）。

    Args:
        vin: 明文车辆识别码
        vin_key: AES 密钥（App 提取）
        vin_iv: AES 初始向量（App 提取）

    Returns:
        Base64 编码的密文

    前置校验：`AES.new` 在密钥/IV 不足 16 字节时会抛 ValueError，而在 live
    路径里这个异常会被上层的泛化 `except Exception` 吞掉，排障时几乎看不出
    根因。这里提前校验并给出明确错误。VIN 也限定 ASCII —— 含非 ASCII 字符
    时会算出网关无法解密的密文（表现为 `079025 Decrypt X-VIN failed`）。
    """
    key_bytes = vin_key.encode("utf-8")
    iv_bytes = vin_iv.encode("utf-8")

    if len(key_bytes) < 16:
        raise ValueError(f"ZEEKR_VIN_KEY 至少需要 16 字节，当前 {len(key_bytes)} 字节")
    if len(iv_bytes) < 16:
        raise ValueError(f"ZEEKR_VIN_IV 至少需要 16 字节，当前 {len(iv_bytes)} 字节")
    if not vin:
        raise ValueError("VIN 不能为空")
    if not vin.isascii():
        raise ValueError("VIN 必须是 ASCII 字符，否则网关无法解密")

    cipher = AES.new(key_bytes[:16], AES.MODE_CBC, iv_bytes[:16])
    ciphertext = cipher.encrypt(pad(vin.encode("utf-8"), AES.block_size))
    return base64.b64encode(ciphertext).decode("ascii")


def encrypt_password(password: str, public_key_b64: str) -> str:
    """使用 RSA 公钥加密登录密码。

    公钥由 `zeekr_key_extractor` 从 App 提取。
    """
    from Crypto.PublicKey import RSA
    from Crypto.Cipher import PKCS1_v1_5

    pem = public_key_b64.strip()
    if not pem.startswith("-----BEGIN"):
        # 裸 base64 公钥需补全 PEM 头尾
        lines = [pem[i:i + 64] for i in range(0, len(pem), 64)]
        pem = "-----BEGIN PUBLIC KEY-----\n" + "\n".join(lines) + "\n-----END PUBLIC KEY-----"

    key = RSA.import_key(pem)
    cipher = PKCS1_v1_5.new(key)
    encrypted = cipher.encrypt(password.encode("utf-8"))
    return base64.b64encode(encrypted).decode("ascii")


# MARK: - 远程控制命令映射


class ServiceID:
    """远程控制 serviceId —— **已验证**，可下发真车。

    参考：RexzeLu/zeekr_ha 与 borconi/openzeekr 的逆向成果，
    与官方 App 实际报文一致，已在真车上验证过。

    本类只允许放**有逆向依据或已验证**的值。
    仅按字母缩写推断的值请放到 `ServiceIDUnverified`。
    """

    # 车门
    LOCK = "RDL"        # 锁车
    UNLOCK = "RDU"      # 解锁
    # 空调
    CLIMATE = "ZAF"     # 空调开关与温度
    # 车窗 / 天窗 / 遮阳帘
    WINDOW = "RWS"
    # 鸣笛 / 闪灯
    HORN_LIGHT = "RHL"
    # 充电
    CHARGE = "RCS"


class ServiceIDUnverified:
    """远程控制 serviceId —— **未验证，真车验证前不要启用**。

    ⚠️ 以下所有值均为**按功能英文名首字母推断**，没有任何逆向依据，
    也从未在真车上验证过；与之配套的参数 key/value 同样是猜的。

    风险后果：轻则指令静默无效（用户以为锁了车 / 开了哨兵，实际没生效 ——
    这本身即安全问题），重则向车端发送未知含义的报文、触发非预期动作。

    ⇒ 这些值**只允许在 mock 模式下使用**；live 模式下应由上层按
      `UNVERIFIED_COMMANDS` 显式拦截（见模块顶部「车控指令可信度分级」）。

    验证通过后的迁移步骤：把常量搬到 `ServiceID`，在注释里补上逆向出处或
    验证记录，并从 `UNVERIFIED_COMMANDS` 中移除对应指令名。

    待验证清单（真车逐条确认）：

        DEFROST    —— 前风挡除霜：验证是否真的除雾、是否影响空调状态
        WHEEL_HEAT —— 方向盘加热：验证档位语义与自动关闭行为
        SEAT_HEAT  —— 座椅加热：验证主/副驾与档位参数
        SEAT_VENT  —— 座椅通风：验证主/副驾与档位参数
        SUNSHADE   —— 遮阳帘：验证开/关/停三种动作是否需要不同 value
        SENTINEL   —— 哨兵模式：验证是否能可靠关闭（误开将导致持续耗电）
    """

    # ⚠️ 以下全部为推断值 —— 未经真车验证，禁止在 live 模式启用
    DEFROST = "ZDF"      # 前风挡除霜（推断）
    WHEEL_HEAT = "ZWH"   # 方向盘加热（推断）
    SEAT_HEAT = "ZSH"    # 座椅加热（推断）
    SEAT_VENT = "ZSV"    # 座椅通风（推断）
    SUNSHADE = "ZSR"     # 遮阳帘（推断）
    SENTINEL = "ZSM"     # 哨兵模式（推断）


def build_control_body(service_id: str, key: str, value: str) -> dict[str, Any]:
    """构造远程控制请求体。

    注意 `serviceParameters` **嵌在 `setting` 里**，这是网关的硬性结构要求。
    """
    return {
        "command": "start",
        "serviceId": service_id,
        "setting": {
            "serviceParameters": [
                {"key": key, "value": value}
            ]
        },
    }


# 指令名 → (serviceId, 参数 key, 参数 value) 映射
#
# ⚠️ 本表**收录 ≠ 可信**。它同时包含已验证指令（引用 `ServiceID`）
#    与仅结构上有定义的未验证指令（引用 `ServiceIDUnverified`）。
#    未验证指令名见下方 `UNVERIFIED_COMMANDS`。
COMMAND_MAP: dict[str, tuple[str, str, str]] = {
    # ---- 已验证：serviceId 有逆向依据，参数与官方 App 一致 ----
    "lock":        (ServiceID.LOCK, "LOCK", "true"),
    "unlock":      (ServiceID.UNLOCK, "UNLOCK", "true"),
    "climateOn":   (ServiceID.CLIMATE, "AC", "true"),
    "climateOff":  (ServiceID.CLIMATE, "AC", "false"),
    "flash":       (ServiceID.HORN_LIGHT, "rhl", "light-flash"),
    "honk":        (ServiceID.HORN_LIGHT, "rhl", "light-horn"),
    "chargeStart": (ServiceID.CHARGE, "RCS", "start"),
    "chargeStop":  (ServiceID.CHARGE, "RCS", "stop"),
    "closeWindows": (ServiceID.WINDOW, "RWS", "close"),

    # ---- ⚠️ 未验证：serviceId 为推断值，真车验证前禁止在 live 模式启用 ----
    # 状态开关型（与原生车控面板第一组对齐）
    "defrost":     (ServiceIDUnverified.DEFROST, "DF", "true"),
    "wheelHeat":   (ServiceIDUnverified.WHEEL_HEAT, "WH", "true"),
    "seatHeat":    (ServiceIDUnverified.SEAT_HEAT, "SH", "true"),
    "ventSeat":    (ServiceIDUnverified.SEAT_VENT, "SV", "true"),
    # 远程操作
    "sunshade":     (ServiceIDUnverified.SUNSHADE, "SR", "true"),
    "sentinel":     (ServiceIDUnverified.SENTINEL, "SM", "true"),
    # 场景（组合指令，由服务端按需展开）
    "tripPlan":    (ServiceID.CLIMATE, "TP", "true"),
    "carFinder":   (ServiceID.HORN_LIGHT, "rhl", "car-finder"),
    "refresh":     (ServiceID.HORN_LIGHT, "rhl", "noop"),
}

# 基于**猜测 serviceId 或猜测参数**的指令名集合 —— 即「未验证指令」。
#
# 这些指令与 `COMMAND_MAP` 中的已验证指令在结构上完全一样，**单看映射表
# 无法分辨**，必须靠本集合显式标记，上层才能据此决策：
#
#   - mock 模式：可以放行（仅打日志，不动真车），便于联调 UI 与链路；
#   - live 模式：**必须拒绝**，直到逐条完成真车验证并迁入已验证集合。
#
# 判定口径是「serviceId 或参数 key/value 是否有逆向依据」——
# 只要任一项是推断的，就不可信：
#   · `tripPlan`    复用已验证的 ZAF，但参数 key（TP）是推断的
#   · `closeWindows` 复用已验证的 RWS，但 value（close）是推断的
#   · `carFinder`   复用已验证的 RHL，但 value（car-finder）是推断的
#   · `refresh`     复用已验证的 RHL，但 value（noop）是推断的
# 每验证通过一条，就从这里删掉一条。
UNVERIFIED_COMMANDS: frozenset[str] = frozenset({
    # serviceId 与参数 key/value 均为推断
    "defrost",      # ZDF 推断，参数 DF 推断
    "wheelHeat",    # ZWH 推断，参数 WH 推断
    "seatHeat",     # ZSH 推断，参数 SH 推断
    "ventSeat",     # ZSV 推断，参数 SV 推断
    "sunshade",     # ZSR 推断，参数 SR 推断
    "sentinel",     # ZSM 推断，参数 SM 推断
    # serviceId 复用已验证值，但参数 key/value 为推断
    "tripPlan",     # ZAF + 参数 TP 推断
    "closeWindows", # RWS + value "close" 推断
    "carFinder",    # RHL + value "car-finder" 推断
    "refresh",      # RHL + value "noop" 推断
})


def is_supported_command(command: str) -> bool:
    """是否为已知指令（仅代表 COMMAND_MAP 中有定义）。

    ⚠️ **注意语义**：本函数只回答「这个指令名认不认识」，
    **不代表它已通过验证、可以下发真车**。未验证指令同样返回 True，
    因为其结构定义是完整的。

    要判断能否上真车，请改用 `is_verified_command()`。

    未知指令不能在客户端伪造成功 —— 车控涉及真实车辆动作，
    宁可明确失败，也不要让用户误以为已经生效。
    """
    return command in COMMAND_MAP


def is_verified_command(command: str) -> bool:
    """是否可安全下发**真车**的指令。

    只有同时满足以下两条才返回 True：

    1. 指令在 `COMMAND_MAP` 中有定义（即 `is_supported_command` 为真）；
    2. 指令**不在** `UNVERIFIED_COMMANDS` 中（serviceId 与参数均有依据）。

    live 模式的车控入口应当用本函数把关；mock 模式则只需
    `is_supported_command`，便于在不动真车的前提下联调未验证指令。
    """
    return command in COMMAND_MAP and command not in UNVERIFIED_COMMANDS


def compact_json(obj: Any) -> str:
    """紧凑 JSON 序列化。

    签名串里含请求体 MD5，因此签名与发送的字节必须逐字节一致 ——
    必须用紧凑格式（无多余空格），且以 `data=` 发送原文。
    """
    return json.dumps(obj, ensure_ascii=False, separators=(",", ":"))
