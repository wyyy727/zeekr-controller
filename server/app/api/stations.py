"""附近充电站接口。

数据来自**两跳、两套完全不同的认证体系**：

  1. 极氪 GW1 `…/bubble/charge/getListV2`  —— 坐标、枪数、运营商 logo
     （复用登录 JWT + `x_ca_*` 签名）
  2. 浩汉网关 `find/station/detail`          —— 站名、地址、评分、**电价**
     （只需一个 `channelId` 请求头，见 `adapters/haohan.py`）

**为什么合并放在服务端而不是让前端直连两个网关**：
跳 1 需要极氪 JWT 与签名，跳 2 需要渠道号 —— 两者都不该下放到浏览器；
更重要的是**用户坐标只应发给极氪自己的网关**，绝不能出现在发给第三方的请求里
（浩汉侧只收 `stationId`）。

**降级是本模块的核心设计**：浩汉不可用时列表照常返回（只是没有站名与价格），
比整页失败好得多 —— 用户至少还能看到"哪个站最近、还剩几个空枪"。
"""

from __future__ import annotations

import asyncio
import logging
import math
import time
from typing import Any

from fastapi import APIRouter, HTTPException, Query

from ..adapters import get_client, is_mock
from ..adapters.haohan import HaohanClient, map_price, map_station_info
from ..core.config import config
from . import fail

logger = logging.getLogger(__name__)

router = APIRouter()

# 站点列表缓存时长（秒）。地图类数据不需要秒级新鲜度，而两侧网关的限流阈值
# 都未知 —— 缓存是这里唯一的风控手段，不是可选优化。
CACHE_TTL = 300.0
# 并发取价上限。实测 8 并发不触发风控，这里再保守一档。
PRICE_CONCURRENCY = 6
# 缓存条目上限，防止长时间运行后无界增长
CACHE_MAX_ENTRIES = 256
# 单次请求最多对多少个站点取价（按距离取最近的这些）
PRICE_BATCH_DEFAULT = 20

_station_cache: dict[str, tuple[float, list[dict[str, Any]]]] = {}
_price_cache: dict[str, tuple[float, dict[str, Any]]] = {}
_haohan: HaohanClient | None = None


def _haohan_client() -> HaohanClient:
    """浩汉客户端单例（惰性创建）。

    单独持有而不塞进 `LiveZeekrClient`：两者认证体系无关，
    放一起会让"极氪改了签名"波及"充电站还能不能看价格"。
    """
    global _haohan
    if _haohan is None:
        _haohan = HaohanClient(host=config.haohan_host, channel_id=config.haohan_channel_id)
    return _haohan


def _cache_get(
    cache: dict[str, tuple[float, Any]], key: str
) -> Any | None:
    """读缓存；过期即删。返回 None 表示未命中。"""
    hit = cache.get(key)
    if hit is None:
        return None
    expires_at, value = hit
    if expires_at < time.time():
        cache.pop(key, None)
        return None
    return value


def _cache_put(cache: dict[str, tuple[float, Any]], key: str, value: Any) -> None:
    """写缓存，并在超限时先清过期项、再按到期时间淘汰一批。"""
    if len(cache) >= CACHE_MAX_ENTRIES:
        now = time.time()
        for stale in [k for k, (expires_at, _) in cache.items() if expires_at < now]:
            cache.pop(stale, None)
        if len(cache) >= CACHE_MAX_ENTRIES:
            # 仍满：丢掉最早到期的那四分之一，避免这里变成内存泄漏点
            for old in sorted(cache, key=lambda k: cache[k][0])[: CACHE_MAX_ENTRIES // 4]:
                cache.pop(old, None)
    cache[key] = (time.time() + CACHE_TTL, value)


def _haversine_km(lat1: float, lng1: float, lat2: float, lng2: float) -> float:
    """球面距离（km）。

    必须自己算：气泡接口**没有** distance 字段，返回顺序也不保证按距离
    （实测 680 条是按图层顺序给的）。
    """
    earth_radius = 6371.0
    phi1, phi2 = math.radians(lat1), math.radians(lat2)
    d_phi = math.radians(lat2 - lat1)
    d_lambda = math.radians(lng2 - lng1)
    a = math.sin(d_phi / 2) ** 2 + math.cos(phi1) * math.cos(phi2) * math.sin(d_lambda / 2) ** 2
    return 2 * earth_radius * math.asin(math.sqrt(a))


async def _load_stations(lat: float, lng: float) -> list[dict[str, Any]]:
    """取附近站点（带缓存）。

    缓存键用 3 位小数的坐标网格（≈100m）—— 用户在地图上小幅移动时
    不至于每次都重新打一遍网关。
    """
    key = f"{lat:.3f},{lng:.3f}"
    cached = _cache_get(_station_cache, key)
    if cached is not None:
        return cached

    stations = await get_client().get_nearby_stations(lat, lng)
    _cache_put(_station_cache, key, stations)
    return stations


async def _enrich(stations: list[dict[str, Any]]) -> bool:
    """给站点补上站名、地址、评分与电价；返回 "价格是否可用"。

    模拟数据源自带这些字段，直接跳过 —— 不然演示环境会变成"必须联网
    且要能连上第三方网关"，那本地开发就没法做了。
    """
    if is_mock():
        return all(item.get("price") for item in stations)

    client = _haohan_client()
    semaphore = asyncio.Semaphore(PRICE_CONCURRENCY)
    price_ok = False

    async def enrich_one(item: dict[str, Any]) -> None:
        nonlocal price_ok
        station_id = item.get("stationId") or ""
        if not station_id:
            return

        detail = _cache_get(_price_cache, station_id)
        if detail is None:
            async with semaphore:
                detail = await client.get_station_detail(station_id)
            # 只缓存成功结果：把 None 也缓存进去，会让一次偶发失败
            # 在接下来五分钟里持续表现为"这个站没有价格"。
            if detail is not None:
                _cache_put(_price_cache, station_id, detail)
        if detail is None:
            return

        item.update(map_station_info(detail))
        item["price"] = map_price(detail)
        price_ok = True

    # 单个站点失败不影响其他站点，所以用 gather(return_exceptions=True) +
    # 内部吞异常的双保险：这里宁可少一格数据，也不能让一个坏站点拖垮整页。
    await asyncio.gather(*(enrich_one(item) for item in stations), return_exceptions=True)
    return price_ok


@router.get("/nearby")
async def get_nearby(
    lat: float = Query(..., ge=-90, le=90, description="纬度"),
    lng: float = Query(..., ge=-180, le=180, description="经度"),
    limit: int = Query(PRICE_BATCH_DEFAULT, ge=1, le=50, description="本页返回站点数上限"),
    offset: int = Query(0, ge=0, description="跳过前 N 个（滑动分页用）"),
) -> dict:
    """附近充电站（距离升序，含电价与分时电价表）。

    **分页**：极氪气泡接口一次就把视野内的站点全给了（它自己不分页），
    所以"翻页"是在服务端对排好序的列表做切片。这样做还有一个实际好处：
    取价格是按站请求浩汉的，首屏只要 limit=10 就比一次拉 20 个快一倍 ——
    而用户很可能只看得下前几个。

    `total` 是**视野内总数**（切片前），`count` 是本页条数。
    前端据此判断还有没有下一页：`offset + count < total`。

    **坐标不会被转发给第三方网关**：发给极氪的是坐标（本来就是它家的数据），
    发给浩汉的只有 `stationId`。这条边界是刻意的，改动时请保留。
    """
    t0 = time.perf_counter()
    try:
        stations = await _load_stations(lat, lng)
    except Exception as exc:  # noqa: BLE001 - 统一转 HTTP 错误，不回显原始报文
        fail("获取附近充电站失败，请检查登录状态与服务端日志", exc)
    t1 = time.perf_counter()

    # 补距离：坐标缺失的站点直接剔除（没有坐标既排不了序也导航不了）
    located: list[dict[str, Any]] = []
    for item in stations:
        item_lat, item_lng = item.get("lat"), item.get("lng")
        if not isinstance(item_lat, (int, float)) or not isinstance(item_lng, (int, float)):
            continue
        item["distanceKm"] = round(_haversine_km(lat, lng, item_lat, item_lng), 2)
        located.append(item)

    located.sort(key=lambda item: item["distanceKm"])
    total = len(located)
    picked = located[offset : offset + limit]

    price_available = await _enrich(picked)
    t2 = time.perf_counter()

    # 慢的时候要能一眼看出慢在哪一段：列表（极氪一跳）还是取价（逐站问浩汉）。
    # 只记耗时与条数，不记坐标。
    logger.debug(
        "附近充电站：列表 %.0fms + 取价 %.0fms（本页 %d / 共 %d 站）",
        (t1 - t0) * 1000,
        (t2 - t1) * 1000,
        len(picked),
        total,
    )

    # 取价后按距离重排即可（价格不参与排序，排序由前端决定）
    return {
        "success": True,
        "data": {
            "location": {"lat": lat, "lng": lng},
            "total": total,
            "offset": offset,
            "count": len(picked),
            # False ⇒ 第三方价格服务不可用；前端应提示"价格暂不可用"，
            # 而不是把空价格当成"这个站免费"。
            "priceAvailable": price_available,
            "stations": picked,
        },
    }


@router.get("/station/{station_id}")
async def get_station(station_id: str) -> dict:
    """单个站点详情（价格 + 实时动态）。

    从列表点进详情时用；`stationId` 来自 `/nearby` 的返回。
    """
    if is_mock():
        stations = await get_client().get_nearby_stations(31.2304, 121.4737)
        hit = next((s for s in stations if s.get("stationId") == station_id), None)
        if hit is None:
            raise HTTPException(status_code=404, detail="站点不存在")
        return {"success": True, "data": {"station": hit, "dynamic": None}}

    client = _haohan_client()
    detail = await client.get_station_detail(station_id)
    if detail is None:
        raise HTTPException(status_code=502, detail="获取站点详情失败")

    return {
        "success": True,
        "data": {
            "station": {
                "stationId": station_id,
                **map_station_info(detail),
                "price": map_price(detail),
            },
            "dynamic": await client.get_station_dynamic(station_id),
        },
    }
