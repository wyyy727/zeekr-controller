"""行程与能耗接口。"""

from __future__ import annotations

import logging
import time

from fastapi import APIRouter, HTTPException

from ..adapters import get_client
from . import fail

logger = logging.getLogger(__name__)

router = APIRouter()

# 行程缓存有效期（秒）。
#
# 历史缺陷：`if cached: return cached` 意味着只要库里**有过**数据，就永远
# 不再回源 —— 新行程再也进不来，用户看到的是永远停在第一次拉取那天的列表。
# 现在缓存只保证「短时间内不重复打网关」，超过 TTL 仍会回源刷新。
TRIPS_CACHE_TTL_SEC = 300

# 进程内记录各缓存键的上次刷新时刻（keys: f"{vin}:{days}"）。
# 单进程自用场景够用；多进程部署时应改为落库的时间戳。
_last_refresh: dict[str, float] = {}


def _cache_key(vin: str | None, days: int) -> str:
    return f"{vin or '-'}:{days}"


def _is_cache_fresh(vin: str | None, days: int) -> bool:
    """缓存是否仍在 TTL 内。"""
    stamped = _last_refresh.get(_cache_key(vin, days))
    if stamped is None:
        return False
    return (time.monotonic() - stamped) < TRIPS_CACHE_TTL_SEC


@router.get("/trips")
async def get_trips(
    days: int = 30,
    vin: str | None = None,
    # 默认值用裸 False 而非 Query(False)：Query(...) 返回的是 FieldInfo 对象，
    # 直接调用函数时它是真值，会让 `not force` 永远为假、缓存判定被短路跳过。
    force: bool = False,
) -> dict:
    """获取行程记录。

    策略：TTL 内直接用本地库（快）；缓存过期或 `force=true` 时回源刷新并落库。
    网关失败时降级返回已有缓存，而不是把空结果糊给用户。
    """
    if not 1 <= days <= 365:
        raise HTTPException(status_code=400, detail="days 取值范围为 1–365")

    from ..main import store

    cached = store.list_trips(days=days)
    if cached and not force and _is_cache_fresh(vin, days):
        return {"success": True, "data": cached, "cached": True}

    client = get_client()
    try:
        trips = await client.get_trips(vin=vin, days=days)
    except Exception as exc:  # noqa: BLE001
        logger.error("获取行程失败：%s", exc)
        if cached:
            # 回源失败但有旧数据 —— 降级返回旧数据，好过直接报错
            logger.warning("回源失败，降级返回 %d 条缓存行程", len(cached))
            return {"success": True, "data": cached, "cached": True, "stale": True}
        # 不回显原始异常：网关报文可能含令牌片段
        fail("获取行程失败，请检查服务端日志与登录状态", exc)

    if trips:
        try:
            store.save_trips(trips)
        except Exception as exc:  # noqa: BLE001
            logger.warning("行程落库失败：%s", exc)

    # 无论本次是否拿到新数据，都记一次刷新时刻，避免网关异常时被打爆
    _last_refresh[_cache_key(vin, days)] = time.monotonic()

    return {"success": True, "data": trips or cached}


@router.get("/energy/trend")
async def get_energy_trend(days: int = 30, vin: str | None = None) -> dict:
    """获取能耗趋势。"""
    if not 1 <= days <= 365:
        raise HTTPException(status_code=400, detail="days 取值范围为 1–365")

    client = get_client()
    try:
        trend = await client.get_energy_trend(vin=vin, days=days)
    except Exception as exc:  # noqa: BLE001
        # 不回显原始异常：网关报文可能含令牌片段
        fail("获取能耗趋势失败，请检查服务端日志与登录状态", exc)

    return {"success": True, "data": trend}
