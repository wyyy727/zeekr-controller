"""FastAPI 应用入口。"""

from __future__ import annotations

import asyncio
import hmac
import logging
from contextlib import asynccontextmanager
from pathlib import Path

from fastapi import FastAPI, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse

from .core.config import config
from .core.store import Store

logging.basicConfig(
    level=logging.DEBUG if config.debug else logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
)

logger = logging.getLogger(__name__)

# httpx 在 INFO 级别打印**完整请求 URL**，而腾讯的 URL 里带 key 与车辆坐标：
# 落到 .server.log 就等于把密钥和"车停在哪"写进文件，与本模块"日志绝不打印坐标"的
# 承诺相反。压到 WARNING：失败仍会记（异常类型），成功不再回显 URL。
logging.getLogger("httpx").setLevel(logging.WARNING)
logging.getLogger("httpcore").setLevel(logging.WARNING)

store = Store(config.database)

# 令牌为空时的信任范围：只认本机来源。
# Uvicorn 在 0.0.0.0 上监听时，本机访问的 client.host 是 127.0.0.1
# （IPv6 双栈下可能是 ::ffff:127.0.0.1）；TestClient 是 "testclient"。
_LOOPBACK_CLIENTS = {"127.0.0.1", "::1", "localhost", "testclient"}


def _is_loopback_client(host: str) -> bool:
    if not host:
        return False
    if host in _LOOPBACK_CLIENTS:
        return True
    return host.rsplit(":", 1)[-1] in _LOOPBACK_CLIENTS


@asynccontextmanager
async def lifespan(app: FastAPI):
    """应用生命周期管理。"""
    logger.info("ZeekrDash 服务启动，端口 %s", config.port)
    if not config.api_token and config.host not in ("127.0.0.1", "localhost", "::1"):
        logger.warning(
            "监听 %s 且未设置 API_TOKEN：非本机来源的 /api/* 将被拒绝。"
            "若要用真机 App 或远程访问，请在 .env 里设置 API_TOKEN 后重启。",
            config.host,
        )
    if config.use_mock:
        logger.info("当前为模拟数据模式（未配置极氪账号或显式指定）")

    # 日电耗保底同步：只在真实数据模式下启动（mock 没有真正的逐日电耗可拉）。
    # 为什么需要：逐日电耗原本只在"用户打开行程页"时回源落库，连续几天不打开
    # 页面就攒不下数据。详见 core/scheduler.py 的说明。
    sync_task: asyncio.Task | None = None
    if not config.use_mock and config.energy_sync_interval_hours > 0:
        from .core.scheduler import energy_sync_loop

        sync_task = asyncio.create_task(
            energy_sync_loop(config.energy_sync_interval_hours, config.energy_sync_days)
        )

    yield

    if sync_task is not None:
        sync_task.cancel()
        try:
            await sync_task
        except asyncio.CancelledError:
            pass

    # 释放 HTTP 连接
    from .adapters import get_client
    from .adapters.live_client import LiveZeekrClient

    client = get_client()
    if isinstance(client, LiveZeekrClient):
        await client.aclose()
    logger.info("ZeekrDash 服务已停止")


def _api_docs_kwargs(enabled: bool) -> dict[str, str | None]:
    """自动文档的三个 URL：关掉时传 None，FastAPI 就根本不注册这些路由。

    传 None 而不是"注册了再拦"，是因为后者一旦中间件顺序或路径匹配出偏差，
    文档就会重新露出来；不注册是彻底没有。
    """
    return {
        "docs_url": "/docs" if enabled else None,
        "redoc_url": "/redoc" if enabled else None,
        "openapi_url": "/openapi.json" if enabled else None,
    }


app = FastAPI(
    title="ZeekrDash",
    description="极氪车主自建看板服务端",
    version="0.1.0",
    lifespan=lifespan,
    # 默认关闭：公网部署不该把接口清单摊开（见 core/config.py 的 api_docs_enabled）。
    **_api_docs_kwargs(config.api_docs_enabled),
)

# iOS App 直连本机服务；preview 页也可能从别的端口访问，故放开跨域。
#
# 注意不能用 allow_origins=["*"] 搭配 allow_credentials=True —— 两者在 CORS
# 规范里互斥（浏览器会直接拒绝该响应）。本服务不使用 Cookie，显式关掉
# credentials 即可，语义正确且不影响 iOS 原生请求。
app.add_middleware(
    CORSMiddleware,
    # 留空 = `*`（默认，兼容既有三种用法）；填了 CORS_ORIGINS 就只允许列出的来源。
    # file:// 页面的 Origin 是字符串 "null"，必须显式加进去，否则本地预览会被拦。
    allow_origins=(config.cors_origins + ["null"]) if config.cors_origins else ["*"],
    allow_credentials=False,
    allow_methods=["*"],
    allow_headers=["*"],
)


@app.middleware("http")
async def enforce_api_token(request: Request, call_next):
    """可选的服务端鉴权（设了 `API_TOKEN` 才启用）。

    为什么需要：服务端监听 `0.0.0.0`，开启车控后**同一局域网内任何人都能
    POST /api/vehicle/command 解锁车辆**。项目文档只声明了"仅应在可信局域网
    内运行"，没有任何技术强制手段。这里补一道最低成本的防线。

    放行规则：
      - `API_TOKEN` 为空        → 完全不启用（保持默认行为，方便本地联调）
      - `/api/health`           → 始终放行（App 用它做连接诊断，不含敏感数据）
      - 非 `/api/*`             → 放行（`/preview`、`/docs`、静态资源）
      - 其余 `/api/*`           → 必须带 `Authorization: Bearer <token>`
                                   或 `?token=`（方便浏览器打开 /preview）

    用 `hmac.compare_digest` 做常量时间比较，避免时序侧信道。
    """
    required = config.api_token
    path = request.url.path

    if required and path.startswith("/api/") and path != "/api/health":
        provided = ""
        header = request.headers.get("authorization", "")
        if header.lower().startswith("bearer "):
            provided = header[7:].strip()
        if not provided:
            provided = request.query_params.get("token", "").strip()

        if not hmac.compare_digest(provided, required):
            return JSONResponse(
                status_code=401,
                content={
                    "detail": "服务端已启用 API 令牌鉴权，请在 App「设置」中填写令牌"
                },
            )
    elif path.startswith("/api/") and path != "/api/health":
        # 令牌为空时的兜底：只信任本机来源。
        # 为什么需要：API_TOKEN 留空是默认值、APP_HOST 默认 0.0.0.0 —— 也就是
        # "默认配置下同一局域网内任何人都能 DELETE /api/charges/records 清库、
        # POST /api/vehicle/command 解锁"。这里把空令牌的信任范围收回回环，
        # 不改变本机联调（含 iOS 模拟器）的使用方式。
        client_host = request.client.host if request.client else ""
        if not _is_loopback_client(client_host):
            return JSONResponse(
                status_code=403,
                headers={"access-control-allow-origin": "*"},
                content={
                    "detail": (
                        "服务端未设置 API_TOKEN，只接受本机访问。"
                        "若要在局域网内使用（如真机 App），请在 .env 里设置 API_TOKEN 后重启。"
                    )
                },
            )

    return await call_next(request)


@app.get("/api/health")
async def health() -> dict:
    """健康检查，供 iOS 端做连接诊断。"""
    from .adapters import is_mock

    return {
        "success": True,
        "data": {
            "status": "ok",
            "mode": "mock" if is_mock() else "live",
            "configured": config.zeekr.is_configured,
            "missingKeys": config.zeekr.missing_keys(),
            "allowCommands": config.allow_commands,
            "pollIntervalIdle": config.poll_interval_idle,
            "pollIntervalCharging": config.poll_interval_charging,
        },
    }


def register_routers() -> None:
    """注册各业务路由。"""
    from .api import auth, charges, location, stations, trips, vehicle

    app.include_router(vehicle.router, prefix="/api/vehicle", tags=["车辆"])
    # 位置单独挂一行：它是全项目唯一把车辆坐标发给第三方（腾讯地图）的出口，
    # 与车况接口的隐私性质不同，便于审计
    app.include_router(location.router, prefix="/api/vehicle", tags=["车辆位置"])
    app.include_router(trips.router, prefix="/api", tags=["行程"])
    app.include_router(charges.router, prefix="/api/charges", tags=["充电消费"])
    # 注意：`charges` 是**消费账单**域（本地导入的支付宝/微信账单），
    # 与「附近充电站」是两回事，故另开前缀而不是挂在 /api/charges 下。
    app.include_router(stations.router, prefix="/api/stations", tags=["附近充电站"])
    app.include_router(auth.router, prefix="/api/auth", tags=["认证"])


# 设计预览页位于**仓库根目录**的 preview/（server/ 的上一级）。
# 线上只部署 server/ 时这个目录根本不存在 —— 服务必须照常跑，不能把「有没有网页」
# 当成启动前提。故：根路径永远注册（无网页时返回一句 JSON 而不是 404），
# /preview 只在文件确实存在时才挂载。
PREVIEW_DIR = Path(__file__).resolve().parent.parent.parent / "preview"
PREVIEW_INDEX = PREVIEW_DIR / "index.html"


@app.get("/", include_in_schema=False)
async def root():
    """根路径：有预览页就跳过去（本机开发方便），纯后端部署返回服务信息。"""
    if PREVIEW_INDEX.is_file():
        from fastapi.responses import RedirectResponse

        return RedirectResponse(url="/preview")
    payload: dict[str, str] = {
        "service": "zeekrdash-api",
        "status": "ok",
        "health": "/api/health",
    }
    # 文档关了就别在服务信息里给个会 404 的链接（本机开发开着时才提示）。
    if config.api_docs_enabled:
        payload["docs"] = "/docs"
    return payload


def mount_preview() -> None:
    """挂载设计预览页（Safari / 浏览器可访问）。

    用于在没有 Mac 无法编译 iOS App 时，先验证界面设计与配色。
    预览页复用同一套接口，是原生版的「所见即所得」参照。
    **可选**：没有 preview/index.html（线上纯后端部署）就静默跳过，不影响 /api/*。
    """
    from fastapi.responses import FileResponse
    from fastapi.staticfiles import StaticFiles

    if not PREVIEW_INDEX.is_file():
        logger.info("未找到 %s，按纯后端模式运行（不挂载预览页）", PREVIEW_INDEX)
        return

    @app.get("/preview", include_in_schema=False)
    async def preview() -> FileResponse:
        return FileResponse(PREVIEW_INDEX)

    app.mount("/preview", StaticFiles(directory=PREVIEW_DIR), name="preview")
    logger.info("设计预览页已挂载：http://<服务地址>/preview")


register_routers()
mount_preview()
