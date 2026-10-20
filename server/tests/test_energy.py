"""官方「行程与能耗」日统计：接口形状与归一化口径。

数据源是官方 `getDailyStatisticsInfo`（与 App「行程统计」同页），
这里守住三件容易出错的事：
  1. 服务端上限 31 天，越界必须先被挡在本地，不要变成一条网关错误；
  2. 逐日电量 = 动态 + 静态（`ecy` 恒 0，不能用）；
  3. 日期统一成 `YYYY-MM-DD` 且按日期升序 —— 服务端给的 X 轴只含有数据的日期。
"""

from __future__ import annotations

import pytest

from app.adapters.live_client import LiveZeekrClient


@pytest.fixture()
def client():
    from fastapi.testclient import TestClient

    from app.main import app

    return TestClient(app)


def test_energy_endpoint_shape(client):
    resp = client.get("/api/trips/energy", params={"days": 7})

    assert resp.status_code == 200
    data = resp.json()["data"]
    assert set(data) == {
        "days",
        "startDate",
        "endDate",
        "distanceKm",
        "energyKwh",
        "dynamicEnergyKwh",
        "avgConsumption",
        "avgDynamicConsumption",
        "fastChargeCount",
        "slowChargeCount",
        "series",
    }
    assert data["days"] == 7

    for item in data["series"]:
        assert set(item) == {"date", "distanceKm", "energyKwh", "minutes", "consumption"}
        assert len(item["date"]) == 10 and item["date"][4] == "-"

    # 逐日序列按日期升序，前端直接画图不用再排
    dates = [item["date"] for item in data["series"]]
    assert dates == sorted(dates)


def test_energy_endpoint_rejects_out_of_range_days(client):
    """31 天是服务端硬限制（A008），必须在本地就挡掉。"""
    for days in (0, 32, 365):
        resp = client.get("/api/trips/energy", params={"days": days})
        assert resp.status_code == 400


def test_daily_energy_merges_dynamic_and_static():
    """逐日电量必须把动态与静态相加；`ecy` 恒 0，拿来用就是永远 0 度电。"""
    payload = {
        "data": {
            "startDate": "2026年10月01日",
            "endDate": "2026年10月02日",
            "totalMileage": 60.0,
            "electricityConsumed": 11.0,
            "dynamicEc": 10.0,
            "avgEc": 18.3,
            "dynamicAvgEc": 16.7,
            "fastChargeNum": 2,
            "normalChargeNum": 1,
            # X 只含有数据的日期，且故意乱序
            "dailyMileageX": ["2026/10/02", "2026/10/01"],
            "dailyMileageY": [40.0, 20.0],
            "drivingTimeY": [55, 26],
            "dynamicEcY": [6.0, 4.0],
            "staticEcY": [0.7, 0.3],
            "ecy": [0.0, 0.0],
        }
    }

    result = LiveZeekrClient._normalize_daily_energy(payload["data"], 2)

    assert result["distanceKm"] == 60.0
    assert result["energyKwh"] == 11.0
    assert result["avgDynamicConsumption"] == 16.7
    assert result["fastChargeCount"] == 2 and result["slowChargeCount"] == 1

    # 排序 + 日期格式 + 逐日电量相加
    assert [item["date"] for item in result["series"]] == ["2026-10-01", "2026-10-02"]
    assert result["series"][0]["energyKwh"] == 4.3   # 4.0 + 0.3
    assert result["series"][1]["energyKwh"] == 6.7   # 6.0 + 0.7
    assert result["series"][0]["consumption"] == 21.5  # 4.3 / 20 * 100
    assert sum(item["energyKwh"] for item in result["series"]) == 11.0


def test_daily_energy_tolerates_short_arrays():
    """网关偶尔少一个尾巴 —— 缺的按 0 处理，不能让整页崩掉。"""
    data = {
        "dailyMileageX": ["2026/10/01", "2026/10/02"],
        "dailyMileageY": [10.0],          # 少一项
        "dynamicEcY": [],
        "staticEcY": [],
    }

    result = LiveZeekrClient._normalize_daily_energy(data, 2)

    assert len(result["series"]) == 2
    assert result["series"][1]["distanceKm"] == 0.0
    assert result["series"][1]["consumption"] is None


def test_energy_endpoint_month_scope(client):
    """scope=month 取「本月 1 日至今」——官方 App 行程统计页的同区间。

    汇总卡必须用这个区间，否则「近 7 天」的充电次数永远小于 App 的本月值，
    看起来就像数据算错了。
    """
    resp = client.get("/api/trips/energy", params={"scope": "month"})

    assert resp.status_code == 200
    data = resp.json()["data"]
    assert data["days"] >= 1
    assert data["startDate"] and data["endDate"]


def test_energy_endpoint_rejects_unknown_scope(client):
    resp = client.get("/api/trips/energy", params={"scope": "year"})
    assert resp.status_code == 400


def test_energy_endpoint_with_year_month(client):
    """指定历史月份：走月报接口，形状与本月一致（前端不用区分来源）。"""
    resp = client.get("/api/trips/energy", params={"yearMonth": "2026-08"})

    assert resp.status_code == 200
    data = resp.json()["data"]
    assert data["startDate"].startswith("2026年08月")
    assert data["distanceKm"] > 0
    assert data["series"], "历史月份也要有逐日序列，否则图表画不出来"


def test_energy_endpoint_rejects_bad_year_month(client):
    resp = client.get("/api/trips/energy", params={"yearMonth": "2026-8-1"})
    assert resp.status_code == 400


def test_energy_months_endpoint(client):
    """可选月份清单：第一项固定「本月」。"""
    resp = client.get("/api/trips/energy/months")

    assert resp.status_code == 200
    data = resp.json()["data"]
    assert data["months"][0]["yearMonth"] == "currentMonth"
    assert len(data["months"]) >= 2
