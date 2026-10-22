"""充电流水接口（`/api/charges/sessions|months|sync`）的契约测试。

这组用例锁的是**口径**与**落库边界**，不是实现细节 ——
改造充电页时最容易错的两件事：把「充了几次」与「充了多少度」混成一个数；
以及让模拟数据写进真实库（历史上据此攒出过 60 条假行程）。
"""

from __future__ import annotations

import pytest


@pytest.fixture()
def client():
    from fastapi.testclient import TestClient

    from app.main import app

    return TestClient(app)


@pytest.fixture(autouse=True)
def _reset_sync_cooldown():
    """同步有 10 秒最小间隔，跨用例必须清零，否则第二条用例直接 429。"""
    from app.api import charges

    charges._last_sync_at = 0.0
    yield
    charges._last_sync_at = 0.0


@pytest.fixture
def synced(client):
    """先同步一次（模拟数据 45 条左右），返回同步结果。"""
    resp = client.post("/api/charges/sync")
    assert resp.status_code == 200
    return resp.json()["data"]


# ── 同步 ────────────────────────────────────────────────────────────────


def test_sync_reports_fetched_rows(synced):
    """同步返回上游条数；模拟模式明确标 `persisted=False`。"""
    assert synced["fetched"] > 0
    assert synced["persisted"] is False
    assert synced["inserted"] == 0
    assert synced["total"] == synced["fetched"]


def test_sync_does_not_persist_mock(client, synced):
    """模拟数据**一律不落库**。

    这是历史事故的回归测试：`save_trips` 曾无条件写入，跑一次模拟模式就把
    60 条假行程写进真实库，排查时差点被当成真数据。
    """
    from app.main import store

    assert synced["fetched"] > 0
    assert store.count_sessions() == 0


def test_sync_has_min_interval(client, synced):
    """刚同步过就再点，必须被挡住（否则连点会连打官方网关）。"""
    resp = client.post("/api/charges/sync")

    assert resp.status_code == 429
    assert "秒后再试" in resp.json()["detail"]


# ── 单月统计 ────────────────────────────────────────────────────────────


def test_sessions_defaults_to_current_month(client, synced):
    """不带参数 = 本月，且 `yearMonth` 回的是真实年月而非 currentMonth。"""
    from datetime import datetime

    data = client.get("/api/charges/sessions").json()["data"]

    assert data["yearMonth"] == datetime.now().strftime("%Y-%m")
    assert data["label"].endswith("月")
    assert data["count"] == len(data["records"])


def test_sessions_totals_are_consistent(client, synced):
    """总电量 == 逐笔之和；快慢充笔数之和 == 总笔数。"""
    data = client.get("/api/charges/sessions").json()["data"]

    summed = round(sum(r["energyKwh"] or 0 for r in data["records"]), 1)
    assert data["totalKwh"] == pytest.approx(summed, abs=0.2)
    assert data["dcCount"] + data["acCount"] == data["count"]
    assert data["dcKwh"] + data["acKwh"] == pytest.approx(data["totalKwh"], abs=0.3)


def test_sessions_records_are_newest_first(client, synced):
    """逐笔记录按开始时间倒序 —— 前端直接渲染，不再自己排序。"""
    starts = [r["startTime"] for r in client.get("/api/charges/sessions").json()["data"]["records"]]

    assert starts == sorted(starts, reverse=True)


def test_sessions_have_no_fabricated_amount(client, synced):
    """官方接口没有金额 ⇒ 落库的 amount 必须是 None，绝不能填 0。

    填 0 的后果很具体：`unit_price = amount / energy_kwh` 会算出 0 元/度，
    然后"每公里成本"整个塌成 0。
    """
    data = client.get("/api/charges/sessions").json()["data"]

    assert data["amountTotal"] is None
    assert data["amountCount"] == 0
    assert data["estimatedCount"] == 0
    assert all(r["amount"] is None for r in data["records"])
    assert all(r["amountSource"] is None for r in data["records"])


def test_sessions_filter_by_month(client, synced):
    """按 `YYYY-MM` 过滤：只回那个月的记录，且不会混进别的月。"""
    data = client.get("/api/charges/sessions", params={"yearMonth": "2026-01"}).json()["data"]

    assert data["yearMonth"] == "2026-01"
    assert all(r["startTime"].startswith("2026-01") for r in data["records"])


def test_sessions_rejects_bad_month(client):
    """格式不对要 400，而不是悄悄回退成本月（那会让人以为筛选没生效）。"""
    for bad in ("2026-13", "2026-1", "26-01", "2026/01", "2026-00"):
        resp = client.get("/api/charges/sessions", params={"yearMonth": bad})
        assert resp.status_code == 400, bad


def test_summarize_empty_month_keeps_shape():
    """空月份字段齐备，前端不必到处判空；平均功率要 None 而不是 0。"""
    from app.api.charges import _summarize_month

    data = _summarize_month("2026-01", [])

    assert data["count"] == 0
    assert data["records"] == []
    assert data["totalKwh"] == 0
    assert data["avgPowerKw"] is None
    assert data["amountTotal"] is None


def test_summarize_separates_estimated_amount():
    """估算金额单独统计，绝不与真值混算 —— 否则"每度多少钱"会是第三种数字。"""
    from app.api.charges import _summarize_month

    rows = [
        {"energyKwh": 50.0, "durationMin": 30, "chargeType": "dc",
         "amount": 60.0, "amountSource": "ocr"},
        {"energyKwh": 30.0, "durationMin": 20, "chargeType": "ac",
         "amount": 20.0, "amountSource": "estimate"},
    ]
    data = _summarize_month("2026-05", rows)

    assert data["amountTotal"] == 60.0
    assert data["amountCount"] == 1
    assert data["estimatedTotal"] == 20.0
    assert data["estimatedCount"] == 1


def test_count_includes_rows_without_energy():
    """次数与电量是两个维度：缺电量的记录仍算一次充电。"""
    from app.api.charges import _summarize_month

    rows = [{"energyKwh": None, "durationMin": None, "chargeType": "unknown"}]
    data = _summarize_month("2026-05", rows)

    assert data["count"] == 1
    assert data["totalKwh"] == 0
    assert data["avgPowerKw"] is None


# ── 月份清单 ────────────────────────────────────────────────────────────


def test_months_lists_current_month_first(client, synced):
    """月份清单第一项固定是「本月」，且只出现一次。"""
    data = client.get("/api/charges/months").json()["data"]
    months = data["months"]

    assert months[0]["yearMonth"] == "currentMonth"
    assert months[0]["label"] == "本月"
    assert sum(1 for m in months if m["yearMonth"] == "currentMonth") == 1


def test_months_totals_match_sessions(client, synced):
    """清单里每个月的电量，必须与单独查该月的结果一致。"""
    months = client.get("/api/charges/months").json()["data"]["months"]

    for item in months:
        stats = client.get(
            "/api/charges/sessions", params={"yearMonth": item["yearMonth"]}
        ).json()["data"]
        assert stats["count"] == item["count"], item["yearMonth"]
        assert stats["totalKwh"] == pytest.approx(item["kwh"], abs=0.2), item["yearMonth"]
        # 趋势图第二根轴：每次充电时长（分钟），必须与当月汇同一口径
        if item["count"]:
            assert item["avgMinutes"] == pytest.approx(
                stats["totalMinutes"] / item["count"], abs=1.0
            ), item["yearMonth"]
        else:
            assert item["avgMinutes"] is None, item["yearMonth"]


# ── 存储层：幂等与"不冲掉已补录的金额" ──────────────────────────────────


def _session(sid: str, **over) -> dict:
    base = {
        "sessionId": sid,
        "source": "zeekr",
        "startTime": "2026-10-16 22:10:38",
        "endTime": "2026-10-16 23:13:44",
        "durationMin": 63.0,
        "energyKwh": 80.1,
        "chargeType": "dc",
    }
    base.update(over)
    return base


def test_save_sessions_is_idempotent():
    """同一批数据写两次，行数不变（点一下同步能随手点的前提）。"""
    from app.main import store

    first = store.save_sessions([_session("zeekr:1"), _session("zeekr:2")])
    second = store.save_sessions([_session("zeekr:1"), _session("zeekr:2")])

    assert first == {"inserted": 2, "updated": 0}
    assert second == {"inserted": 0, "updated": 2}
    assert store.count_sessions() == 2


def test_save_sessions_updates_energy_but_keeps_local_amount():
    """上游修正电量要跟着更新；但金额/站点名来自 OCR，**不能被覆盖**。

    这条是"用户辛苦配对的钱被一次例行同步抹掉"的回归测试。
    """
    from app.main import store

    store.save_sessions([_session("zeekr:9")])
    with store._connect() as conn:
        conn.execute(
            "UPDATE charge_sessions SET amount = 28.85, amount_source = 'ocr', "
            "station_name = '演示充电站' WHERE session_id = 'zeekr:9'"
        )

    store.save_sessions([_session("zeekr:9", energyKwh=81.5)])

    rows = store.list_sessions()
    assert rows[0]["energyKwh"] == 81.5
    assert rows[0]["amount"] == 28.85
    assert rows[0]["amountSource"] == "ocr"
    assert rows[0]["stationName"] == "演示充电站"


def test_save_sessions_skips_rows_without_id_or_start():
    """缺 id / 起始时间的记录直接丢弃 —— 编一个 id 会污染幂等键。"""
    from app.main import store

    result = store.save_sessions([
        {"sessionId": "", "startTime": "2026-10-16 22:10:38"},
        {"sessionId": "zeekr:x"},
        _session("zeekr:ok"),
    ])

    assert result == {"inserted": 1, "updated": 0}


def test_list_sessions_filters_by_month():
    """存储层的月份过滤按 `start_ts` 前 7 位，与接口层一致。"""
    from app.main import store

    store.save_sessions([
        _session("zeekr:a", startTime="2026-10-01 08:00:00"),
        _session("zeekr:b", startTime="2026-09-30 23:00:00"),
    ])

    october = store.list_sessions(year_month="2026-10")
    assert [r["sessionId"] for r in october] == ["zeekr:a"]

    months = {m["yearMonth"]: m["count"] for m in store.session_months()}
    assert months == {"2026-10": 1, "2026-09": 1}


def test_session_months_carries_recorded_amount():
    """月份清单要带**已补录**金额：前端「累计金额」就是把它按月加起来。

    估算（`amount_source='estimate'`）必须排除 —— 把估算混进合计，
    "这个月花了多少"就变成第三种数字，和卡片上的「当月金额」对不上。
    """
    from app.main import store

    store.save_sessions([_session("zeekr:a", energyKwh=40.0)])
    store.save_payments([
        {"paymentId": "p1", "source": "manual", "paidAt": "2026-10-16 22:10",
         "amount": 50.0, "status": "pending"},
        {"paymentId": "p2", "source": "manual", "paidAt": "2026-10-16 22:10",
         "amount": 74.4, "status": "pending"},
    ])
    store.link_payment("zeekr:a", "p1", "manual", "high")

    october = next(m for m in store.session_months() if m["yearMonth"] == "2026-10")
    assert october["amount"] == pytest.approx(50.0)
    assert october["amountCount"] == 1

    # 估算来源不计入合计（金额本身仍然留着，只是不进"花了多少钱"）
    store.save_payments([
        {"paymentId": "p3", "source": "estimate", "paidAt": "2026-10-16 22:10",
         "amount": 99.0, "status": "matched"},
    ])
    with store._connect() as conn:  # noqa: SLF001 - 测试直接造估算行
        conn.execute(
            "UPDATE charge_sessions SET amount = 99.0, amount_source = 'estimate' "
            "WHERE session_id = 'zeekr:a'"
        )

    october = next(m for m in store.session_months() if m["yearMonth"] == "2026-10")
    assert october["amount"] == 0.0
    assert october["amountCount"] == 0


# ── 归一化 ──────────────────────────────────────────────────────────────


def test_normalize_charge_sessions_maps_types():
    """归一化：直流/交流映射、毫秒转本地时间、缺 eventId 的行丢弃。"""
    from app.adapters.live_client import LiveZeekrClient

    raw = [
        {
            "year": 2026,
            "monthList": [
                {
                    "yearMonth": "2026-10",
                    "count": 3,
                    "sumPower": 120.0,
                    "records": [
                        {
                            "eventId": 111,
                            "startTime": 1792159838586,
                            "endTime": 1792163618586,
                            "chargeType": 2,
                            "chargeTypeName": "直流",
                            "chargedTime": 63,
                            "power": 80.1,
                        },
                        {
                            "eventId": 222,
                            "startTime": 1792164000000,
                            "chargeType": 1,
                            "chargeTypeName": "交流",
                            "power": 30.0,
                        },
                        # 没有 id ⇒ 无法幂等，必须丢弃而不是编一个
                        {"startTime": 1792164000000, "power": 1.0},
                    ],
                }
            ],
        }
    ]

    out = LiveZeekrClient._normalize_charge_sessions(raw)

    assert len(out) == 2
    assert {o["chargeType"] for o in out} == {"dc", "ac"}
    assert out[0]["sessionId"].startswith("zeekr:")
    assert out[0]["startTime"].count(":") == 2 and "-" in out[0]["startTime"]
    # 没有 chargedTime 时用起止时间差补时长
    assert any(o["durationMin"] == pytest.approx(63.0) for o in out)
    # 归一化结果里不能带 VIN（上游报文里有，这里必须剥掉）
    assert all("vin" not in {k.lower() for k in o} for o in out)


def test_normalize_charge_sessions_tolerates_garbage():
    """上游结构异常时返回空列表，不抛异常（同步失败要能明确报错）。"""
    from app.adapters.live_client import LiveZeekrClient

    assert LiveZeekrClient._normalize_charge_sessions(None) == []
    assert LiveZeekrClient._normalize_charge_sessions({}) == []
    assert LiveZeekrClient._normalize_charge_sessions([{"monthList": None}]) == []
    assert LiveZeekrClient._normalize_charge_sessions(["x", 1, None]) == []
