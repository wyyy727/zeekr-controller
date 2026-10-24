"""应用配置。

所有敏感信息（极氪账号、密钥）通过环境变量或本地 .env 注入，
**绝不进入版本库**。
"""

from __future__ import annotations

import os
import re
from dataclasses import dataclass, field
from pathlib import Path

BASE_DIR = Path(__file__).resolve().parent.parent.parent
DATA_DIR = BASE_DIR / "data"
DATA_DIR.mkdir(parents=True, exist_ok=True)


def _load_dotenv() -> None:
    """加载 .env 到 os.environ（已存在的环境变量优先，不覆盖）。

    为什么需要这一步：此前 `.env` 只在 `scripts/server.sh` 里被 `source` 读取，
    而 `config.py` 自身完全不看 `.env`。于是：

      - 用 `uvicorn app.main:app` 或 IDE 直接启动 → .env 不生效；
      - 按 README 的 `cd .. && cp .env.example .env` 操作时，.env 落在
        **仓库根目录**，而 server.sh 找的是 **server/.env** → 同样不生效。

    两者的共同后果是：用户以为在用真实数据，实际静默跑在模拟模式下。
    这里补上统一加载，并同时查找两个位置，消除路径歧义。

    查找顺序（先命中的先用）：server/.env → 仓库根目录/.env
    """
    for candidate in (BASE_DIR / ".env", BASE_DIR.parent / ".env"):
        if not candidate.is_file():
            continue
        text: str | None = None
        for encoding in ("utf-8", "gbk"):
            try:
                text = candidate.read_text(encoding=encoding)
                break
            except (OSError, UnicodeDecodeError):
                continue
        if text is None:
            continue

        for raw in text.splitlines():
            line = raw.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, _, value = line.partition("=")
            key = key.strip()
            if not key or key in os.environ:
                continue
            # 只把「空白 + #」视为行内注释，避免误伤值里的 #
            value = re.sub(r"\s+#.*$", "", value).strip()
            if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
                value = value[1:-1]
            os.environ[key] = value


_load_dotenv()


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


def _env_float(key: str, default: float) -> float:
    try:
        return float(_env(key) or default)
    except ValueError:
        return default


@dataclass
class ZeekrConfig:
    """极氪国区密钥配置。

    密钥来源：wysie/zeekr_key_extractor 从官方安卓 APK 提取（--region CN）。
    本文件不提供、不分发任何密钥，请自行提取后填入环境变量。
    """

    # 注意：登录手机号**不在这里配置**。它由客户端在登录时输入并随请求传入
    # （POST /api/auth/sendCode 的 phone 字段），服务端启动阶段并不需要知道它。

    # 6 个密钥（从安卓 APK 提取）
    hmac_access_key: str = field(default_factory=lambda: _env("ZEEKR_HMAC_ACCESS_KEY"))
    hmac_secret_key: str = field(default_factory=lambda: _env("ZEEKR_HMAC_SECRET_KEY"))
    password_public_key: str = field(default_factory=lambda: _env("ZEEKR_PASSWORD_PUBLIC_KEY"))
    prod_secret: str = field(default_factory=lambda: _env("ZEEKR_PROD_SECRET"))
    vin_key: str = field(default_factory=lambda: _env("ZEEKR_VIN_KEY"))
    vin_iv: str = field(default_factory=lambda: _env("ZEEKR_VIN_IV"))

    # 可选：从 App 抓包得到的 X-VIN 令牌（部分车型的 GW3 实时状态/车控需要）
    vehicle_token: str = field(default_factory=lambda: _env("ZEEKR_VEHICLE_TOKEN"))

    # TSP 平台号 —— `/ms-app-bff/api/1.0/permissions` 的必填参数。
    #
    # 2026-10-16 用真车令牌枚举实测（网关自己回的错，不需要猜）：
    #   非数字        → 000002 param check failed（参数校验就挂了）
    #   1 / 2 / 3     → 037021 平台类型未定义
    #   4             → 000000 ok，但 data 为空数组
    #   5 / 7 / 8 / 21…27 → 000000 ok，返回该车 21 项权限（内容一致）
    # 故取 5。若不适用可在 .env 用 ZEEKR_TSP_PLATFORM 覆盖。
    tsp_platform: str = field(default_factory=lambda: _env("ZEEKR_TSP_PLATFORM") or "5")

    # 会话持久化路径
    session_file: Path = field(
        default_factory=lambda: Path(_env("ZEEKR_SESSION_FILE") or (DATA_DIR / "session.json"))
    )

    @property
    def is_configured(self) -> bool:
        """是否已具备对接真实网关的最小配置。

        只看密钥。手机号由客户端在登录时提供，服务端启动时无从得知，
        也不该成为「能否走真实网关」的前置条件 —— 否则「换一个账号登录」
        会变成一件需要改配置文件并重启服务的事。
        """
        return bool(self.hmac_access_key and self.hmac_secret_key)

    def missing_keys(self) -> list[str]:
        """返回缺失的密钥名，便于前端提示。"""
        required = {
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

    # 可选的 API 令牌。**留空则不启用鉴权**（保持默认行为，方便本地联调）。
    # 设了值之后，除 /api/health 外的所有 /api/* 都必须带
    # `Authorization: Bearer <token>`（或 `?token=` 便于浏览器访问 /preview）。
    #
    # 为什么需要：服务端监听 0.0.0.0，开启车控后同一局域网内任何人都能
    # POST /api/vehicle/command 解锁车辆。文档只声明了"仅应在可信局域网内
    # 运行"，没有任何技术强制手段。
    api_token: str = field(default_factory=lambda: _env("API_TOKEN"))

    # 数据源：auto（配置齐全走真实接口，否则回落 mock）/ mock / live
    data_source: str = field(default_factory=lambda: _env("DATA_SOURCE", "auto"))

    # 轮询间隔（秒）
    poll_interval_idle: int = field(default_factory=lambda: _env_int("POLL_INTERVAL_IDLE", 300))
    poll_interval_charging: int = field(default_factory=lambda: _env_int("POLL_INTERVAL_CHARGING", 60))

    # 日电耗保底同步（小时）。0 = 关闭。
    #
    # 为什么需要：逐日电耗原本只在"用户打开行程页"时回源落库（GET
    # /api/trips/energy 成功后 upsert），连续几天不打开页面就攒不下数据。
    # 官方日统计只允许回查 60 天，真丢的风险不高，但用户要的是"不用管也在攒"，
    # 于是加一个进程内定时任务兜底。默认 6 小时一次，每次只打一个官方接口
    # （7 天窗口落在单次 ≤31 天的限制内），写入是覆盖，重复跑没有副作用。
    energy_sync_interval_hours: float = field(
        default_factory=lambda: _env_float("ENERGY_SYNC_INTERVAL_HOURS", 6.0)
    )
    # 保底任务每次回看的自然日数（1–31，只用一批）。7 天足够覆盖"周五没打开、
    # 周一才打开"这种间隔，又不会把单次请求拖慢。
    energy_sync_days: int = field(default_factory=lambda: _env_int("ENERGY_SYNC_DAYS", 7))


    database: Path = field(default_factory=lambda: DATA_DIR / "zeekr.db")

    # ── 浩汉充电（第三方网关）─────────────────────────────────
    #
    # **极氪 App 的充电地图并不是极氪自己做的** —— 地图页内嵌的是浩汉能源
    # （`haohanpower.tech`）的 SDK（APK 里的 `com.haohan.*` 包）。极氪侧的
    # `getListV2` 只给坐标与枪数，**电价在浩汉网关**，两边认证毫无关系。
    #
    # `channelId=1` 读自浩汉小程序前端的硬编码（`{"sourceCode":4,"channelId":1}`），
    # 实测即极氪渠道。**做成配置项而不是常量** —— 这是逆向得到的值，
    # 对方改动渠道号时应当改 .env 就能恢复，而不是等一次发版。
    haohan_host: str = field(
        default_factory=lambda: _env("ZEEKR_HAOHAN_HOST")
        or "https://gateway-prod.haohanpower.tech"
    )
    haohan_channel_id: str = field(
        default_factory=lambda: _env("ZEEKR_HAOHAN_CHANNEL_ID") or "1"
    )

    # ── 腾讯位置服务（车辆位置卡：地址 + 静态地图）──────────────
    #
    # 为什么必须有 key：车坐标是 **GCJ-02**，而合规上只能用腾讯/高德/百度/天地图
    # （Apple Maps 属禁止清单，iOS 端也用不了 MapKit）。腾讯的免 key 代理模式
    # 只对 WorkBuddy 生成的页面有效，本项目是本地 FastAPI 托管，用不了。
    #
    # **key 只放在服务端**：前端通过 `/api/vehicle/location/map.png` 拿图片，
    # 请求由后端代发。这样 HTML 里不会出现 key（一旦出现在前端 JS/URL 里，
    # 就等于公开），iOS 端也不用各自拼地图 URL。
    #
    # 未配置时一律降级：不请求第三方、地址为 None、地图不可用，
    # 界面只显示坐标 + 上报时间 —— 不用一句"服务异常"糊过去。
    #
    # ⚠️ 隐私边界：这是**唯一**会把车坐标发给第三方的路径，用户已知情同意。
    # 注释与日志里都不要打印坐标。
    tencent_map_key: str = field(
        default_factory=lambda: _env("TENCENT_MAP_KEY")
    )

    # ── DeepSeek Vision（充电账单截图 OCR）─────────────────────
    #
    # 金额的**唯一自动化来源**。极氪接口只给电量（`power`），车端报文里
    # 也没有任何费率字段；「补能订单」金额页在浩汉网关后、要浩汉账号态，
    # 不可自动化 ⇒ 只能靠截图识别。
    #
    # 隐私边界（硬约束，别为了省事放宽）：
    #   · 截图**不落盘**，只在内存里 base64 后直传，不写 /tmp、不进对象存储；
    #   · 上传前不做框选/涂黑（已核实截图不含 VIN），但**回传要做字段白名单 + 正则过滤**；
    #   · 日志只记 sha256 前 8 位、字节数、耗时、字段数，**不记图片也不记上游原文**。
    #
    # 未配置 key 时 OCR 接口返回 503，界面提示"去 .env 填 key"；
    # 手工录入不依赖任何外部服务，照常可用。
    deepseek_api_key: str = field(default_factory=lambda: _env("DEEPSEEK_API_KEY"))
    deepseek_base_url: str = field(
        default_factory=lambda: _env("DEEPSEEK_BASE_URL") or "https://api.deepseek.com"
    )
    vision_model: str = field(
        default_factory=lambda: _env("DEEPSEEK_VISION_MODEL")
        or "deepseek-v4-flash-vision-exp"
    )

    # 估算用的兜底单价（元/度）。**0 = 关闭估算**。
    #
    # 为什么默认关：估算说不出"这笔到底是谁付的"，一个凭空算出来的金额
    # 很容易被当成实际支出。只有在用户自己配了本地电价（比如家充 0.5 元/度）
    # 时才打开，且界面必须与「已确认金额」分两列、不参与单价计算。
    charge_estimate_price: float = field(
        default_factory=lambda: _env_float("CHARGE_ESTIMATE_PRICE", 0.0)
    )

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
