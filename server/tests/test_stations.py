"""附近充电站的契约与降级语义回归。

必须被断言住的是两件事，否则它们会悄悄退化：

1. **对外契约**：`/api/stations/nearby` 的字段是前端（preview 两页与 iOS）
   直接消费的。mock 与 live 的形状一旦漂移，症状是"演示一切正常、
   接上真车就缺字段" —— 属于最难排查的一类问题。
2. **降级语义**：第三方价格服务不可用时，必须返回"有站点、无价格"，
   而不是整页失败；更**不能把缺价格显示成 0 元**（那会被读成"这个站免费"）。

隐私：本文件所有夹具**只复刻上游字段名与值类型**，取值一律是假值。
"""

from __future__ import annotations

import asyncio
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from app.adapters.haohan import map_price, map_station_info  # noqa: E402
from app.adapters.live_client import _map_station  # noqa: E402
from app.adapters.mock_client import MockZeekrClient  # noqa: E402

# ── 前端消费的字段（改这里等于改对外契约）──
TRIMMED_STATION_KEYS = {
    "stationId", "lat", "lng", "operatorLogo", "selfOperate", "marketingPrice",
    "availableCount", "totalCount", "acCount", "dcCount",
    "ableAcCount", "ableDcCount", "stationStatus",
}
# 由浩汉 detail 补齐的字段。
# 气泡接口**没有**站名/地址/评分（实测结论），所以这几个只能从第三方取；
# 而运营商 logo 与自营标记极氪侧已经给了，刻意不重复取。
ENRICHED_KEYS = {"name", "address", "score", "tags"}

PRICE_KEYS = {
    "totalPrice", "feeElectric", "serviceFee", "currentPeriod",
    "periods", "parkingFee", "parkFree", "holdFee", "feeDesc",
}
PERIOD_KEYS = {"timeFrame", "electric", "service", "total"}


# ══════════════════════════════════════════════
# 夹具：字段名照抄官方响应，取值全为假值
# ══════════════════════════════════════════════

def _upstream_station() -> dict:
    """极氪气泡接口的站点形状。

    `lat` / `lng` 上游是**字符串** —— 这里是刻意保留的，用来锁住
    "必须转数字"这条约束（不转的话前端算距离会退化成字符串运算）。
    """
    return {
        "stationId": "TESTSTATION0001",
        "lat": "30.1234567",
        "lng": "120.1234567",
        "availableCount": 3,
        "allConnectorCount": 8,
        "acCount": 2,
        "dcCount": 6,
        "ableAcCount": 1,
        "ableDcCount": 2,
        "operatorAvatar": "http://example.invalid/logo.png",
        "selfOperateFlag": True,
        "marketingPriceFlag": False,
        "stationStatus": 50,
        # 以下是明确**不透传**的图层 / 营销字段，留着证明裁剪真的生效
        "layer": 3, "reduceLevel": "simple", "showSizeLevel": None,
        "monthCardTag": "", "bubblesLeftIconUrl": "", "businessType": 9,
        "mapStationType": 0, "pointId": "", "ext": {}, "bubblesLeftFlag": False,
    }


def _upstream_detail() -> dict:
    """浩汉 detail 的形状。"""
    return {
        "stationId": "TESTSTATION0001",
        "stationName": "测试充电站",
        "address": "测试路 1 号",
        # 上游拼写就是 `peaseScore`（不是 please），这里照抄以锁住该事实
        "peaseScore": "4.5",
        "stationTagList": [{"tagDesc": "测试标签"}, {"tagDesc": ""}],
        "operatorAvatar": "http://example.invalid/logo.png",
        "selfOperateFlag": False,
        "totalPrice": 1.9,
        # 下面两个拆分费用是**字符串**，与 totalPrice 的数值类型不一致 ——
        # 上游真实如此，必须归一化
        "feeElectric": "1.10",
        "serviceFee": "0.80",
        "electricFeeTime": "11:00-22:00",
        "electricFeeList": [
            {"timeFrame": "00:00-11:00", "feeElectric": "0.50",
             "feeService": "0.90", "totalPrice": "1.40"},
            {"timeFrame": "11:00-22:00", "feeElectric": "1.10",
             "feeService": "0.80", "totalPrice": "1.90"},
        ],
        "parkingFee": "按场地标准收费",
        "parkFreeFlag": False,
        "holdFeeFlag": True,
        "chargeFeeDesc": "测试说明",
    }


# ══════════════════════════════════════════════
# 字段裁剪与类型归一化
# ══════════════════════════════════════════════

def test_map_station_trims_to_contract():
    """站点对象只保留契约字段 —— 图层与营销字段一律不进。"""
    mapped = _map_station(_upstream_station())

    assert set(mapped) == TRIMMED_STATION_KEYS
    for dropped in ("layer", "reduceLevel", "businessType", "monthCardTag",
                    "ext", "pointId", "showSizeLevel", "bubblesLeftIconUrl"):
        assert dropped not in mapped, f"{dropped} 不该被透传给前端"


def test_map_station_converts_string_coordinates():
    """字符串坐标必须转成 float —— 否则前端算距离会变成字符串运算。"""
    mapped = _map_station(_upstream_station())

    assert isinstance(mapped["lat"], float)
    assert isinstance(mapped["lng"], float)
    assert mapped["lat"] == pytest.approx(30.1234567)
    assert mapped["lng"] == pytest.approx(120.1234567)


def test_map_station_tolerates_missing_coordinates():
    """缺坐标时给 None 而不是抛异常 —— 调用方据此剔除该站。"""
    mapped = _map_station({"stationId": "TESTSTATION0002", "lat": "", "lng": None})

    assert mapped["lat"] is None
    assert mapped["lng"] is None


def test_map_price_normalizes_types():
    price = map_price(_upstream_detail())

    assert set(price) == PRICE_KEYS
    assert price["totalPrice"] == pytest.approx(1.9)
    # 上游是字符串 → 必须变数字，否则前端的"按价格排序"会按字典序排
    assert isinstance(price["feeElectric"], float)
    assert price["feeElectric"] == pytest.approx(1.10)
    assert price["serviceFee"] == pytest.approx(0.80)
    assert price["currentPeriod"] == "11:00-22:00"
    assert price["holdFee"] is True
    assert price["parkFree"] is False


def test_map_price_periods_are_normalized():
    price = map_price(_upstream_detail())

    assert len(price["periods"]) == 2
    assert set(price["periods"][0]) == PERIOD_KEYS
    assert price["periods"][0]["total"] == pytest.approx(1.40)
    assert price["periods"][1]["electric"] == pytest.approx(1.10)


def test_map_price_without_periods_returns_empty_list():
    """没有分时表时必须给 `[]` 而不是 None —— 前端会直接 `.map()`。"""
    price = map_price({"totalPrice": 1.2})

    assert price["periods"] == []
    assert price["totalPrice"] == pytest.approx(1.2)


def test_map_station_info_reads_upstream_names():
    info = map_station_info(_upstream_detail())

    assert set(info) == ENRICHED_KEYS
    assert info["name"] == "测试充电站"
    assert info["address"] == "测试路 1 号"
    # `peaseScore` → `score`，且转成数字
    assert info["score"] == pytest.approx(4.5)
    # 空的 tagDesc 被丢弃，不留空字符串
    assert info["tags"] == ["测试标签"]
    # 极氪侧已提供这两项，第三方这边刻意不再回，避免两个来源打架
    assert "operatorLogo" not in info and "selfOperate" not in info


# ══════════════════════════════════════════════
# mock 与 live 的形状一致
# ══════════════════════════════════════════════

def test_mock_stations_cover_frontend_contract():
    """模拟数据必须**直接满足前端契约**（含站名与价格）。

    理由：预览页在没有后端时靠它呈现设计。若 mock 只给坐标，
    那张卡片在演示环境里永远没有站名和价格 —— 设计好坏根本看不出来。
    """
    stations = asyncio.run(MockZeekrClient().get_nearby_stations(30.1234, 120.1234))

    assert stations, "模拟模式必须给出站点"
    for station in stations:
        assert set(station) >= (TRIMMED_STATION_KEYS - {"operatorLogo"}) | ENRICHED_KEYS | {"price"}
        assert isinstance(station["lat"], float)
        assert station["price"] is None or set(station["price"]) == PRICE_KEYS


def test_mock_stations_scale_with_location():
    """坐标参与随机种子：换了位置结果就变。

    这条断言的价值在于防"定位其实没生效"—— 若无论怎么定位列表都
    纹丝不动，说明坐标根本没传下去，而这种故障光看界面是看不出来的。
    """
    client = MockZeekrClient()
    here = asyncio.run(client.get_nearby_stations(30.1234, 120.1234))
    there = asyncio.run(client.get_nearby_stations(39.9000, 116.4000))

    assert [s["lat"] for s in here] != [s["lat"] for s in there]


def test_mock_station_names_are_marked_as_demo():
    """模拟站名一律带「演示」字样。

    不是洁癖：模拟数据若长得像真实场站，截图流出去就会被当成真的站点信息，
    而那关系到"去哪里充电"这种会影响真人的判断。
    """
    stations = asyncio.run(MockZeekrClient().get_nearby_stations(30.1234, 120.1234))

    for station in stations:
        assert "演示" in station["name"]


def test_mock_multi_period_station_has_current_period_marked():
    """至少要有一个分时站点，且 `currentPeriod` 落在表内。

    覆盖的是"当前时段高亮"这个特性 —— 没有多段样本就永远验证不到。
    """
    stations = asyncio.run(MockZeekrClient().get_nearby_stations(30.1234, 120.1234))
    multi = [s for s in stations if s["price"] and len(s["price"]["periods"]) > 1]

    assert multi, "模拟数据里应至少有一个尖峰平谷站点"
    for station in multi:
        price = station["price"]
        frames = [p["timeFrame"] for p in price["periods"]]
        assert price["currentPeriod"] in frames
        # 当前时段的总价必须与顶层 totalPrice 一致，否则界面自相矛盾
        active = next(p for p in price["periods"] if p["timeFrame"] == price["currentPeriod"])
        assert active["total"] == pytest.approx(price["totalPrice"])


# ══════════════════════════════════════════════
# 接口契约与降级
# ══════════════════════════════════════════════

@pytest.fixture()
def client():
    from fastapi.testclient import TestClient

    from app.main import app

    return TestClient(app)


def test_nearby_endpoint_shape(client):
    """/api/stations/nearby 的响应契约。"""
    resp = client.get("/api/stations/nearby", params={"lat": 30.1234, "lng": 120.1234})
    assert resp.status_code == 200

    data = resp.json()["data"]
    assert set(data) == {"location", "total", "count", "priceAvailable", "stations"}
    assert data["count"] == len(data["stations"])
    assert data["total"] >= data["count"]


def test_nearby_endpoint_sorts_by_distance(client):
    """返回顺序按距离升序 —— 前端默认视图直接吃这个顺序。"""
    resp = client.get("/api/stations/nearby", params={"lat": 30.1234, "lng": 120.1234})
    distances = [s["distanceKm"] for s in resp.json()["data"]["stations"]]

    assert distances == sorted(distances)


def test_nearby_endpoint_respects_limit(client):
    resp = client.get("/api/stations/nearby",
                      params={"lat": 30.1234, "lng": 120.1234, "limit": 2})

    assert len(resp.json()["data"]["stations"]) == 2


def test_nearby_endpoint_rejects_invalid_coordinates(client):
    """坐标越界在入口就被挡下 —— 不要让它走到网关再报错。"""
    assert client.get("/api/stations/nearby", params={"lat": 91, "lng": 120}).status_code == 422
    assert client.get("/api/stations/nearby", params={"lat": 30, "lng": 181}).status_code == 422
    assert client.get("/api/stations/nearby", params={"lat": 30}).status_code == 422


def test_price_failure_degrades_instead_of_failing(monkeypatch):
    """第三方价格服务不可用时：站点照常返回，只是没有价格。

    这是本模块最重要的行为 —— 如果这里退化成 500，
    用户会因为"一个外部厂商挂了"而完全看不到附近的充电站。
    """
    import app.api.stations as stations_api

    async def _fake_list(self, lat, lng, zoom=13):
        # 必须复刻 **live 形状**（气泡接口本来就没有站名与价格）；
        # 用 mock 客户端会自带价格，那就测不出降级了。
        return [{"stationId": "TESTSTATION0001", "lat": lat, "lng": lng,
                 "availableCount": 2, "totalCount": 4}]

    async def _detail_fail(self, station_id):
        return None

    monkeypatch.setattr(type(stations_api.get_client()), "get_nearby_stations", _fake_list)
    monkeypatch.setattr(stations_api, "HaohanClient", type(
        "FailingHaohan", (), {"__init__": lambda self, **kw: None,
                              "get_station_detail": _detail_fail,
                              "get_station_dynamic": _detail_fail}))
    monkeypatch.setattr(stations_api, "_haohan", None)
    monkeypatch.setattr(stations_api, "is_mock", lambda: False)
    # 缓存会让上面那个假客户端不被调用，先清空
    stations_api._station_cache.clear()
    stations_api._price_cache.clear()

    from fastapi.testclient import TestClient

    from app.main import app

    with TestClient(app) as client:
        resp = client.get("/api/stations/nearby",
                          params={"lat": 30.1234, "lng": 120.1234})

    assert resp.status_code == 200
    data = resp.json()["data"]
    assert data["stations"], "价格挂了不代表列表也该空"
    assert data["priceAvailable"] is False
    # 关键：价格为 None（而不是 0）—— 0 会被读成"这个站免费"
    for station in data["stations"]:
        assert station.get("price") is None

    stations_api._station_cache.clear()
    stations_api._price_cache.clear()


def test_station_cache_key_is_a_coordinate_grid(monkeypatch):
    """缓存键按 ~100m 网格归一 —— 地图上小幅移动不该重复打网关。

    这是唯一的风控手段：两侧网关的限流阈值都未知，而地图类交互
    天然是高频的。
    """
    import app.api.stations as stations_api

    calls = []

    async def _fake_list(self, lat, lng, zoom=13):
        calls.append((lat, lng))
        return [{"stationId": "TESTSTATION0001", "lat": lat, "lng": lng,
                 "availableCount": 1, "totalCount": 1}]

    monkeypatch.setattr(type(stations_api.get_client()), "get_nearby_stations", _fake_list)
    stations_api._station_cache.clear()

    from fastapi.testclient import TestClient

    from app.main import app

    with TestClient(app) as client:
        client.get("/api/stations/nearby", params={"lat": 30.12341, "lng": 120.12341})
        client.get("/api/stations/nearby", params={"lat": 30.12344, "lng": 120.12344})
        first_batch = len(calls)
        client.get("/api/stations/nearby", params={"lat": 30.2000, "lng": 120.2000})

    assert first_batch == 1, f"同网格内的两次请求应命中缓存，实际打了 {first_batch} 次"
    assert len(calls) == 2, "换网格应重新请求"
    stations_api._station_cache.clear()
