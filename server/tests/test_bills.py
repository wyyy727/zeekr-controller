"""账单解析与充电消费归集的测试。

运行：python3 -m pytest tests/ -v
"""

from __future__ import annotations

import csv
import io
import sys
from datetime import datetime, timedelta
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from app.bills.aggregator import build_summary, extract_charges
from app.bills.parsers import parse_bill
from app.bills.providers import detect_provider, is_excluded


# MARK: - 服务商识别


class TestProviderDetection:
    """服务商关键词识别。"""

    @pytest.mark.parametrize("merchant,expected", [
        ("极氪极充-ZEEKR Power广州天河站", "zeekr"),
        ("浙江极氪智能科技有限公司", "zeekr"),
        ("特来电新能源股份有限公司", "teld"),
        ("星星充电-万帮新能源科技", "starCharge"),
        ("国家电网电动汽车服务有限公司", "stateGrid"),
        ("小桔充电", "eCharging"),
        ("云快充", "eCharging"),
        ("依威能源", "eCharging"),
    ])
    def test_recognizes_known_providers(self, merchant: str, expected: str) -> None:
        assert detect_provider(merchant) == expected

    @pytest.mark.parametrize("merchant", [
        "广州天河城购物中心",
        "美团外卖",
        "星巴克咖啡",
        "中国石化加油站",
        "滴滴出行",
    ])
    def test_ignores_non_charging(self, merchant: str) -> None:
        assert detect_provider(merchant) is None

    def test_word_length_priority(self) -> None:
        """长关键词必须优先，避免短泛词抢先命中。

        「小桔充电」含「充电」（泛词）与「小桔充电」（具体词），
        必须命中具体词而非退化成 other。
        """
        assert detect_provider("小桔充电") == "eCharging"

    @pytest.mark.parametrize("merchant", [
        "Anker 充电宝租赁",
        "绿联充电线旗舰店",
        "小米充电器专卖",
    ])
    def test_excludes_accessories(self, merchant: str) -> None:
        """充电宝/充电线等配件不能被误判为充电消费。"""
        assert detect_provider(merchant) is None
        assert is_excluded(merchant)


# MARK: - 账单解析


def _make_alipay_csv(rows: list[list[str]]) -> bytes:
    """构造支付宝格式账单（GBK 编码，金额带负号）。"""
    header = ["交易时间", "交易对方", "商品说明", "收/支", "金额", "支付方式", "交易状态", "交易单号"]
    content = [
        ["支付宝交易记录明细查询"],
        ["账号:[138****8000]"],
        ["---------------------------------交易记录明细列表------------------------------------"],
        header,
        *rows,
        ["共%d笔记录" % len(rows)],
    ]
    buffer = io.StringIO()
    csv.writer(buffer).writerows(content)
    return buffer.getvalue().encode("gbk")


def _make_wechat_csv(rows: list[list[str]]) -> bytes:
    """构造微信格式账单（UTF-8 BOM，金额带 ¥，表头前有说明行）。"""
    header = ["交易时间", "交易类型", "交易对方", "商品", "收/支", "金额(元)", "支付方式", "当前状态", "交易单号", "商户单号"]
    content = [
        ["微信支付账单明细"],
        ["微信昵称：[测试用户]"],
        ["起始时间：[2026-06-01] 终止时间：[2026-09-17]"],
    ]
    content.extend([[""] for _ in range(14)])
    content.append(header)
    content.extend(rows)
    buffer = io.StringIO()
    csv.writer(buffer).writerows(content)
    return buffer.getvalue().encode("utf-8-sig")


class TestBillParsing:
    """账单文件解析。"""

    def test_parses_alipay_gbk(self) -> None:
        """支付宝账单是 GBK 编码，需自动识别。"""
        rows = [
            ["2026-09-15 14:30:00", "特来电新能源股份有限公司", "充电费用", "支出", "-68.50", "余额宝", "交易成功", "20260915001"],
            ["2026-09-14 09:15:00", "美团外卖", "餐饮", "支出", "-35.00", "余额宝", "交易成功", "20260914002"],
        ]
        result = parse_bill(_make_alipay_csv(rows), source="alipay")

        assert result["success"]
        assert result["total"] == 2
        assert result["records"][0]["amount"] == 68.50  # 支出取绝对值
        assert result["records"][0]["merchant"] == "特来电新能源股份有限公司"

    def test_parses_wechat_with_bom_and_header_offset(self) -> None:
        """微信账单是 UTF-8 BOM，表头前有 17 行说明。"""
        rows = [
            ["2026-09-15 14:30:00", "商户消费", "小桔充电", "充电服务", "支出", "¥88.00", "零钱", "支付成功", "420001", "421"],
            ["2026-09-14 10:00:00", "商户消费", "星巴克", "餐饮", "支出", "¥45.00", "零钱", "支付成功", "420002", "422"],
        ]
        result = parse_bill(_make_wechat_csv(rows), source="wechat")

        assert result["success"]
        assert result["total"] == 2
        assert result["records"][0]["amount"] == 88.00  # 去掉 ¥ 符号

    def test_only_keeps_expenses(self) -> None:
        """只保留支出，剔除收入。"""
        rows = [
            ["2026-09-15 14:30:00", "特来电", "充电", "支出", "-68.50", "余额宝", "成功", "1"],
            ["2026-09-15 10:00:00", "某公司", "退款", "收入", "100.00", "余额宝", "成功", "2"],
            ["2026-09-15 09:00:00", "某人", "转账", "不计收支", "50.00", "余额宝", "成功", "3"],
        ]
        result = parse_bill(_make_alipay_csv(rows), source="alipay")

        assert result["total"] == 1
        assert result["records"][0]["merchant"] == "特来电"

    def test_rejects_empty_file(self) -> None:
        result = parse_bill(b"", source="auto")
        assert not result["success"]

    def test_rejects_file_without_header(self) -> None:
        result = parse_bill("这是一段无关文本\n没有任何表头".encode("utf-8"), source="auto")
        assert not result["success"]
        assert "表头" in result["message"]


# MARK: - 充电消费提取与去重


class TestExtraction:
    """充电消费提取。"""

    def test_extracts_only_charging(self) -> None:
        records = [
            {"timestamp": "2026-09-15 14:30:00", "amount": 68.50, "merchant": "特来电新能源", "description": "充电"},
            {"timestamp": "2026-09-15 12:00:00", "amount": 35.00, "merchant": "美团外卖", "description": "餐饮"},
            {"timestamp": "2026-09-14 09:00:00", "amount": 88.00, "merchant": "小桔充电", "description": "充电"},
        ]
        charges = extract_charges(records)

        assert len(charges) == 2
        assert {c["provider"] for c in charges} == {"teld", "eCharging"}

    def test_dedups_same_minute_and_amount(self) -> None:
        """同一分钟、同一金额视为重复（跨平台去重）。"""
        records = [
            {"timestamp": "2026-09-15 14:30:05", "amount": 68.50, "merchant": "特来电", "description": "充电"},
            {"timestamp": "2026-09-15 14:30:48", "amount": 68.50, "merchant": "特来电", "description": "充电"},
        ]
        charges = extract_charges(records)
        assert len(charges) == 1

    def test_keeps_different_amounts_same_minute(self) -> None:
        """同一分钟但金额不同，视为两笔。"""
        records = [
            {"timestamp": "2026-09-15 14:30:00", "amount": 68.50, "merchant": "特来电", "description": "充电"},
            {"timestamp": "2026-09-15 14:30:00", "amount": 32.00, "merchant": "小桔充电", "description": "充电"},
        ]
        assert len(extract_charges(records)) == 2

    def test_sorted_by_time_desc(self) -> None:
        records = [
            {"timestamp": "2026-09-10 10:00:00", "amount": 10.0, "merchant": "特来电", "description": "充电"},
            {"timestamp": "2026-09-15 10:00:00", "amount": 20.0, "merchant": "特来电", "description": "充电"},
        ]
        charges = extract_charges(records)
        assert charges[0]["timestamp"] > charges[1]["timestamp"]


# MARK: - 汇总统计


class TestSummary:
    """汇总统计。"""

    def test_empty_input(self) -> None:
        summary = build_summary([])
        assert summary["totalAmount"] == 0.0
        assert summary["totalCount"] == 0
        assert summary["monthly"] == []

    def test_aggregates_by_month_and_provider(self) -> None:
        charges = [
            {"timestamp": "2026-09-15 10:00:00", "amount": 100.0, "provider": "teld", "energyKwh": None},
            {"timestamp": "2026-09-10 10:00:00", "amount": 50.0, "provider": "teld", "energyKwh": None},
            {"timestamp": "2026-08-20 10:00:00", "amount": 80.0, "provider": "zeekr", "energyKwh": None},
        ]
        summary = build_summary(charges, months=6)

        assert summary["totalAmount"] == 230.0
        assert summary["totalCount"] == 3

        months = {m["month"]: m for m in summary["monthly"]}
        assert months["2026-09"]["amount"] == 150.0
        assert months["2026-09"]["count"] == 2
        assert months["2026-08"]["amount"] == 80.0

        providers = {p["provider"]: p for p in summary["byProvider"]}
        assert providers["teld"]["amount"] == 150.0
        assert providers["zeekr"]["amount"] == 80.0

    def test_computes_unit_price_when_energy_available(self) -> None:
        charges = [
            {"timestamp": "2026-09-15 10:00:00", "amount": 100.0, "provider": "teld", "energyKwh": 50.0},
        ]
        summary = build_summary(charges)
        assert summary["avgUnitPrice"] == 2.0
        assert summary["totalEnergyKwh"] == 50.0

    def test_unit_price_none_without_energy(self) -> None:
        """账单里通常没有电量数据，此时不应编造单价。"""
        charges = [
            {"timestamp": "2026-09-15 10:00:00", "amount": 100.0, "provider": "teld", "energyKwh": None},
        ]
        summary = build_summary(charges)
        assert summary["avgUnitPrice"] is None
        assert summary["totalEnergyKwh"] is None


# MARK: - 端到端


class TestEndToEnd:
    """完整链路：文件 → 解析 → 归集 → 汇总。"""

    def test_full_pipeline(self) -> None:
        now = datetime.now()
        rows = []
        for i in range(10):
            ts = (now - timedelta(days=i)).strftime("%Y-%m-%d %H:%M:%S")
            provider = ["特来电新能源", "小桔充电", "星星充电", "极氪极充"][i % 4]
            rows.append([ts, provider, "充电费用", "支出", f"-{50 + i}", "余额宝", "成功", f"{i}"])

        parsed = parse_bill(_make_alipay_csv(rows), source="alipay")
        assert parsed["success"]
        assert parsed["total"] == 10

        charges = extract_charges(parsed["records"])
        assert len(charges) == 10

        summary = build_summary(charges)
        assert summary["totalCount"] == 10
        assert summary["totalAmount"] == sum(50 + i for i in range(10))
        assert len(summary["byProvider"]) == 4
