"""金额补录（截图识别 / 手工 / 配对）的契约测试。

重点守三件事：
  1. **配对口径**：电量 ±5% 且时间 ±10 分钟才算强匹配；多候选不许自己拍板；
  2. **不吞钱**：配不上的支付必须留下（unmatched / pending），不能静默丢；
  3. **隐私**：识别结果回传前必须剔掉 VIN / 手机号 / 完整订单号。
"""

from __future__ import annotations

from datetime import datetime, timedelta

import pytest

BASE = datetime(2026, 10, 16, 22, 10, 0)


@pytest.fixture()
def client():
    from fastapi.testclient import TestClient

    from app.main import app

    return TestClient(app)


@pytest.fixture
def writable(monkeypatch: pytest.MonkeyPatch):
    """把 is_mock() 固定为 False —— 否则补录接口会按设计返回 503。

    数据库本身由 conftest 隔离到 tmp_path，**不会碰到真实库**。
    """
    import app.api.charges as charges_api

    monkeypatch.setattr(charges_api, "is_mock", lambda: False)
    return charges_api


def _session(sid: str, start: datetime, kwh: float = 80.1, minutes: int = 63) -> dict:
    return {
        "sessionId": sid,
        "source": "zeekr",
        "startTime": start.strftime("%Y-%m-%d %H:%M:%S"),
        "endTime": (start + timedelta(minutes=minutes)).strftime("%Y-%m-%d %H:%M:%S"),
        "durationMin": float(minutes),
        "energyKwh": kwh,
        "chargeType": "dc",
    }


def _seed_sessions(*sessions: dict) -> None:
    from app.main import store

    store.save_sessions(list(sessions))


# ── 配对口径（纯函数）──────────────────────────────────────────────────


def test_strong_match_needs_energy_and_time():
    """电量差 ≤5% 且起点差 ≤10 分钟 → strong。"""
    from app.bills.matching import candidate_matches

    sessions = [_session("a", BASE), _session("b", BASE + timedelta(hours=5), kwh=40)]

    cands = candidate_matches({"paidAt": "2026-10-16 22:12", "energyKwh": 80.0}, sessions)

    assert [c["sessionId"] for c in cands] == ["a"]
    assert cands[0]["kind"] == "strong"


def test_weak_match_uses_time_window_only():
    """时间落在 session±30 分钟、但电量对不上 → weak（低置信）。"""
    from app.bills.matching import candidate_matches

    sessions = [_session("a", BASE, kwh=80.1)]
    cands = candidate_matches({"paidAt": "2026-10-16 21:50", "energyKwh": 30.0}, sessions)

    assert cands and cands[0]["kind"] == "weak"
    assert cands[0]["confidence"] == "low"


def test_no_match_outside_window():
    from app.bills.matching import candidate_matches

    sessions = [_session("a", BASE)]
    assert candidate_matches({"paidAt": "2026-10-16 12:00", "energyKwh": 80.1}, sessions) == []


def test_multiple_candidates_lower_confidence():
    """同一天充两次且电量接近 → 不能自动绑定，必须降为 low。"""
    from app.bills.matching import candidate_matches, choose_match

    sessions = [_session("a", BASE), _session("b", BASE + timedelta(minutes=25))]

    best = choose_match(candidate_matches({"paidAt": "2026-10-16 22:12", "energyKwh": 80.1}, sessions))

    assert best is not None
    assert best["confidence"] == "low"


def test_single_weak_match_is_low_confidence():
    """只有一条弱匹配也不能算 high —— 时间挨着不代表是同一笔。"""
    from app.bills.matching import candidate_matches, choose_match

    sessions = [_session("a", BASE, kwh=80.1)]
    best = choose_match(candidate_matches({"paidAt": "2026-10-16 21:50", "energyKwh": 5}, sessions))

    assert best["confidence"] == "low"


def test_energy_tolerance_boundary():
    """5% 是包含边界：80 度的 5% = 4 度。

    超出容差**不等于没有候选** —— 时间还落在窗口里，所以仍然是 weak（低置信），
    只是不能再自动绑定（见 `test_weak_match_uses_time_window_only`）。
    """
    from app.bills.matching import candidate_matches

    sessions = [_session("a", BASE, kwh=80.0)]

    inside = candidate_matches({"paidAt": "2026-10-16 22:10", "energyKwh": 76.0}, sessions)
    outside = candidate_matches({"paidAt": "2026-10-16 22:10", "energyKwh": 75.9}, sessions)

    assert inside and inside[0]["kind"] == "strong"
    assert outside and outside[0]["kind"] == "weak"


def test_unit_price_never_fabricates_zero():
    """缺电量就是 None —— 拿 0 顶会让"每度多少钱"变成 0 元。"""
    from app.bills.matching import unit_price

    assert unit_price(28.85, 80.146) == 0.36
    assert unit_price(28.85, None) is None
    assert unit_price(28.85, 0) is None
    assert unit_price(None, 80) is None


@pytest.mark.parametrize(
    "text",
    [
        "2026-10-16 22:10",
        "2026-10-16 22:10:00",
        "2026/10/16 22:10",
        "2026-10-16T22:10",
        "2026.10.16 22:10",
    ],
)
def test_parse_time_variants(text):
    from app.bills.matching import parse_time

    parsed = parse_time(text)
    assert parsed is not None and parsed.hour == 22


def test_sanity_rejects_absurd_unit_price():
    """单价 0.1 或 9 元/度基本是识别错了（服务费原价/总额被当成了实付）。"""
    from app.bills.matching import sanity_check

    assert sanity_check({"amount": 28.85, "energyKwh": 80.1, "confidence": 0.9})[0]
    assert not sanity_check({"amount": 5.0, "energyKwh": 80.1})[0]
    assert not sanity_check({"amount": 900.0, "energyKwh": 80.1})[0]
    assert not sanity_check({"amount": 20.0, "energyKwh": 20.0, "confidence": 0.4})[0]


# ── 回传过滤（隐私）────────────────────────────────────────────────────


def test_scrub_drops_vin_phone_and_full_order_no():
    """模型不听话时，回传这一层必须把敏感字段清掉。"""
    from app.adapters.vision_ocr import scrub_row

    row = scrub_row(
        {
            "amount": "¥28.85",
            "energyKwh": "80.146度",
            "stationName": "上海经纬汇极充站 3号楼 B1层",
            "orderNoTail4": "202610160000123456",
            "evidenceText": "VIN L6TDEMOCK000000000 手机 13800138000 已支付 ¥28.85",
            "confidence": "0.92",
            "vin": "L6TDEMOCK000000000",
            "plate": "沪A12345",
        }
    )

    assert row["amount"] == 28.85
    assert row["energyKwh"] == pytest.approx(80.146)
    assert row["orderNoTail4"] == "3456"
    # 站点名去掉门牌楼层
    assert row["stationName"] == "上海经纬汇极充站"
    # VIN 与手机号一律不出现
    assert "L6TDEMOCK" not in (row["evidenceText"] or "")
    assert "13800138000" not in (row["evidenceText"] or "")
    # 白名单之外的键根本不进结果
    assert "vin" not in row and "plate" not in row


def test_scrub_keeps_plain_values():
    from app.adapters.vision_ocr import scrub_row

    row = scrub_row({"amount": 10.5, "stationName": "特来电·世纪公园站", "confidence": 0.8})

    assert row["amount"] == 10.5
    assert row["stationName"] == "特来电·世纪公园站"
    assert row["currency"] == "CNY"


def test_scrub_parses_third_party_duration_and_energy():
    """第三方账单的三种版式（改充电 / 国网式 / 理想超充）都要能落成字段。

    尤其是「00:18:25」：交给 _as_float 会抠出 "00" 当分钟 —— 时长凭空变 0，
    平均功率和配对窗口跟着全废，所以必须走时分秒解析。
    """
    from app.adapters.vision_ocr import scrub_row

    # 改充电：「充电62.370度 · 用时37分钟」+ 下单时间
    li_gai = scrub_row(
        {
            "amount": 28.84,
            "energyKwh": "充电62.370度",
            "durationMin": "用时37分钟",
            "startAt": "2026-04-30 22:11:20",
        }
    )
    assert li_gai["energyKwh"] == pytest.approx(62.370)
    assert li_gai["durationMin"] == pytest.approx(37.0)
    assert li_gai["startAt"] == "2026-04-30 22:11:20"

    # 理想超充：裸时间 + 「充电时长 00:18:25」+ 「充电度数 60.672度」
    li_xiang = scrub_row(
        {
            "amount": 105.0,
            "energyKwh": "60.672度",
            "durationMin": "00:18:25",
            "startAt": "2026-09-25 18:35:42",
        }
    )
    assert li_xiang["energyKwh"] == pytest.approx(60.672)
    # 18 分 25 秒 = 18.4 分钟，不是 0
    assert li_xiang["durationMin"] == pytest.approx(18.4)
    assert li_xiang["startAt"] == "2026-09-25 18:35:42"

    # 国网式：「充电电量：56.9710度」，没有时长
    state_grid = scrub_row({"amount": 94.38, "energyKwh": "充电电量：56.9710度"})
    assert state_grid["energyKwh"] == pytest.approx(56.971)
    assert state_grid["durationMin"] is None


# ── OCR 接口 ───────────────────────────────────────────────────────────


def test_receipts_status_reports_unconfigured(monkeypatch: pytest.MonkeyPatch, client):
    from app.core.config import config

    monkeypatch.setattr(config, "deepseek_api_key", "", raising=False)
    data = client.get("/api/charges/receipts/status").json()["data"]

    assert data["configured"] is False
    assert data["model"] is None


def test_ocr_without_key_returns_503(monkeypatch: pytest.MonkeyPatch, client):
    """没配 key 要明确说"去填 DEEPSEEK_API_KEY"，而不是含糊的识别失败。"""

    async def boom(*_a, **_k):
        from app.core.config import config

        if not config.deepseek_api_key:
            from app.adapters.vision_ocr import VisionUnavailable

            raise VisionUnavailable("未配置 DEEPSEEK_API_KEY，无法使用截图识别")
        return {"type": "receipt", "rows": [], "imageSha8": "x"}

    monkeypatch.setattr("app.api.charges.extract_receipts", boom)
    from app.core.config import config

    monkeypatch.setattr(config, "deepseek_api_key", "", raising=False)

    resp = client.post(
        "/api/charges/receipts/ocr",
        files={"file": ("shot.png", b"\x89PNG\r\n\x1a\n fake", "image/png")},
    )

    assert resp.status_code == 503
    assert "DEEPSEEK_API_KEY" in resp.json()["detail"]


def test_ocr_returns_rows_with_candidates(writable, monkeypatch, client):
    """识别结果必须带候选与"需复核"标记，且**不入库**。

    只用一张假图，网络调用整个被替换掉 —— 测试绝不碰真实 vision 服务。
    """
    _seed_sessions(_session("zeekr:a", BASE))

    async def fake_extract(_image, _mime, *, include_raw: bool = False):
        return {
            "type": "list_row",
            "imageSha8": "abcd1234",
            "rows": [
                {
                    "amount": 28.85,
                    "energyKwh": 80.146,
                    "startAt": "2026-10-16 22:10",
                    "endAt": "2026-10-16 23:13",
                    "stationName": "上海经纬汇极充站",
                    "confidence": 0.92,
                },
                {
                    "amount": 3.0,
                    "energyKwh": 80.0,
                    "startAt": "2026-10-16 22:10",
                    "confidence": 0.5,
                },
            ],
        }

    monkeypatch.setattr("app.api.charges.extract_receipts", fake_extract)

    data = client.post(
        "/api/charges/receipts/ocr",
        files={"file": ("shot.png", b"fake-image-bytes", "image/png")},
    ).json()["data"]

    assert data["imageSha8"] == "abcd1234"
    assert len(data["rows"]) == 2
    assert data["rows"][0]["candidates"][0]["sessionId"] == "zeekr:a"
    assert data["rows"][0]["needsReview"] is False
    # 单价 0.04 元/度 → 明显读错，必须标黄让用户看
    assert data["rows"][1]["needsReview"] is True

    from app.main import store

    assert store.list_payments() == []       # 不落库


def test_ocr_rejects_non_image(writable, client):
    resp = client.post(
        "/api/charges/receipts/ocr",
        files={"file": ("bill.pdf", b"%PDF-1.4", "application/pdf")},
    )
    assert resp.status_code == 400


# ── 入库与配对 ─────────────────────────────────────────────────────────


def test_commit_links_strong_match_and_sets_amount(writable, client):
    _seed_sessions(_session("zeekr:a", BASE, kwh=80.1))

    data = client.post(
        "/api/charges/receipts/commit",
        json={
            "imageSha8": "abcd1234",
            "rows": [
                {
                    "amount": 28.85,
                    "energyKwh": 80.146,
                    "startAt": "2026-10-16 22:10",
                    "stationName": "上海经纬汇极充站",
                }
            ],
        },
    ).json()["data"]

    assert data["linked"] == 1
    assert data["pending"] == 0

    sessions = client.get("/api/charges/sessions", params={"yearMonth": "2026-10"}).json()["data"]
    rec = sessions["records"][0]
    assert rec["amount"] == 28.85
    assert rec["amountSource"] == "ocr"
    assert rec["stationName"] == "上海经纬汇极充站"
    assert rec["unitPrice"] == pytest.approx(0.36, abs=0.01)
    # 汇总口径：已确认金额 + 单价
    assert sessions["amountTotal"] == 28.85
    assert sessions["unitPrice"] == pytest.approx(0.36, abs=0.01)
    assert sessions["unpricedCount"] == 0


def test_commit_keeps_unmatched_payments(writable, client):
    """零命中也必须留下来，不能因为配不上就把钱丢了。"""
    _seed_sessions(_session("zeekr:a", BASE))

    data = client.post(
        "/api/charges/receipts/commit",
        json={"rows": [{"amount": 8.0, "startAt": "2026-09-01 10:00"}]},
    ).json()["data"]

    assert data["unmatched"] == 1

    from app.main import store

    payments = store.list_payments()
    assert len(payments) == 1
    assert payments[0]["status"] == "unmatched"


def test_commit_marks_multi_candidate_pending(writable, client):
    _seed_sessions(_session("zeekr:a", BASE), _session("zeekr:b", BASE + timedelta(minutes=20)))

    data = client.post(
        "/api/charges/receipts/commit",
        json={"rows": [{"amount": 30.0, "energyKwh": 80.0, "startAt": "2026-10-16 22:10"}]},
    ).json()["data"]

    assert data["pending"] == 1
    assert data["linked"] == 0


def test_commit_is_idempotent(writable, client):
    """同一张截图重跑不会插两遍（幂等键含图 hash）。"""
    _seed_sessions(_session("zeekr:a", BASE))
    body = {
        "imageSha8": "abcd1234",
        "rows": [{"amount": 28.85, "energyKwh": 80.1, "startAt": "2026-10-16 22:10"}],
    }

    first = client.post("/api/charges/receipts/commit", json=body).json()["data"]
    second = client.post("/api/charges/receipts/commit", json=body).json()["data"]

    assert first["inserted"] == 1
    assert second["inserted"] == 0
    assert second["skipped"] == 1

    from app.main import store

    assert len(store.list_payments()) == 1


def test_manual_payment_with_explicit_session(writable, client):
    """手工录入可直接指定是哪一次充电（4 字段兜底那条路）。"""
    _seed_sessions(_session("zeekr:a", BASE))

    data = client.post(
        "/api/charges/payments/manual",
        json={"amount": 45.0, "paidAt": "2026-10-18 09:00", "sessionId": "zeekr:a"},
    ).json()["data"]

    assert data["linked"] == 1

    from app.main import store

    assert store.list_sessions()[0]["amount"] == 45.0
    assert store.list_sessions()[0]["amountSource"] == "manual"


def test_manual_payment_validates_input(writable, client):
    assert client.post("/api/charges/payments/manual", json={"amount": 0}).status_code == 400
    assert client.post(
        "/api/charges/payments/manual", json={"amount": 10, "paidAt": "昨天"}
    ).status_code == 400


def test_payments_list_includes_candidates(writable, client):
    """待确认的支付要连候选一起返回 —— 用户点一下就能绑，不用再翻流水。

    这里塞**两条**相近的流水：唯一强匹配会被直接绑定（进 matched），
    只有"多候选拿不准"的才会停在 pending。
    """
    _seed_sessions(_session("zeekr:a", BASE), _session("zeekr:b", BASE + timedelta(minutes=15)))
    client.post(
        "/api/charges/receipts/commit",
        json={"imageSha8": "h1", "rows": [{"amount": 20.0, "energyKwh": 80.0,
                                           "startAt": "2026-10-16 22:12"}]},
    )

    data = client.get("/api/charges/payments", params={"status": "pending"}).json()["data"]

    assert data["payments"]
    assert "zeekr:a" in [c["sessionId"] for c in data["payments"][0]["candidates"]]


def test_link_and_unlink(writable, client):
    _seed_sessions(_session("zeekr:a", BASE), _session("zeekr:b", BASE + timedelta(days=3)))
    client.post(
        "/api/charges/receipts/commit",
        json={"imageSha8": "h2", "rows": [{"amount": 12.0, "startAt": "2026-10-19 22:10"}]},
    )
    from app.main import store

    payment_id = store.list_payments()[0]["paymentId"]

    linked = client.post(
        f"/api/charges/payments/{payment_id}/link", json={"sessionId": "zeekr:a"}
    )
    assert linked.status_code == 200
    # 列表要能看出"这笔挂在哪次充电上" —— 否则界面上没法给解绑入口
    assert store.list_payments()[0]["sessionId"] == "zeekr:a"
    assert store.list_sessions(year_month="2026-10")[1]["amount"] == 12.0 or any(
        s["amount"] == 12.0 for s in store.list_sessions()
    )

    removed = client.delete(f"/api/charges/payments/{payment_id}/link")
    assert removed.status_code == 200
    assert all(s["amount"] is None for s in store.list_sessions())
    # 解绑不删证据：支付退回待确认
    assert store.list_payments()[0]["status"] == "pending"


def test_unlink_unknown_payment_returns_404(writable, client):
    assert client.delete("/api/charges/payments/nope/link").status_code == 404


def test_writes_blocked_in_mock_mode(client):
    """模拟模式没有真实流水可配对 —— 写入必须被挡住，而不是写进真库。"""
    resp = client.post("/api/charges/payments/manual", json={"amount": 10, "paidAt": "2026-10-16 22:10"})

    assert resp.status_code == 503
    assert "模拟数据" in resp.json()["detail"]


def test_summary_counts_unpriced_energy(writable, client):
    """未补录金额的电量要单独可读 —— 界面据此提示"还有多少度没算钱"。"""
    _seed_sessions(
        _session("zeekr:a", BASE, kwh=60.0),
        _session("zeekr:b", BASE + timedelta(days=1), kwh=40.0),
    )
    client.post(
        "/api/charges/receipts/commit",
        json={"imageSha8": "h3", "rows": [{"amount": 30.0, "energyKwh": 60.0,
                                           "startAt": "2026-10-16 22:10"}]},
    )

    data = client.get("/api/charges/sessions", params={"yearMonth": "2026-10"}).json()["data"]

    assert data["amountCount"] == 1
    assert data["unpricedCount"] == 1
    assert data["unpricedKwh"] == pytest.approx(40.0)
    assert data["totalKwh"] == pytest.approx(100.0)
