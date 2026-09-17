"""FastAPI 应用入口。"""

from __future__ import annotations

import logging
from contextlib import asynccontextmanager
from pathlib import Path

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

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

# iOS App 直连本机服务，允许跨域
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


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
