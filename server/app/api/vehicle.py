"""车辆状态与车控接口。"""

from __future__ import annotations

import logging
from typing import Any

from fastapi import APIRouter
from pydantic import BaseModel, Field

from ..adapters import get_client
from ..core.config import config
from . import fail

logger = logging.getLogger(__name__)

router = APIRouter()


class CommandRequest(BaseModel):
    """车控指令请求。"""

    command: str = Field(..., description="指令名，如 lock / unlock / climateOn")
    params: dict[str, Any] | None = Field(default=None, description="可选参数")
    vin: str | None = Field(default=None, description="目标车辆 VIN")


@router.get("/status")
async def get_status(vin: str | None = None) -> dict:
    """获取车辆实时状态。"""
    client = get_client()
    try:
        status = await client.get_vehicle_status(vin=vin)
    except Exception as exc:  # noqa: BLE001 - 统一转为 HTTP 错误
        # 不回显原始异常：网关报文可能含令牌片段
        fail("获取车辆状态失败，请检查服务端日志与登录状态", exc)

    # 补齐车辆信息（状态接口在某些网关下不返回昵称/车牌）
    try:
        vehicles = await client.list_vehicles()
        if vehicles:
            meta = next((v for v in vehicles if v.get("vin") == status.get("vin")), vehicles[0])
            for key in ("nickname", "plateNo", "modelName"):
                if not status.get(key) or status.get(key) == "极氪 001":
                    status[key] = meta.get(key) or status.get(key)
    except Exception as exc:  # noqa: BLE001
        logger.debug("补齐车辆信息失败（不影响状态）：%s", exc)

    # 落库一条快照，便于回溯电量曲线
    try:
        from ..main import store
        store.save_snapshot(status)
    except Exception as exc:  # noqa: BLE001
        logger.debug("保存快照失败：%s", exc)

    return {"success": True, "data": status}


@router.get("/list")
async def list_vehicles() -> dict:
    """获取车辆列表。"""
    client = get_client()
    try:
        vehicles = await client.list_vehicles()
    except Exception as exc:  # noqa: BLE001
        # 不回显原始异常：网关报文可能含令牌片段
        fail("获取车辆列表失败，请检查服务端日志", exc)

    return {"success": True, "data": vehicles}


@router.post("/command")
async def send_command(payload: CommandRequest) -> dict:
    """下发车控指令。

    安全约束：需在服务端配置 `ALLOW_COMMANDS=true` 才允许下发，
    默认关闭 —— 避免误操作。
    """
    if not config.allow_commands:
        return {
            "success": False,
            "error": "服务端未开启车控指令开关（设置 ALLOW_COMMANDS=true 后重启）",
            "data": {"success": False, "message": "车控指令已禁用", "command": payload.command},
        }

    client = get_client()
    try:
        result = await client.send_command(
            command=payload.command,
            params=payload.params,
            vin=payload.vin,
        )
    except Exception as exc:  # noqa: BLE001
        # 不回显原始异常：网关报文可能含令牌片段
        fail("下发指令失败，请检查服务端日志", exc)

    success = bool(result.get("success"))
    return {
        "success": success,
        "data": result,
        "error": None if success else result.get("message"),
    }


@router.get("/snapshots")
async def get_snapshots(vin: str, limit: int = 200) -> dict:
    """获取电量历史快照。"""
    from ..main import store

    return {"success": True, "data": store.list_snapshots(vin=vin, limit=limit)}
