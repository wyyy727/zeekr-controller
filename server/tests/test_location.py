"""车辆位置接口的降级行为。

这些用例守着一条原则：**没有地图 key 时，位置卡必须还能用**。
一辆车的坐标本身是有价值的（能看出车在哪一片），不该因为没配第三方 key
就整块消失，更不该显示一个假的"地图加载失败"占位图。
"""

from __future__ import annotations

import pytest
from fastapi.testclient import TestClient

from app.api.location import reset_position_cache
from app.adapters.tencent_map import reset_map_client


@pytest.fixture()
def client_no_map_key(monkeypatch: pytest.MonkeyPatch):
    """未配置腾讯 key 的客户端（测试环境默认就是空）。"""
    from app.core.config import config

    monkeypatch.setattr(config, "tencent_map_key", "", raising=False)
    reset_map_client()
    reset_position_cache()

    from app.main import app

    with TestClient(app) as c:
        yield c

    reset_map_client()
    reset_position_cache()


def test_location_without_map_key_still_returns_coordinates(client_no_map_key):
    """没有 key：坐标照常返回，地址为空，并明确告知地图不可用。"""
    resp = client_no_map_key.get("/api/vehicle/location")
    assert resp.status_code == 200

    data = resp.json()["data"]
    assert data["available"] is True
    assert isinstance(data["lat"], float)
    assert isinstance(data["lng"], float)
    # 车上报时间必须带出来 —— 位置不是实时的，界面要靠它提示"多久以前"
    assert data["reportedAt"]
    assert data["address"] is None
    assert data["mapAvailable"] is False


def test_map_image_returns_404_without_key(client_no_map_key):
    """没有 key：不请求腾讯、不返回占位图，直接 404（前端 onerror 隐藏）。"""
    resp = client_no_map_key.get("/api/vehicle/location/map.png")
    assert resp.status_code == 404
    # 绝不能返回一段 JSON 或空图片，那会让 <img> 显示成破图
    assert resp.content == b""


def test_position_cache_avoids_repeated_gateway_calls(client_no_map_key, monkeypatch):
    """位置卡与缩略图会先后取同一坐标，60 秒内只打一次车况接口。"""
    from app.adapters import get_client

    calls = {"n": 0}
    real = get_client()
    # 先抓住原方法：直接写 real.get_vehicle_status 会在替换后调到自己
    original = real.get_vehicle_status

    async def counting(*args, **kwargs):
        calls["n"] += 1
        return await original(*args, **kwargs)

    monkeypatch.setattr(real, "get_vehicle_status", counting)

    client_no_map_key.get("/api/vehicle/location")
    client_no_map_key.get("/api/vehicle/location")
    client_no_map_key.get("/api/vehicle/location/map.png")

    assert calls["n"] == 1, "60 秒内应复用缓存，而不是每次请求都打车况接口"


# ── 地址 / 图片的持久化缓存 ──────────────────────────────
#
# 这组用例守的是隐私收益：坐标不变时**一次都不该再请求腾讯**。
# 用 fake client 计数，而不是断言"看起来像缓存"。


class _FakeMapClient:
    """假腾讯客户端：记录调用次数，返回固定内容。"""

    available = True

    def __init__(self) -> None:
        self.geocode_calls = 0
        self.image_calls = 0

    async def reverse_geocode(self, lat: float, lng: float):
        self.geocode_calls += 1
        return {
            "address": "演示市演示区演示路 1 号",
            "recommend": "演示园区",
            "province": "演示省",
            "city": "演示市",
            "district": "演示区",
            "street": "演示路",
        }

    async def static_map(self, lat: float, lng: float, **kwargs):
        self.image_calls += 1
        # 不写真实图片：只要前 8 字节像 PNG 即可，测试只关心"有没有再请求"
        return b"\x89PNG\r\n\x1a\n" + b"0" * 64, "image/png"


@pytest.fixture()
def fake_map(monkeypatch: pytest.MonkeyPatch, tmp_path):
    """配了 key、且腾讯客户端被替身的场景。"""
    from app.api import location

    fake = _FakeMapClient()
    monkeypatch.setattr(location, "get_map_client", lambda: fake)
    # 图片缓存指到临时目录 —— 绝不能写进真实的 server/data/mapcache
    monkeypatch.setattr(location, "_MAP_CACHE_DIR", tmp_path / "mapcache")
    reset_position_cache()

    from app.main import app

    with TestClient(app) as c:
        yield c, fake

    reset_position_cache()


def test_address_cached_in_db_and_not_refetched(fake_map):
    """第一次请求腾讯并落库；第二次坐标没变，直接吃缓存。"""
    client, fake = fake_map

    first = client.get("/api/vehicle/location").json()["data"]
    assert first["addressFromCache"] is False
    assert first["address"]["address"] == "演示市演示区演示路 1 号"
    assert fake.geocode_calls == 1

    second = client.get("/api/vehicle/location").json()["data"]
    assert second["addressFromCache"] is True
    assert fake.geocode_calls == 1, "坐标没变就不该再请求腾讯"


def test_address_cache_survives_in_database(fake_map):
    """缓存要落在库里，而不是只在进程内存 —— 否则重启后又得重新外发一次。"""
    client, fake = fake_map
    data = client.get("/api/vehicle/location").json()["data"]

    from app.api import location as loc_mod
    from app.main import store

    key = loc_mod.coord_key(data["lat"], data["lng"])
    cached = store.get_geocode(key)
    assert cached is not None
    assert cached["address"] == "演示市演示区演示路 1 号"


def test_address_refetched_when_position_changes(fake_map):
    """车换了位置 → 新坐标没有缓存 → 必须重新请求。"""
    client, fake = fake_map
    client.get("/api/vehicle/location")
    assert fake.geocode_calls == 1

    from app.api import location as loc_mod

    # 直接改位置缓存模拟"车动了"，避免依赖 mock 的随机坐标
    moved = dict(loc_mod._position_cache["data"])
    moved["lat"] = float(moved["lat"]) + 0.05
    loc_mod._position_cache["data"] = moved

    again = client.get("/api/vehicle/location").json()["data"]
    assert again["addressFromCache"] is False
    assert fake.geocode_calls == 2


def test_map_image_cached_on_disk(fake_map):
    """同一坐标的图只向腾讯取一次，第二次从磁盘返回。"""
    client, fake = fake_map

    first = client.get("/api/vehicle/location/map.png")
    assert first.status_code == 200
    assert first.headers.get("X-Map-Cache") == "miss"

    second = client.get("/api/vehicle/location/map.png")
    assert second.status_code == 200
    assert second.headers.get("X-Map-Cache") == "hit"
    assert fake.image_calls == 1, "坐标没变就不该再请求一次地图图片"
