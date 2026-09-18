"""本轮缺陷修复的回归测试。

对应审计报告里逐条修掉的缺陷。每条测试的 docstring 都写明「修之前会怎样」，
便于后来者理解这条断言为什么存在 —— 否则很容易在重构时把它当成冗余删掉。

运行：python -m pytest tests/ -v
"""

from __future__ import annotations

import asyncio
import base64
import io
import json
import re
import sys
import tempfile
from pathlib import Path
from typing import Any

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from app.adapters import mock_client as mock_module  # noqa: E402
from app.adapters.live_client import (  # noqa: E402
    ERR_LOGGED_IN_ELSEWHERE,
    ERR_SIGNATURE,
    ERR_UNAUTHORIZED,
    KNOWN_ERROR_CODES,
    LiveZeekrClient,
    ZeekrAPIError,
    _jwt_expires_at,
)
from app.adapters.mock_client import MockZeekrClient  # noqa: E402
from app.adapters.zeekr_signing import encrypt_vin  # noqa: E402
from app.bills.aggregator import build_summary  # noqa: E402
from app.bills.parsers import _decode, parse_bill  # noqa: E402
from app.core.store import Store  # noqa: E402


def _normalize(payload: dict) -> dict:
    return LiveZeekrClient._normalize_status(payload, "TESTVIN0000000001")


# MARK: - P1-1 动力电池 SOC 不得被 12V 电瓶顶替


class TestSocIsNeverLvBattery:
    """12V 电瓶电量绝不能冒充动力电池 SOC。

    修之前：两者字段名同为 chargeLevel，`pick()` 的后缀匹配会让 12V 的值
    填进 soc（实测报文缺 electricVehicleStatus 时 soc 被解析成 88）。
    用户会以为整车满电 —— 静默错值比报错危险得多。
    """

    def test_only_lv_battery_present_yields_none(self) -> None:
        payload = {
            "data": {
                "additionalVehicleStatus": {
                    "maintenanceStatus": {
                        "mainBatteryStatus": {"chargeLevel": 88, "voltage": 12.8}
                    }
                }
            }
        }
        status = _normalize(payload)
        assert status["soc"] is None, "12V 电瓶电量被当成了动力电池 SOC"
        assert status["battery12vLevel"] == 88.0, "12V 电瓶自己的字段应正常解析"

    def test_ev_field_still_wins(self) -> None:
        payload = {
            "data": {
                "additionalVehicleStatus": {
                    "electricVehicleStatus": {"chargeLevel": 86},
                    "maintenanceStatus": {
                        "mainBatteryStatus": {"chargeLevel": 88, "voltage": 12.8}
                    },
                }
            }
        }
        status = _normalize(payload)
        assert status["soc"] == 86.0
        assert status["battery12vLevel"] == 88.0

    def test_flat_charge_level_still_resolves(self) -> None:
        """扁平报文（无嵌套）仍要能取到 SOC —— 排除规则不能矫枉过正。"""
        status = _normalize({"data": {"chargeLevel": 55}})
        assert status["soc"] == 55.0


# MARK: - P0-1 车窗不再拿假数据伪装


class TestWindowsNotFabricated:
    """live 模式不再返回四个硬编码的 None 假装"读到了但未知"。

    修之前：`windows` 恒为 {"frontLeft": None, ...}，与 iOS 的
    `[String: Bool]?`（值非可选）冲突 —— 解码抛 valueNotFound，
    整个 VehicleStatus 失败，live 模式静默回落到模拟数据。
    """

    def test_windows_is_empty_in_live(self) -> None:
        status = _normalize({"data": {"electricVehicleStatus": {"chargeLevel": 50}}})
        assert status["windows"] is None, "车窗无数据时应整体留空，而不是四个 None"

    def test_doors_never_raises(self) -> None:
        """车门字段缺失时值为 None，iOS 侧已按可选值类型容错，这里不得抛异常。"""
        status = _normalize({"data": {"electricVehicleStatus": {"chargeLevel": 50}}})
        assert set(status["doors"]) == {"frontLeft", "frontRight", "rearLeft", "rearRight"}
        assert all(v is None for v in status["doors"].values())


# MARK: - P1-2 缺 success 的错误信封必须识别为错误


class TestUnwrapErrorEnvelope:
    """网关错误信封不一定带 `success` 字段。

    修之前：`payload.get("success", True)` 在字段缺失时按成功处理，
    于是 079025（签名失败）这类错误被当成"数据"，最终表现成
    「账号下未找到车辆」—— 真正的原因完全看不见。
    """

    @pytest.mark.parametrize("code", sorted(KNOWN_ERROR_CODES))
    def test_known_error_code_without_success_field_raises(self, code: str) -> None:
        with pytest.raises(ZeekrAPIError) as exc:
            LiveZeekrClient._unwrap({"code": code, "msg": "boom"})
        assert exc.value.code == code

    def test_signature_failure_is_surfaced(self) -> None:
        with pytest.raises(ZeekrAPIError) as exc:
            LiveZeekrClient._unwrap(
                {"code": ERR_SIGNATURE, "msg": "Signature authentication failed"}
            )
        assert ERR_SIGNATURE in str(exc.value)

    def test_plain_success_envelope_passes(self) -> None:
        payload = {"code": "0", "msg": "ok", "data": {"chargeLevel": 50}}
        assert LiveZeekrClient._unwrap(payload) is payload

    def test_code_zero_without_success_passes(self) -> None:
        payload = {"code": "0", "msg": "ok"}
        assert LiveZeekrClient._unwrap(payload) is payload

    def test_explicit_success_false_raises(self) -> None:
        with pytest.raises(ZeekrAPIError):
            LiveZeekrClient._unwrap({"code": "12345", "success": False, "msg": "nope"})

    def test_non_dict_raises(self) -> None:
        with pytest.raises(ZeekrAPIError):
            LiveZeekrClient._unwrap(["not", "a", "dict"])


# MARK: - B2 query 编码分叉防护


class TestQuerySignableGuard:
    """签名用的转义规则与 httpx 的 `params=` 编码只对"无特殊字符"的值一致。

    修之前：没有任何防护。以后有人传入含 `*` / `/` / `?` 的值时，签名串与
    实际发送字节会分叉，网关报 079025 而签名"看起来"是对的 —— 极难定位。
    """

    def test_plain_values_pass(self) -> None:
        LiveZeekrClient._assert_query_signable(
            {"latest": "false", "target": "new", "vin": "L6T7841Z0PN000001"}
        )

    def test_empty_and_none_pass(self) -> None:
        LiveZeekrClient._assert_query_signable(None)
        LiveZeekrClient._assert_query_signable({})

    @pytest.mark.parametrize("bad", ["a*b", "a/b", "a?b", "中文", "has space", "50%"])
    def test_special_characters_are_rejected(self, bad: str) -> None:
        with pytest.raises(ZeekrAPIError):
            LiveZeekrClient._assert_query_signable({"q": bad})


# MARK: - B5 VIN 加密前置校验


class TestEncryptVinValidation:
    """密钥/IV 长度不足时给出明确错误，而不是让 AES.new 抛晦涩异常。"""

    def test_valid_input_returns_base64(self) -> None:
        out = encrypt_vin("L6TDEMOCK00000001", "0123456789abcdef", "abcdef0123456789")
        assert len(base64.b64decode(out)) % 16 == 0

    def test_short_key_raises(self) -> None:
        with pytest.raises(ValueError, match="ZEEKR_VIN_KEY"):
            encrypt_vin("L6TDEMOCK00000001", "short", "abcdef0123456789")

    def test_short_iv_raises(self) -> None:
        with pytest.raises(ValueError, match="ZEEKR_VIN_IV"):
            encrypt_vin("L6TDEMOCK00000001", "0123456789abcdef", "short")

    def test_empty_vin_raises(self) -> None:
        with pytest.raises(ValueError, match="VIN"):
            encrypt_vin("", "0123456789abcdef", "abcdef0123456789")

    def test_non_ascii_vin_raises(self) -> None:
        with pytest.raises(ValueError, match="ASCII"):
            encrypt_vin("车辆识别码", "0123456789abcdef", "abcdef0123456789")


# MARK: - A2 登录态需检测过期


def _make_jwt(exp: int | None = None, raw_payload: str | None = None) -> str:
    """造一个只用于解析的 JWT（不验签）。"""
    if raw_payload is not None:
        payload = raw_payload
    else:
        body = json.dumps({"exp": exp} if exp is not None else {"sub": "x"})
        payload = base64.urlsafe_b64encode(body.encode()).decode().rstrip("=")
    return f"eyJhbGciOiJIUzI1NiJ9.{payload}.sig"


def _bare_client(session: dict[str, Any]) -> LiveZeekrClient:
    """构造一个不触发登录的客户端，只用于验证会话判断。"""
    client = LiveZeekrClient.__new__(LiveZeekrClient)
    client._session = session
    return client


class TestSessionExpiry:
    """`is_authenticated` 不能只看"令牌存在"。

    修之前：会话是落盘复用的，重启后磁盘上的 gw1_jwt 可能早已过期，
    但设置页仍显示「已登录」，用户点什么都失败。
    """

    def test_parses_exp_claim(self) -> None:
        assert _jwt_expires_at(_make_jwt(exp=2_000_000_000)) == 2_000_000_000

    def test_unparseable_token_returns_none(self) -> None:
        assert _jwt_expires_at("not-a-jwt") is None
        assert _jwt_expires_at(_make_jwt(raw_payload="!!!not-base64!!!")) is None

    def test_missing_exp_returns_none(self) -> None:
        assert _jwt_expires_at(_make_jwt()) is None

    def test_expired_token_is_not_authenticated(self) -> None:
        client = _bare_client({"gw1_jwt": _make_jwt(exp=1_000_000_000)})  # 2001 年
        assert asyncio.run(client.is_authenticated()) is False

    def test_fresh_token_is_authenticated(self) -> None:
        client = _bare_client({"gw1_jwt": _make_jwt(exp=4_000_000_000)})  # 2096 年
        assert asyncio.run(client.is_authenticated()) is True

    def test_no_token_is_not_authenticated(self) -> None:
        assert asyncio.run(_bare_client({}).is_authenticated()) is False

    def test_unparseable_token_keeps_legacy_behavior(self) -> None:
        """读不出 exp 时沿用旧行为（视为有效）—— 宁可漏判过期，也不要误踢用户下线。"""
        assert asyncio.run(_bare_client({"gw1_jwt": "opaque"}).is_authenticated()) is True

    def test_server_conflict_code_is_known(self) -> None:
        """079021 同时是"会话被顶替"与"已知错误码"，两条逻辑都要认得它。"""
        assert ERR_LOGGED_IN_ELSEWHERE in KNOWN_ERROR_CODES
        assert ERR_UNAUTHORIZED in KNOWN_ERROR_CODES


# MARK: - D4 写入笔数语义


class TestSaveChargesReturnValue:
    """`save_charges` 应返回**实际写入**的条数。

    修之前：用 INSERT OR IGNORE 却 return len(rows)，把被忽略的重复行也算进去，
    调用方据此判断"导入了几笔"会偏大。
    """

    @staticmethod
    def _store() -> Store:
        return Store(Path(tempfile.mkdtemp()) / "t.db")

    @staticmethod
    def _charge(record_id: str, amount: float = 10.0) -> dict[str, Any]:
        return {
            "recordId": record_id,
            "timestamp": "2026-09-01 10:00:00",
            "amount": amount,
            "provider": "zeekr",
        }

    def test_returns_actual_inserted_count(self) -> None:
        store = self._store()
        assert store.save_charges([self._charge("a"), self._charge("b")]) == 2

    def test_duplicates_are_not_counted(self) -> None:
        store = self._store()
        store.save_charges([self._charge("a"), self._charge("b")])
        assert store.save_charges([self._charge("a"), self._charge("b")]) == 0
        assert store.save_charges(
            [self._charge("a"), self._charge("b"), self._charge("c")]
        ) == 1

    def test_empty_input_returns_zero(self) -> None:
        assert self._store().save_charges([]) == 0


# MARK: - D5 连接生命周期


class TestConnectionLifecycle:
    """`_connect()` 必须显式关闭连接。

    修之前：`with sqlite3.connect(...) as conn` 只提交事务、**不 close()**，
    句柄依赖 GC 回收。
    """

    def test_connection_is_closed_after_block(self) -> None:
        store = Store(Path(tempfile.mkdtemp()) / "t.db")
        with store._connect() as conn:
            conn.execute("SELECT 1")
        with pytest.raises(Exception):
            conn.execute("SELECT 1")   # 已关闭的连接再操作必然报错

    def test_rollback_on_exception_then_usable(self) -> None:
        store = Store(Path(tempfile.mkdtemp()) / "t.db")
        with pytest.raises(RuntimeError):
            with store._connect() as conn:
                conn.execute("SELECT 1")
                raise RuntimeError("boom")
        # 连接已关闭，但库本身仍可用
        assert store.list_charges() == []


# MARK: - D6 汇总口径


class TestSummaryWindow:
    """汇总的总额/笔数与月度/服务商分布必须是**同一范围**。

    修之前：总额与笔数统计全量历史，月度列表被截成最近 N 个月，
    前端把两者并排展示时会让人以为同范围。
    """

    def test_reports_window_months(self) -> None:
        summary = build_summary([{"timestamp": "2026-09-01 10:00:00", "amount": 10.0}], months=3)
        assert summary["windowMonths"] == 3

    def test_out_of_window_charges_are_excluded_everywhere(self) -> None:
        charges = [
            {"timestamp": "2026-09-01 10:00:00", "amount": 100.0, "provider": "zeekr"},
            {"timestamp": "2020-01-01 10:00:00", "amount": 900.0, "provider": "teld"},
        ]
        summary = build_summary(charges, months=6)
        assert summary["totalAmount"] == 100.0, "窗口外的记录不该计入总额"
        assert summary["totalCount"] == 1
        assert {p["provider"] for p in summary["byProvider"]} == {"zeekr"}
        assert all(m["month"] != "2020-01" for m in summary["monthly"])

    def test_empty_window_returns_honest_nulls(self) -> None:
        summary = build_summary([], months=6)
        assert summary["totalAmount"] == 0.0
        assert summary["totalCount"] == 0
        assert summary["totalEnergyKwh"] is None
        assert summary["avgUnitPrice"] is None
        assert summary["monthly"] == []
        assert summary["windowMonths"] == 6


# MARK: - B4 编码探测不再静默丢字节


class TestDecodeNoSilentByteLoss:
    """无法可靠解码时必须明确失败，而不是 `errors="ignore"` 丢掉字节。

    修之前：静默丢字节会把**编码问题伪装成「未找到表头行」**，
    用户看到"格式不对"，真正原因是编码读不了，排障方向被带偏。
    """

    def test_returns_none_when_nothing_decodes(self, monkeypatch: pytest.MonkeyPatch) -> None:
        monkeypatch.setattr("app.bills.parsers.CANDIDATE_ENCODINGS", ("ascii",))
        assert _decode(b"\xff\xfe\x00\x01") is None

    def test_parse_bill_reports_encoding_problem(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        monkeypatch.setattr("app.bills.parsers.CANDIDATE_ENCODINGS", ("ascii",))
        result = parse_bill(b"\xff\xfe\x00\x01", source="auto")
        assert result["success"] is False
        assert "编码" in result["message"], "应明确指出是编码问题，而不是含糊的格式问题"

    def test_utf8_bom_still_works(self) -> None:
        text = "交易时间,金额,收/支\n2026-09-01 10:00:00,10.00,支出\n"
        assert _decode(text.encode("utf-8-sig")) is not None

    def test_gbk_still_works(self) -> None:
        text = "交易时间,金额,收/支\n2026-09-01 10:00:00,10.00,支出\n"
        assert _decode(text.encode("gbk")) is not None


# MARK: - B3 列名包含匹配取最短


class TestColumnFallbackPicksShortest:
    """同一别名命中多列时取**列名最短**的。

    修之前：第一个命中就用 —— 表头若没有精确的「金额」而存在
    「商品优惠金额」「金额说明」，会取到前者。
    """

    def test_shortest_matching_column_wins(self) -> None:
        header = [
            "交易时间",
            "交易对方",
            "商品优惠金额",
            "金额说明",
            "收/支",
            "交易状态",
            "交易单号",
        ]
        from app.bills.parsers import _map_columns

        mapping = _map_columns(header)
        assert mapping["amount"] == header.index("金额说明"), "应取列名更短、歧义更小的那列"

    def test_exact_match_still_preferred(self) -> None:
        header = ["交易时间", "优惠金额", "金额", "收/支", "交易单号"]
        from app.bills.parsers import _map_columns

        mapping = _map_columns(header)
        assert mapping["amount"] == header.index("金额"), "精确匹配优先于包含匹配"


# MARK: - D1 xlsx 账单导入


def _build_xlsx_bill() -> bytes:
    """构造一份微信风格的 xlsx 账单。"""
    from openpyxl import Workbook

    workbook = Workbook()
    sheet = workbook.active
    sheet.append(["微信支付账单明细"])
    sheet.append(["微信昵称：[测试用户]"])
    sheet.append([])
    sheet.append([
        "交易时间", "交易类型", "交易对方", "商品", "收/支",
        "金额(元)", "支付方式", "当前状态", "交易单号", "商户单号",
    ])
    sheet.append([
        "2026-09-01 10:30:00", "商户消费", "极氪极充广州站", "充电服务费", "支出",
        "88.50", "零钱", "支付成功", "420001", "4200001",
    ])
    sheet.append([
        "2026-09-05 16:45:00", "商户消费", "星星充电", "充电订单", "支出",
        "72.80", "零钱", "支付成功", "420002", "4200002",
    ])
    sheet.append([
        "2026-09-06 12:00:00", "商户消费", "美团外卖", "餐饮", "支出",
        "42.00", "零钱", "支付成功", "420003", "4200003",
    ])
    sheet.append(["共3笔记录"])

    buffer = io.BytesIO()
    workbook.save(buffer)
    return buffer.getvalue()


class TestXlsxImport:
    """服务端要能读 xlsx。

    修之前：iOS 的文件选择器允许选 .spreadsheet，服务端却只收 csv/txt ——
    两端契约不一致，而微信「用于个人对账」的导出常用 Excel 格式，用户直接撞墙。
    """

    def test_xlsx_is_parsed(self) -> None:
        result = parse_bill(_build_xlsx_bill(), source="auto")
        assert result["success"] is True
        assert result["total"] == 3
        assert sorted(r["amount"] for r in result["records"]) == [42.0, 72.8, 88.5]

    def test_xlsx_charges_are_extracted(self) -> None:
        from app.bills.aggregator import extract_charges

        parsed = parse_bill(_build_xlsx_bill(), source="auto")
        charges = extract_charges(parsed["records"])
        assert len(charges) == 2, "外卖不该被当成充电消费"
        assert {c["provider"] for c in charges} == {"zeekr", "starCharge"}

    def test_broken_xlsx_gives_clear_error(self) -> None:
        result = parse_bill(b"PK\x03\x04this-is-not-a-real-xlsx", source="auto")
        assert result["success"] is False
        assert "Excel" in result["message"]

    def test_csv_still_works(self) -> None:
        csv_bytes = (
            "交易时间,交易对方,商品说明,收/支,金额,支付方式,交易状态,交易单号\n"
            "2026-09-01 10:30:00,极氪极充,充电服务费,支出,-88.50,余额宝,交易成功,1\n"
        ).encode("utf-8")
        result = parse_bill(csv_bytes, source="alipay")
        assert result["success"] is True
        assert result["total"] == 1


# MARK: - P1-5 API 令牌鉴权


class TestApiTokenMiddleware:
    """设了 `API_TOKEN` 才启用鉴权，且只保护 `/api/*`（放行 health）。

    修之前：服务端监听 0.0.0.0 且完全没有鉴权，开启车控后局域网内
    任何人都能 POST /api/vehicle/command 解锁车辆。
    """

    @staticmethod
    def _client():
        from fastapi.testclient import TestClient

        from app.main import app

        return TestClient(app)

    def test_disabled_by_default(self) -> None:
        from app.core.config import config

        assert config.api_token == ""
        client = self._client()
        assert client.get("/api/vehicle/list").status_code == 200

    def test_requires_token_when_enabled(self, monkeypatch: pytest.MonkeyPatch) -> None:
        from app.core.config import config

        monkeypatch.setattr(config, "api_token", "s3cret")
        client = self._client()

        assert client.get("/api/health").status_code == 200, "健康检查必须放行（连接诊断要用）"
        assert client.get("/preview").status_code == 200, "非 /api/* 放行"

        denied = client.get("/api/vehicle/list")
        assert denied.status_code == 401
        assert "令牌" in denied.json()["detail"]

        assert client.get(
            "/api/vehicle/list", headers={"Authorization": "Bearer wrong"}
        ).status_code == 401
        assert client.get(
            "/api/vehicle/list", headers={"Authorization": "Bearer s3cret"}
        ).status_code == 200
        assert client.get(
            "/api/vehicle/list", headers={"Authorization": "bearer s3cret"}
        ).status_code == 200, "Bearer 前缀大小写不敏感"
        assert client.get("/api/vehicle/list?token=s3cret").status_code == 200, (
            "要支持 ?token= 以便浏览器打开 /preview"
        )


# MARK: - D7 三处 mock 数据一致性


class TestMockDataConsistency:
    """三处模拟数据必须一致。

    修之前：靠注释里一句"请同步修改"约束，零自动化校验；实测服务端 mock
    与 iOS/预览页的车辆身份三件套**已经不一致**（服务端是 我的极氪 001 /
    粤A·D88888 / 极氪 001），导致同一台手机在「localhost 模式」和
    「连服务端」两种情况下显示成两台不同的车。
    """

    REPO_ROOT = Path(__file__).resolve().parent.parent.parent

    @staticmethod
    def _from_swift(text: str, field: str) -> str | None:
        match = re.search(rf'{field}:\s*"([^"]*)"', text)
        return match.group(1) if match else None

    @staticmethod
    def _from_preview(text: str, field: str) -> str | None:
        start = text.find("const MOCK")
        assert start >= 0, "preview/index.html 里找不到 MOCK 常量"
        segment = text[start:start + 4000]
        match = re.search(rf'{field}:\s*[\'"]([^\'"]*)[\'"]', segment)
        return match.group(1) if match else None

    def test_vehicle_identity_matches_across_three_sources(self) -> None:
        swift_text = (self.REPO_ROOT / "ZeekrDash/Core/Mock/MockData.swift").read_text("utf-8")
        preview_text = (self.REPO_ROOT / "preview/index.html").read_text("utf-8")
        server = asyncio.run(MockZeekrClient().get_vehicle_status())

        for field, server_key in (
            ("nickname", "nickname"),
            ("plateNo", "plateNo"),
            ("modelName", "modelName"),
        ):
            swift_value = self._from_swift(swift_text, field)
            preview_value = self._from_preview(preview_text, field)
            server_value = server[server_key]

            assert swift_value, f"MockData.swift 里没解析到 {field}"
            assert preview_value, f"preview/index.html 里没解析到 {field}"
            assert swift_value == preview_value == server_value, (
                f"{field} 三处不一致："
                f"MockData.swift={swift_value!r} "
                f"preview={preview_value!r} "
                f"mock_client.py={server_value!r}"
            )

    def test_server_mock_vin_is_obviously_fake(self) -> None:
        """VIN 故意用 L6TDEMOCK... —— 不会被界面展示，但要一眼看出是假的。"""
        assert "MOCK" in mock_module.MOCK_VIN.upper()
