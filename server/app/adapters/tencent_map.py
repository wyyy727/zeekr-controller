"""腾讯位置服务接入层（车辆位置卡：逆地理编码 + 静态地图）。

**为什么需要这一层**：车坐标来自极氪网关，是**裸经纬度**（6 位小数），
对人没有意义。要变成「上海市浦东新区XX路XX号」或者一张地图缩略图，
必须调用合规的地图服务。

**为什么是腾讯而不是 Apple 地图**：中国大陆的地图展示只能用腾讯/高德/百度/天地图，
Apple Maps 属禁止清单 —— 所以 iOS 端也**不能用 MapKit**，两端共用同一套后端。

**为什么 key 只在服务端**：腾讯静态图的常规用法是前端直接拼 URL（`<img src="...&key=..."`），
那等于把 key 公开在 HTML 里。这里改成后端代发、只向前端吐图片字节与地址文本，
key 留在 `.env`，前端一辈子看不到它。

坐标系统一：腾讯 webService 内地就是 **GCJ-02**，与极氪返回的坐标同系，**不要做任何转换**
（转了反而会偏几百米）。

**隐私边界（重要，勿破坏）**：这是全项目唯一把「车在哪」发给第三方的地方，
用户已明确知情同意。因此：
  · 日志里绝不打印坐标与地址（只打状态码与耗时）；
  · 不要把坐标写进任何会被 git 跟踪的文件。
"""

from __future__ import annotations

import logging
import time
from typing import Any

import httpx

logger = logging.getLogger(__name__)

GEOCODER_URL = "https://apis.map.qq.com/ws/geocoder/v1/"
STATICMAP_URL = "https://apis.map.qq.com/ws/staticmap/v2/"
WEATHER_URL = "https://apis.map.qq.com/ws/weather/v1/"

TIMEOUT = 10.0

# 腾讯的成功码是 `status == 0`（注意与极氪的六位 `000000`、浩汉的四位 `0000` 都不同）
STATUS_OK = 0

# 缓存策略：坐标是「最后上报点」，静止时不会变，而腾讯个人 key 有日调用量限制。
# 地址按 5 位小数（≈1 米）归并，10 分钟有效；图片按参数缓存，只留少量条目。
_ADDRESS_TTL = 600
_IMAGE_TTL = 600
_MAX_IMAGE_ENTRIES = 12
# 天气官方约 10 分钟更新一次，缓存比它略短即可；个人 key 的天气调用量有限，
# 页面上每次刷新都打一遍纯属浪费（还要多外发一次坐标）。
_WEATHER_TTL = 300


def _grid(value: float | None, digits: int = 5) -> str:
    """坐标归并成缓存键。None 保持为 '-'，避免把缺失值当成 0。"""
    return "-" if value is None else f"{value:.{digits}f}"


class TencentMapClient:
    """逆地理编码与静态图。任何失败都返回 `None`，降级交给上层。"""

    def __init__(self, key: str = "") -> None:
        self._key = (key or "").strip()
        self._address_cache: dict[str, tuple[float, dict[str, Any] | None]] = {}
        self._image_cache: dict[str, tuple[float, tuple[bytes, str] | None]] = {}
        self._weather_cache: dict[str, tuple[float, dict[str, Any] | None]] = {}

    @property
    def available(self) -> bool:
        """未配置 key 时，本模块整体不可用（不请求、不报错，由界面显示降级态）。"""
        return bool(self._key)

    # ── 逆地理编码 ───────────────────────────────────────────

    async def reverse_geocode(self, lat: float, lng: float) -> dict[str, Any] | None:
        """坐标 → 地址。返回精简后的字典，字段缺失即 None。

        返回结构（只保留界面要用的，原始响应里有几十个字段）：
            address      标准格式化地址，如「上海市浦东新区XX路XX号」
            recommend    更人性化的推荐描述（可能比 address 更好读）
            province/city/district/street   行政区划
        """
        if not self.available:
            return None

        cache_key = f"{_grid(lat)},{_grid(lng)}"
        now = time.time()
        hit = self._address_cache.get(cache_key)
        if hit and hit[0] > now:
            return hit[1]

        payload = await self._get_json(
            GEOCODER_URL,
            {"location": f"{lat:.6f},{lng:.6f}", "key": self._key, "get_poi": 0},
        )
        if payload is None:
            # 失败不写缓存：否则一次网络抖动会被记十分钟（与充电站价格同一原则）
            return None

        result = payload.get("result") or {}
        component = result.get("address_component") or {}
        formatted = result.get("formatted_addresses") or {}
        data = {
            "address": result.get("address") or None,
            "recommend": formatted.get("recommend") or None,
            "province": component.get("province") or None,
            "city": component.get("city") or None,
            "district": component.get("district") or None,
            "street": component.get("street") or None,
        }
        self._address_cache[cache_key] = (now + _ADDRESS_TTL, data)
        return data

    # ── 天气 ─────────────────────────────────────────────────

    async def weather(self, lat: float, lng: float) -> dict[str, Any] | None:
        """坐标 → 当地实时天气。失败返回 None（界面显示「--」）。

        ⚠️ 这是**「当地气温」，不是车外实测温度**：车端 `climateStatus.exteriorTemp`
        实测恒为空（非空率 0/15），这版固件根本不上报。日常两者基本一致，
        差别只在极端场景（暴晒、地下车库）—— 所以界面上写「当地气温」，不写「车外温度」。

        返回结构（原始响应字段很多，只留界面要用的）：
            temperature   气温（℃，整数）
            weather       天气现象（「多云」「小雨」）
            humidity      相对湿度 %
            windDirection / windPower   风向 / 风力
            city / district             行政区（界面可以不显示，便于排查）
            updateTime    上游观测时间
        """
        if not self.available:
            return None

        cache_key = f"{_grid(lat)},{_grid(lng)}"
        now = time.time()
        hit = self._weather_cache.get(cache_key)
        if hit and hit[0] > now:
            return hit[1]

        payload = await self._get_json(
            WEATHER_URL,
            {"location": f"{lat:.6f},{lng:.6f}", "key": self._key},
        )
        if payload is None:
            # 失败不写缓存：一次网络抖动不该让界面十分钟都没有温度
            return None

        realtime = (payload.get("result") or {}).get("realtime") or []
        current = realtime[0] if realtime and isinstance(realtime[0], dict) else {}
        infos = current.get("infos") or {}
        temperature = infos.get("temperature")
        if temperature is None:
            # 拿不到气温就当失败：界面上「--」比「0℃」诚实
            return None

        data = {
            "temperature": temperature,
            "weather": infos.get("weather") or None,
            "humidity": infos.get("humidity"),
            "windDirection": infos.get("wind_direction") or None,
            "windPower": infos.get("wind_power") or None,
            "city": current.get("city") or None,
            "district": current.get("district") or None,
            "updateTime": current.get("update_time") or None,
        }
        self._weather_cache[cache_key] = (now + _WEATHER_TTL, data)
        return data

    # ── 静态地图 ─────────────────────────────────────────────

    async def static_map(
        self,
        lat: float,
        lng: float,
        *,
        width: int = 640,
        height: int = 280,
        zoom: int = 16,
        scale: int = 2,
    ) -> tuple[bytes, str] | None:
        """返回 (图片字节, content-type)。失败返回 None（界面退回不显示图）。

        尺寸约束来自官方文档：宽 50–1680、高 50–1200，zoom 4–18。
        超范围腾讯不返回图片（而不是报错），所以这里先夹紧再发。
        """
        if not self.available:
            return None

        width = max(50, min(1680, int(width)))
        height = max(50, min(1200, int(height)))
        zoom = max(4, min(18, int(zoom)))
        scale = 2 if int(scale) >= 2 else 1

        cache_key = f"{_grid(lat, 6)},{_grid(lng, 6)}|{width}x{height}|{zoom}|{scale}"
        now = time.time()
        hit = self._image_cache.get(cache_key)
        if hit and hit[0] > now:
            return hit[1]

        params = {
            "center": f"{lat:.6f},{lng:.6f}",
            "zoom": zoom,
            "size": f"{width}*{height}",
            "scale": scale,
            "maptype": "roadmap",
            # 标记点样式：大号红点，省得再引外部图标（腾讯示例图不可外链）
            "markers": f"size:large|color:red|{lat:.6f},{lng:.6f}",
            "key": self._key,
        }
        image = await self._get_bytes(STATICMAP_URL, params)
        if image is None:
            return None

        if len(self._image_cache) >= _MAX_IMAGE_ENTRIES:
            # 简单裁剪：丢掉最早过期的一条即可，不值得为这点内存上 LRU
            oldest = min(self._image_cache, key=lambda k: self._image_cache[k][0])
            self._image_cache.pop(oldest, None)
        self._image_cache[cache_key] = (now + _IMAGE_TTL, image)
        return image

    # ── 底层请求 ─────────────────────────────────────────────

    async def _get_json(self, url: str, params: dict[str, Any]) -> dict[str, Any] | None:
        try:
            async with httpx.AsyncClient(timeout=TIMEOUT, follow_redirects=True) as http:
                resp = await http.get(url, params=params)
                resp.raise_for_status()
                payload = resp.json()
        except Exception as exc:  # noqa: BLE001
            # 只打异常类型：异常文本可能包含完整 URL（其中带 key 与坐标）
            logger.warning("腾讯地图请求失败（%s）", type(exc).__name__)
            return None

        status = payload.get("status")
        if status != STATUS_OK:
            # message 是腾讯自己写的，不含坐标，可安全记录
            logger.warning("腾讯地图返回异常 status=%s msg=%s", status, payload.get("message"))
            return None
        return payload

    async def _get_bytes(self, url: str, params: dict[str, Any]) -> tuple[bytes, str] | None:
        try:
            async with httpx.AsyncClient(timeout=TIMEOUT, follow_redirects=True) as http:
                resp = await http.get(url, params=params)
                resp.raise_for_status()
        except Exception as exc:  # noqa: BLE001
            logger.warning("腾讯静态图请求失败（%s）", type(exc).__name__)
            return None

        content_type = resp.headers.get("content-type", "").split(";")[0].strip()
        if not content_type.startswith("image/"):
            # 出错时腾讯返回的是 JSON（status/message），不是图片
            logger.warning("腾讯静态图未返回图片（content-type=%s）", content_type or "空")
            return None
        return resp.content, content_type


_client: TencentMapClient | None = None


def get_map_client() -> TencentMapClient:
    """按当前配置取单例（配置变了要重启服务端）。"""
    global _client
    if _client is None:
        from ..core.config import config

        _client = TencentMapClient(config.tencent_map_key)
    return _client


def reset_map_client() -> None:
    """测试与配置重载用。"""
    global _client
    _client = None
