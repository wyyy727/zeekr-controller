"""车辆位置接口：经纬度 + 地址 + 静态地图缩略图。

为什么单独一个模块而不是塞进 `vehicle.py`：这里的两个接口都会**把车辆坐标
发给第三方（腾讯位置服务）**，是全项目唯一的对外坐标出口，把隐私边界
集中在一个文件里，比散落在车况接口里更容易守住。

设计要点：

1. **坐标不出现在 URL 里**。前端不传 lat/lng，由后端自己向极氪网关取 ——
   uvicorn 的 access log 会记录完整 URL，坐标若走 query 就等于进了日志。
2. **位置卡与地图图共享一份 60 秒缓存**。两者会先后请求同一坐标，
   不缓存就等于每刷一次页面打两次车况接口（还多一次腾讯调用）。
3. **没有 key 就明确降级**，不假装有地址。`mapAvailable` 告诉前端
   "图可以请求"，但取图失败仍要能退回纯文字。
"""

from __future__ import annotations

import logging
import time
from pathlib import Path
from typing import Any

from fastapi import APIRouter, Response

from ..adapters import get_client
from ..adapters.tencent_map import get_map_client
from ..core.config import DATA_DIR
from . import fail

logger = logging.getLogger(__name__)

router = APIRouter()

# 地图图片落盘缓存：坐标不变就不该反复向腾讯请求（既省额度，也少一次位置外发）。
# ⚠️ 文件名里含坐标，目录在 server/data/ 下（.gitignore 已覆盖），属个人位置数据。
_MAP_CACHE_DIR = DATA_DIR / "mapcache"
# 上限 20 张（约 12MB）。淘汰只在写入后检查、按 mtime 删最旧的（见 _store_map）。
# 为什么是 20 而不是更大：文件名自带坐标，留得越多 = 磁盘上残留的位置轨迹越久；
# 实际会反复命中的只有"当前停车点"这几个坐标，一次路过的位置基本不会再回来。
_MAP_CACHE_MAX = 20

# 位置卡与缩略图共用：60 秒内不重复打车况接口
_POSITION_TTL = 60
# 缓存必须**按 vin 分开**：否则 60 秒内先查 A 车再看 B 车，B 会拿到 A 的坐标
# （接口暴露了 `?vin=`，多车场景一用就串）。
_position_cache: dict[str, Any] = {"at": 0.0, "data": None, "vin": ""}


def reset_position_cache() -> None:
    """测试用。"""
    _position_cache["at"] = 0.0
    _position_cache["data"] = None
    _position_cache["vin"] = ""


def coord_key(lat: float, lng: float, digits: int = 5) -> str:
    """坐标 → 缓存键。

    5 位小数 ≈ 1 米：车静止时实测坐标连 6 位都完全一致，5 位足够命中，
    又能容忍轻微的定位抖动。**不要**把精度降到 3 位以下 —— 那会让
    相邻两个地点的地址互相串。
    """
    return f"{lat:.{digits}f},{lng:.{digits}f}"


async def _address_for(lat: float, lng: float) -> tuple[dict[str, Any] | None, bool]:
    """取地址，返回 (地址, 是否来自本地缓存)。

    缓存优先的意义不只是省额度 —— **坐标不变就完全不向腾讯发请求**，
    这是这个功能里唯一能实实在在减少隐私外发的办法。
    """
    map_client = get_map_client()
    if not map_client.available:
        return None, False

    key = coord_key(lat, lng)

    # ① 先查库（跨重启有效：车停几天不动，就只查一次）
    cached: dict[str, Any] | None = None
    try:
        from ..main import store

        cached = store.get_geocode(key)
    except Exception as exc:  # noqa: BLE001 - 缓存故障不该让位置卡失败
        logger.debug("读取地址缓存失败：%s", exc)

    if cached and cached.get("address"):
        return cached, True

    # ② 未命中才请求
    data = await map_client.reverse_geocode(lat, lng)
    if data and data.get("address"):
        try:
            from ..main import store

            store.save_geocode(key, data)
        except Exception as exc:  # noqa: BLE001
            logger.debug("写入地址缓存失败：%s", exc)

    return data, False


async def _current_position(vin: str | None) -> dict[str, Any]:
    """取「最后一次上报的位置」。

    注意用词：这不是实时位置 —— 车静止时网关不更新坐标（实测 15 条快照
    只有 3 个位置点），所以 `reportedAt` 必须一并返回，界面要显示出来。
    """
    now = time.time()
    key = vin or ""
    cached = _position_cache["data"]
    if (
        cached is not None
        and _position_cache["vin"] == key
        and now - _position_cache["at"] < _POSITION_TTL
    ):
        return cached

    client = get_client()
    try:
        status = await client.get_vehicle_status(vin=vin)
    except Exception as exc:  # noqa: BLE001
        # 不回显原始异常：网关报文可能含令牌片段
        fail("获取车辆位置失败，请检查服务端登录状态", exc)

    lat = status.get("latitude")
    lng = status.get("longitude")
    data: dict[str, Any] = {
        "available": lat is not None and lng is not None,
        "lat": lat,
        "lng": lng,
        # 车上报时间，不是服务端抓取时间 —— 两者可能差几十分钟
        "reportedAt": status.get("lastUpdateTs"),
    }
    if not data["available"]:
        data["reason"] = "车辆尚未上报位置"

    _position_cache.update(at=now, data=data, vin=key)
    return data


@router.get("/location")
async def get_location(vin: str | None = None) -> dict:
    """车辆位置（坐标 + 地址）。未配置腾讯 key 时 address 为 None。"""
    position = await _current_position(vin)
    if not position["available"]:
        return {"success": True, "data": {**position, "mapAvailable": False}}

    map_client = get_map_client()
    address = None
    from_cache = False
    if map_client.available:
        address, from_cache = await _address_for(position["lat"], position["lng"])

    return {
        "success": True,
        "data": {
            **position,
            "address": address,
            # 有 key 才让前端去请求图片；取图失败时前端还要能退回纯文字
            "mapAvailable": map_client.available,
            # 这次地址是否来自本地缓存（true = 没有把坐标发给腾讯）
            "addressFromCache": from_cache,
        },
    }


@router.get("/weather")
async def get_weather(vin: str | None = None) -> dict:
    """车辆所在地的实时天气 —— 界面上标的是**「当地气温」，不是车外实测温度**。

    为什么要有这个接口：车端 `climateStatus.exteriorTemp` 实测恒为空
    （非空率 0/15，这版固件根本不上报），"车外温度"这个数只能按位置查天气。
    日常两者基本一致，差别只在暴晒 / 地下车库这类极端场景。

    坐标**不出现在本接口的入参里**：由服务端向极氪取，与 `/location` 共用
    同一份 60 秒缓存，所以多一个接口不会多外发一次位置。
    查询失败一律返回 `available: false`（不是 500）—— 温度缺失只是少一个数字，
    不该让整页弹错误。
    """
    position = await _current_position(vin)
    if not position["available"]:
        return {
            "success": True,
            "data": {"available": False, "reason": "车辆尚未上报位置"},
        }

    map_client = get_map_client()
    if not map_client.available:
        return {
            "success": True,
            "data": {"available": False, "reason": "未配置 TENCENT_MAP_KEY"},
        }

    weather = await map_client.weather(position["lat"], position["lng"])
    if weather is None:
        return {
            "success": True,
            "data": {"available": False, "reason": "天气查询失败"},
        }

    return {"success": True, "data": {"available": True, **weather}}


@router.get("/location/map.png")
async def get_location_map(
    vin: str | None = None,
    width: int = 640,
    height: int = 280,
    zoom: int = 16,
) -> Response:
    """静态地图缩略图。

    返回 404 而不是一张占位图：前端 `<img onerror>` 直接隐藏即可，
    比后端生成"地图加载失败"的假图片更省事，也不会让人误以为是真地图。
    """
    position = await _current_position(vin)
    if not position["available"]:
        return Response(status_code=404)

    map_client = get_map_client()
    if not map_client.available:
        logger.debug("未配置 TENCENT_MAP_KEY，跳过静态图请求")
        return Response(status_code=404)

    # 先看磁盘：同一个坐标、同一组尺寸参数，图片不会变
    cached = _cached_map(position["lat"], position["lng"], width, height, zoom)
    if cached is not None:
        path, media_type = cached
        return Response(
            content=path.read_bytes(),
            media_type=media_type,
            headers={"Cache-Control": "private, max-age=86400", "X-Map-Cache": "hit"},
        )

    image = await map_client.static_map(
        position["lat"], position["lng"], width=width, height=height, zoom=zoom
    )
    if image is None:
        return Response(status_code=404)

    body, content_type = image
    _store_map(position["lat"], position["lng"], width, height, zoom, body, content_type)

    return Response(
        content=body,
        media_type=content_type,
        # 坐标不变时图片也不会变，让浏览器自己缓存，省腾讯的调用额度
        headers={"Cache-Control": "private, max-age=600", "X-Map-Cache": "miss"},
    )


def _map_stem(lat: float, lng: float, width: int, height: int, zoom: int) -> str:
    """文件名：坐标 + 尺寸 + 缩放。坐标里的点与逗号换成文件系统安全字符。"""
    key = coord_key(lat, lng, digits=6).replace(",", "_").replace(".", "p").replace("-", "m")
    return f"{key}_{width}x{height}_z{zoom}"


def _cached_map(
    lat: float, lng: float, width: int, height: int, zoom: int
) -> tuple[Path, str] | None:
    """命中磁盘缓存则返回 (路径, MIME)。腾讯可能返回 png 也可能 jpeg。"""
    stem = _map_stem(lat, lng, width, height, zoom)
    for ext, media_type in (("png", "image/png"), ("jpg", "image/jpeg")):
        path = _MAP_CACHE_DIR / f"{stem}.{ext}"
        if path.exists() and path.stat().st_size > 0:
            return path, media_type
    return None


def _store_map(
    lat: float,
    lng: float,
    width: int,
    height: int,
    zoom: int,
    body: bytes,
    content_type: str,
) -> None:
    """落盘。写失败只记 debug —— 缓存坏了最多多请求一次，不该影响出图。"""
    try:
        _MAP_CACHE_DIR.mkdir(parents=True, exist_ok=True)
        ext = "png" if "png" in content_type.lower() else "jpg"
        path = _MAP_CACHE_DIR / f"{_map_stem(lat, lng, width, height, zoom)}.{ext}"
        path.write_bytes(body)

        # 简单上限：超出就删**最旧**的几张（按 mtime，不是按文件名 ——
        # 文件名是坐标串，按它排序删掉的不是最旧的那张，会反复删错、反复回源）
        files = sorted(
            list(_MAP_CACHE_DIR.glob("*.png")) + list(_MAP_CACHE_DIR.glob("*.jpg")),
            key=lambda p: p.stat().st_mtime,
        )
        if len(files) > _MAP_CACHE_MAX:
            for old in files[: len(files) - _MAP_CACHE_MAX]:
                old.unlink(missing_ok=True)
    except Exception as exc:  # noqa: BLE001
        logger.debug("写入地图缓存失败：%s", exc)
