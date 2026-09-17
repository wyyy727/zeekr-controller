"""行程与能耗接口。"""

from __future__ import annotations

import logging

from fastapi import APIRouter, HTTPException

from ..adapters import get_client

logger = logging.getLogger(__name__)

router = APIRouter()


@router.get("/trips")
async def get_trips(days: int = 30, vin: str | None = None) -> dict:
    """获取行程记录。

    策略：优先读本地库（快），库里没有则实时拉取并落库。
    """
    if not 1 <= days <= 365:
        raise HTTPException(status_code=400, detail="days 取值范围为 1–365")

    from ..main import store

    cached = store.list_trips(days=days)
    if cached:
        return {"success": True, "data": cached}

    client = get_client()
    try:
        trips = await client.get_trips(vin=vin, days=days)
    except Exception as exc:  # noqa: BLE001
        logger.error("获取行程失败：%s", exc)
        raise HTTPException(status_code=500, detail=f"获取行程失败：{exc}") from exc

    if trips:
        try:
            store.save_trips(trips)
        except Exception as exc:  # noqa: BLE001
            logger.warning("行程落库失败：%s", exc)

    return {"success": True, "data": trips}


@router.get("/energy/trend")
async def get_energy_trend(days: int = 30, vin: str | None = None) -> dict:
    """获取能耗趋势。"""
    if not 1 <= days <= 365:
        raise HTTPException(status_code=400, detail="days 取值范围为 1–365")

    client = get_client()
    try:
        trend = await client.get_energy_trend(vin=vin, days=days)
    except Exception as exc:  # noqa: BLE001
        logger.error("获取能耗趋势失败：%s", exc)
        raise HTTPException(status_code=500, detail=f"获取能耗趋势失败：{exc}") from exc

    return {"success": True, "data": trend}
