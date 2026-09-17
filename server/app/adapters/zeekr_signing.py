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

# GW3 所有端点（含登录）都必须使用此 app id，网关按它查签名密钥
GW3_APP_ID = "ZEEKRCNCH001M0001"

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


def sign_gw3(
    prod_secret: str,
    method: str,
    path: str,
    headers: dict[str, str],
    query: dict[str, str] | None = None,
    body: str | None = None,
) -> str:
    """GW3 请求签名。

    `X-SIGNATURE = base64(HMAC-SHA256(prod_secret, stringToSign))`，
    其中 stringToSign 的构造顺序为：

        1. 所有 `x-api*` 开头的头，按「小写头名:值」升序排列，换行连接
        2. query 参数按 key 排序，以 `k=v` 用 `&` 连接
        3. 请求体 MD5 十六进制（无请求体时为空串）
        4. HTTP 方法（大写）
        5. URL 路径

    注意：`X-TIMESTAMP` 是普通头，**不参与签名**。

    Args:
        prod_secret: X-SIGNATURE 的 HMAC 密钥
        method: HTTP 方法
        path: URL 路径（不含 host）
        headers: 请求头
        query: 查询参数
        body: 请求体原文（须与实际发送的字节逐字节一致）

    Returns:
        Base64 编码的签名串（44 字符）
    """
    # 1. x-api* 头，小写名:值，升序
    api_headers = sorted(
        (k.lower(), v) for k, v in headers.items() if k.lower().startswith("x-api")
    )
    header_part = "\n".join(f"{k}:{v}" for k, v in api_headers)

    # 2. query，按 key 排序
    query_part = ""
    if query:
        # `*` 需转义为 %2A，与官方 App 一致
        escaped = {k: str(v).replace("*", "%2A") for k, v in query.items()}
        query_part = "&".join(f"{k}={escaped[k]}" for k in sorted(escaped))

    # 3. body md5
    body_md5 = _md5_hex(body) if body else ""

    string_to_sign = "\n".join([
        header_part,
        query_part,
        body_md5,
        method.upper(),
        path,
    ])

    digest = hmac.new(
        prod_secret.encode("utf-8"),
        string_to_sign.encode("utf-8"),
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

    注意签名与发送的字节必须一致，因此请求体须用紧凑 JSON 序列化。
    """
    headers: dict[str, str] = {
        "X-APP-ID": GW3_APP_ID,
        "X-APP-OS-VERSION": APP_OS_VERSION,
        "User-Agent": USER_AGENT,
        "Content-Type": "application/json; charset=utf-8",
        "X-TIMESTAMP": str(int(time.time() * 1000)),
        # 带横线的 UUID nonce
        "X-NONCE": _nonce(),
    }

    if authorization:
        headers["Authorization"] = authorization
    if encrypted_vin:
        headers["X-VIN"] = encrypted_vin

    signature = sign_gw3(
        prod_secret=prod_secret,
        method=method,
        path=path,
        headers=headers,
        query=query,
        body=body,
    )
    headers["X-SIGNATURE"] = signature

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
    """
    cipher = AES.new(
        vin_key.encode("utf-8")[:16],
        AES.MODE_CBC,
        vin_iv.encode("utf-8")[:16],
    )
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
    """远程控制 serviceId 映射（与官方 App 一致）。

    参考：RexzeLu/zeekr_ha 与 borconi/openzeekr 的逆向成果。
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
COMMAND_MAP: dict[str, tuple[str, str, str]] = {
    "lock":        (ServiceID.LOCK, "LOCK", "true"),
    "unlock":      (ServiceID.UNLOCK, "UNLOCK", "true"),
    "climateOn":   (ServiceID.CLIMATE, "AC", "true"),
    "climateOff":  (ServiceID.CLIMATE, "AC", "false"),
    "flash":       (ServiceID.HORN_LIGHT, "rhl", "light-flash"),
    "honk":        (ServiceID.HORN_LIGHT, "rhl", "light-horn"),
    "chargeStart": (ServiceID.CHARGE, "RCS", "start"),
    "chargeStop":  (ServiceID.CHARGE, "RCS", "stop"),
}


def compact_json(obj: Any) -> str:
    """紧凑 JSON 序列化。

    签名串里含请求体 MD5，因此签名与发送的字节必须逐字节一致 ——
    必须用紧凑格式（无多余空格），且以 `data=` 发送原文。
    """
    return json.dumps(obj, ensure_ascii=False, separators=(",", ":"))
