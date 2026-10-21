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

# 带"价格类"筛选（电价上限 / 停车免费）时，单次请求最多**扫描**多少个候选站点。
#
# 为什么需要这个上限：枪数、是否自营来自极氪气泡接口，判断成本为零；
# 而电价与停车费只能逐站问浩汉。若为了筛"1.2 元以下"去扫全部候选，
# 视野里几十上百个站会变成几十上百次第三方请求 —— 那是明确的风控红线。
# 30 个 ≈ 最近 5~10 km，已经覆盖绝大多数使用场景；
# 更远的站按"距离优先"分批滚动，翻页时接着扫，不会漏。
PRICE_SCAN_MAX = 30

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


def _passes_basic(
    item: dict[str, Any], connector: str | None, self_only: bool
) -> bool:
    """只靠极氪气泡字段就能判定的筛选（零请求成本）。

    这些条件必须在**切片之前**过滤，否则"第 2 页里混进一堆不符合条件的站"，
    用户会以为筛选没生效。价格类条件做不到这一步（要先问浩汉），见 `_passes_price`。
    """
    if connector == "dc" and not (item.get("dcCount") or 0):
        return False
    if connector == "ac" and not (item.get("acCount") or 0):
        return False
    if self_only and not item.get("selfOperate"):
        return False
    return True


def _passes_price(
    item: dict[str, Any], max_price: float | None, park_free: bool
) -> bool:
    """价格类筛选（需要先取到浩汉的电价与停车费）。

    **没有价格一律判为不通过** —— 用户明确要"低于 X 元"，
    一个查不到价格的站不满足这个条件。这与"价格缺失不等于免费"是同一条原则：
    拿不到就不猜。
    """
    if max_price is None and not park_free:
        return True

    price = item.get("price") or {}
    if max_price is not None:
        total = price.get("totalPrice")
        if not isinstance(total, (int, float)) or total > max_price:
            return False
    if park_free and price.get("parkFree") is not True:
        return False
    return True


@router.get("/nearby")
async def get_nearby(
    lat: float = Query(..., ge=-90, le=90, description="纬度"),
    lng: float = Query(..., ge=-180, le=180, description="经度"),
    limit: int = Query(PRICE_BATCH_DEFAULT, ge=1, le=50, description="本页返回站点数上限"),
    offset: int = Query(0, ge=0, description="从第几个候选开始（滑动分页用）"),
    connector: str | None = Query(
        None, pattern="^(dc|ac)$", description="只看快充 dc / 慢充 ac（不传＝不限）"
    ),
    self_only: bool = Query(False, description="只看极氪自营"),
    max_price: float | None = Query(
        None, gt=0, le=20, description="只看当前总价不高于该值（元/度）"
    ),
    park_free: bool = Query(False, description="只看停车免费"),
) -> dict:
    """附近充电站（距离升序，含电价与分时电价表）。

    **分页**：极氪气泡接口一次就把视野内的站点全给了（它自己不分页），
    所以"翻页"是在服务端对排好序的列表做切片。这样做还有一个实际好处：
    取价格是按站请求浩汉的，首屏只要 limit=10 就比一次拉 20 个快一倍 ——
    而用户很可能只看得下前几个。

    **筛选分两类，别混在一起看**：
    · 枪型（`connector`）、自营（`self_only`）来自气泡接口，零成本，
      在切片**之前**过滤 ⇒ `total` 就是筛选后的真实条数；
    · 电价（`max_price`）、停车（`park_free`）必须先取价才知道，
      只能在切片后逐批取价再筛，并受 `PRICE_SCAN_MAX` 限制扫描范围。
      此时 `total` 仍表示"零成本筛选后的候选数"，**不是**符合条件的总数，
      所以响应里带 `priceFilterApplied` 让前端别把 total 当匹配数显示。

    `nextOffset` 是下一次分页该传的 offset（带价格筛选时它会**大于**
    `offset + count`，因为中间扫描掉的候选不返回）。前端只该用它翻页，
    不要自己用 `count` 推算。

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

    # 零成本的筛选先做掉 —— 后面所有口径（total / 翻页）都建立在这个候选集上
    candidates = [i for i in located if _passes_basic(i, connector, self_only)]
    total = len(candidates)

    needs_price = max_price is not None or park_free
    price_available = False

    if not needs_price:
        picked = candidates[offset : offset + limit]
        price_available = await _enrich(picked)
        next_offset = offset + len(picked)
    else:
        # 逐批取价 + 筛选，直到凑满一页或扫到上限。
        # `consumed` 只算**真正看过**的候选 —— 凑满一页就停时可以留几只在
        # 本批未看的位置，下一轮从那里接着来，既不重复也不漏。
        picked = []
        cursor = offset
        scan_end = min(total, offset + PRICE_SCAN_MAX)
        while cursor < scan_end and len(picked) < limit:
            batch = candidates[cursor:cursor + limit]
            if not batch:
                break
            ok = await _enrich(batch)
            price_available = price_available or ok
            consumed = 0
            for item in batch:
                consumed += 1
                if _passes_price(item, max_price, park_free):
                    picked.append(item)
                    if len(picked) >= limit:
                        break
            cursor += consumed
        next_offset = cursor

    has_more = next_offset < total
    t2 = time.perf_counter()

    # 慢的时候要能一眼看出慢在哪一段：列表（极氪一跳）还是取价（逐站问浩汉）。
    # 只记耗时与条数，不记坐标。
    logger.debug(
        "附近充电站：列表 %.0fms + 取价 %.0fms（本页 %d / 候选 %d，筛选=%s）",
        (t1 - t0) * 1000,
        (t2 - t1) * 1000,
        len(picked),
        total,
        ",".join(
            [x for x in (connector, "self" if self_only else "",
                         "price" if max_price is not None else "",
                         "parkFree" if park_free else "") if x]
        ) or "无",
    )

    # 取价后按距离重排即可（价格不参与排序，排序由前端决定）
    return {
        "success": True,
        "data": {
            "location": {"lat": lat, "lng": lng},
            "total": total,
            "offset": offset,
            # 下一页该从哪开始（带价格筛选时会跳过被扫描掉的候选）
            "nextOffset": next_offset,
            "hasMore": has_more,
            "count": len(picked),
            # False ⇒ 第三方价格服务不可用；前端应提示"价格暂不可用"，
            # 而不是把空价格当成"这个站免费"。
            "priceAvailable": price_available,
            # True ⇒ 用了价格类筛选，此时 total 只是候选数，不是匹配总数
            "priceFilterApplied": needs_price,
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
