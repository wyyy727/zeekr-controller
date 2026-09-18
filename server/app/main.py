"""FastAPI 应用入口。"""

from __future__ import annotations

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

store = Store(config.database)


@asynccontextmanager
async def lifespan(app: FastAPI):
    """应用生命周期管理。"""
    logger.info("ZeekrDash 服务启动，端口 %s", config.port)
    if config.use_mock:
        logger.info("当前为模拟数据模式（未配置极氪账号或显式指定）")
    yield

    # 释放 HTTP 连接
    from .adapters import get_client
    from .adapters.live_client import LiveZeekrClient

    client = get_client()
    if isinstance(client, LiveZeekrClient):
        await client.aclose()
    logger.info("ZeekrDash 服务已停止")


app = FastAPI(
    title="ZeekrDash",
    description="极氪车主自建看板服务端",
    version="0.1.0",
    lifespan=lifespan,
)

# iOS App 直连本机服务；preview 页也可能从别的端口访问，故放开跨域。
#
# 注意不能用 allow_origins=["*"] 搭配 allow_credentials=True —— 两者在 CORS
# 规范里互斥（浏览器会直接拒绝该响应）。本服务不使用 Cookie，显式关掉
# credentials 即可，语义正确且不影响 iOS 原生请求。
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
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
    from .api import auth, charges, trips, vehicle

    app.include_router(vehicle.router, prefix="/api/vehicle", tags=["车辆"])
    app.include_router(trips.router, prefix="/api", tags=["行程"])
    app.include_router(charges.router, prefix="/api/charges", tags=["充电消费"])
    app.include_router(auth.router, prefix="/api/auth", tags=["认证"])


def mount_preview() -> None:
    """挂载设计预览页（Safari 可访问）。

    用于在没有 Mac 无法编译 iOS App 时，先验证界面设计与配色。
    预览页复用同一套接口，是原生版的「所见即所得」参照。
    """
    from fastapi.responses import FileResponse, RedirectResponse
    from fastapi.staticfiles import StaticFiles

    # 预览页位于项目根目录的 preview/（server/ 的上一级）
    preview_dir = Path(__file__).resolve().parent.parent.parent / "preview"
    index_file = preview_dir / "index.html"

    if not index_file.exists():
        logger.warning("预览页不存在，跳过挂载：%s", index_file)
        return

    @app.get("/", include_in_schema=False)
    async def root() -> RedirectResponse:
        return RedirectResponse(url="/preview")

    @app.get("/preview", include_in_schema=False)
    async def preview() -> FileResponse:
        return FileResponse(index_file)

    app.mount("/preview", StaticFiles(directory=preview_dir), name="preview")
    logger.info("设计预览页已挂载：http://<服务地址>/preview")


register_routers()
mount_preview()
