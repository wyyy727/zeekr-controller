"""应用配置。

所有敏感信息（极氪账号、密钥）通过环境变量或本地 .env 注入，
**绝不进入版本库**。
"""

from __future__ import annotations

import os
from dataclasses import dataclass, field
from pathlib import Path

BASE_DIR = Path(__file__).resolve().parent.parent.parent
DATA_DIR = BASE_DIR / "data"
DATA_DIR.mkdir(parents=True, exist_ok=True)


def _env(key: str, default: str = "") -> str:
    return os.environ.get(key, default).strip()


def _env_bool(key: str, default: bool = False) -> bool:
    raw = _env(key).lower()
    if not raw:
        return default
    return raw in {"1", "true", "yes", "on"}


def _env_int(key: str, default: int) -> int:
    try:
        return int(_env(key) or default)
    except ValueError:
        return default


@dataclass
class ZeekrConfig:
    """极氪国区账号与密钥配置。

    密钥来源：wysie/zeekr_key_extractor 从官方安卓 APK 提取（--region CN）。
    本文件不提供、不分发任何密钥，请自行提取后填入环境变量。
    """

    # 极氪 App 注册手机号（中国大陆 +86）
    phone: str = field(default_factory=lambda: _env("ZEEKR_PHONE"))

    # 6 个密钥（从安卓 APK 提取）
    hmac_access_key: str = field(default_factory=lambda: _env("ZEEKR_HMAC_ACCESS_KEY"))
    hmac_secret_key: str = field(default_factory=lambda: _env("ZEEKR_HMAC_SECRET_KEY"))
    password_public_key: str = field(default_factory=lambda: _env("ZEEKR_PASSWORD_PUBLIC_KEY"))
    prod_secret: str = field(default_factory=lambda: _env("ZEEKR_PROD_SECRET"))
    vin_key: str = field(default_factory=lambda: _env("ZEEKR_VIN_KEY"))
    vin_iv: str = field(default_factory=lambda: _env("ZEEKR_VIN_IV"))

    # 可选：从 App 抓包得到的 X-VIN 令牌（部分车型的 GW3 实时状态/车控需要）
    vehicle_token: str = field(default_factory=lambda: _env("ZEEKR_VEHICLE_TOKEN"))

    # 会话持久化路径
    session_file: Path = field(
        default_factory=lambda: Path(_env("ZEEKR_SESSION_FILE") or (DATA_DIR / "session.json"))
    )

    @property
    def is_configured(self) -> bool:
        """是否已具备登录所需的最小配置。"""
        return bool(self.phone and self.hmac_access_key and self.hmac_secret_key)

    def missing_keys(self) -> list[str]:
        """返回缺失的密钥名，便于前端提示。"""
        required = {
            "ZEEKR_PHONE": self.phone,
            "ZEEKR_HMAC_ACCESS_KEY": self.hmac_access_key,
            "ZEEKR_HMAC_SECRET_KEY": self.hmac_secret_key,
            "ZEEKR_PASSWORD_PUBLIC_KEY": self.password_public_key,
            "ZEEKR_PROD_SECRET": self.prod_secret,
            "ZEEKR_VIN_KEY": self.vin_key,
            "ZEEKR_VIN_IV": self.vin_iv,
        }
        return [k for k, v in required.items() if not v]


@dataclass
class AppConfig:
    """应用级配置。"""

    host: str = field(default_factory=lambda: _env("APP_HOST", "0.0.0.0"))
    port: int = field(default_factory=lambda: _env_int("APP_PORT", 8765))
    debug: bool = field(default_factory=lambda: _env_bool("APP_DEBUG", False))

    # 允许下发的车控指令总开关（默认关闭，符合"只读优先"的安全原则）
    allow_commands: bool = field(default_factory=lambda: _env_bool("ALLOW_COMMANDS", False))

    # 数据源：auto（配置齐全走真实接口，否则回落 mock）/ mock / live
    data_source: str = field(default_factory=lambda: _env("DATA_SOURCE", "auto"))

    # 轮询间隔（秒）
    poll_interval_idle: int = field(default_factory=lambda: _env_int("POLL_INTERVAL_IDLE", 300))
    poll_interval_charging: int = field(default_factory=lambda: _env_int("POLL_INTERVAL_CHARGING", 60))

    database: Path = field(default_factory=lambda: DATA_DIR / "zeekr.db")

    zeekr: ZeekrConfig = field(default_factory=ZeekrConfig)

    @property
    def use_mock(self) -> bool:
        """是否需要使用 mock 数据源。"""
        if self.data_source == "mock":
            return True
        if self.data_source == "live":
            return False
        # auto：配置齐全则走真实接口
        return not self.zeekr.is_configured


config = AppConfig()
