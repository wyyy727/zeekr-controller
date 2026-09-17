"""核心逻辑单元测试。

覆盖范围：
- GW3 签名算法的确定性与格式
- VIN 加密
- 账单解析（支付宝 GBK / 微信 UTF-8 BOM）
- 服务商识别与排除词
- 跨平台去重
- 汇总统计

运行：python -m pytest tests/ -v
"""

from __future__ import annotations

import base64
import csv
import io
import sys
from datetime import datetime, timedelta
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from app.adapters.zeekr_signing import (  # noqa: E402
    COMMAND_MAP,
    build_control_body,
    compact_json,
    encrypt_vin,
    sign_gw3,
)
from app.bills.aggregator import build_summary, extract_charges  # noqa: E402
from app.bills.parsers import parse_bill  # noqa: E402
from app.bills.providers import detect_provider, is_excluded  # noqa: E402


# MARK: - 签名


class TestSigning:
    """签名与加密算法测试。"""

    def test_gw3_signature_is_base64(self) -> None:
        """GW3 签名必须是 44 字符的 Base64（HMAC-SHA256 摘要长度）。"""
        signature = sign_gw3(
            prod_secret="test_secret_value",
            method="POST",
            path="/test/path",
            headers={"X-APP-ID": "ZEEKRCNCH001M0001"},
            body='{"a":1}',
        )
        assert len(signature) == 44
        # 校验确实是合法 Base64
        assert base64.b64decode(signature)

    def test_gw3_signature_is_deterministic(self) -> None:
        """相同输入必须产生相同签名（不可引入随机量）。"""
        kwargs = {
            "prod_secret": "secret",
            "method": "GET",
            "path": "/api/status",
            "headers": {"X-APP-ID": "ZEEKRCNCH001M0001"},
            "query": {"b": "2", "a": "1"},
        }
        assert sign_gw3(**kwargs) == sign_gw3(**kwargs)

    def test_gw3_signature_differs_on_body(self) -> None:
        """请求体变化必须导致签名变化。"""
        base = {
            "prod_secret": "secret",
            "method": "POST",
            "path": "/api",
            "headers": {"X-APP-ID": "id"},
        }
        assert sign_gw3(body='{"a":1}', **base) != sign_gw3(body='{"a":2}', **base)

    def test_gw3_excludes_timestamp_header(self) -> None:
        """X-TIMESTAMP 是普通头，不参与签名。

        GW1 的 x-api* 过滤规则决定了：只有 x-api 开头的头才进签名串。
        """
        base = {
            "prod_secret": "secret",
            "method": "POST",
            "path": "/api",
            "body": "{}",
        }
        sig1 = sign_gw3(headers={"X-APP-ID": "id", "X-TIMESTAMP": "111"}, **base)
        sig2 = sign_gw3(headers={"X-APP-ID": "id", "X-TIMESTAMP": "999"}, **base)
        assert sig1 == sig2, "X-TIMESTAMP 不应参与签名"

    def test_gw3_query_escapes_asterisk(self) -> None:
        """query 中的 `*` 需转义为 %2A（与官方 App 一致）。"""
        base = {
            "prod_secret": "secret",
            "method": "GET",
            "path": "/api",
            "headers": {"X-APP-ID": "id"},
        }
        sig_star = sign_gw3(query={"q": "*"}, **base)
        sig_escaped = sign_gw3(query={"q": "%2A"}, **base)
        assert sig_star == sig_escaped

    def test_encrypt_vin_produces_ciphertext(self) -> None:
        """VIN 加密结果必须是可解码的 Base64，且长度达标。"""
        ciphertext = encrypt_vin(
            vin="L6TDEMOCK00000001",
            vin_key="0123456789abcdef",
            vin_iv="abcdef0123456789",
        )
        decoded = base64.b64decode(ciphertext)
        assert len(decoded) % 16 == 0, "AES 块大小必须为 16 字节的整数倍"
        assert len(ciphertext) >= 17, "网关要求 X-VIN 至少 17 字符"

    def test_control_body_structure(self) -> None:
        """远程控制体的层级结构必须正确。

        serviceParameters **嵌在 setting 里** —— 这是网关的硬性要求。
        """
        body = build_control_body("ZAF", "AC", "true")
        assert body["command"] == "start"
        assert body["serviceId"] == "ZAF"
        assert "setting" in body
        assert "serviceParameters" in body["setting"]
        assert body["setting"]["serviceParameters"][0] == {"key": "AC", "value": "true"}

    def test_compact_json_has_no_spaces(self) -> None:
        """紧凑 JSON —— 签名串含请求体 MD5，字节必须与发送内容一致。"""
        result = compact_json({"a": 1, "b": "中文"})
        assert " " not in result
        assert result == '{"a":1,"b":"中文"}'

    def test_command_map_covers_all_commands(self) -> None:
        """命令映射表应覆盖前端声明的全部指令。"""
        expected = {
            "lock", "unlock", "climateOn", "climateOff",
            "flash", "honk", "chargeStart", "chargeStop",
        }
        assert set(COMMAND_MAP.keys()) == expected
        for command, trio in COMMAND_MAP.items():
            assert len(trio) == 3, f"{command} 应为 (serviceId, key, value) 三元组"


# MARK: - 服务商识别


class TestProviderDetection:
    """充电服务商识别测试。"""

    @pytest.mark.parametrize("merchant,expected", [
        ("极氪极充-ZEEKR Power广州天河站", "zeekr"),
        ("极氪能源科技", "zeekr"),
        ("特来电新能源股份有限公司", "teld"),
        ("星星充电-万帮新能源科技", "starCharge"),
        ("国家电网电动汽车服务有限公司", "stateGrid"),
        ("小桔充电", "eCharging"),
        ("e充电", "eCharging"),
        ("云快充", "eCharging"),
    ])
    def test_known_providers(self, merchant: str, expected: str) -> None:
        """已知服务商应被正确识别。"""
        assert detect_provider(merchant) == expected

    def test_xiaoju_not_misclassified_as_echarging(self) -> None:
        """小桔充电不应被误认为 e充电。

        两者共用「充电」子串，必须靠长词优先匹配来区分。
        """
        assert detect_provider("小桔充电") == "eCharging"

    @pytest.mark.parametrize("merchant", [
        "Anker 充电宝租赁",
        "小米充电线旗舰店",
        "手机充电器专卖",
        "Apple 数据线",
    ])
    def test_excluded_items(self, merchant: str) -> None:
        """充电宝/充电线等不应被识别为充电消费。"""
        assert detect_provider(merchant) is None
        assert is_excluded(merchant) is True

    @pytest.mark.parametrize("merchant", [
        "广州天河城购物中心",
        "美团外卖",
        "星巴克咖啡",
        "中石化加油站",
    ])
    def test_non_charge_merchants(self, merchant: str) -> None:
        """普通消费不应被识别。"""
        assert detect_provider(merchant) is None


# MARK: - 账单解析


def _build_alipay_csv() -> bytes:
    """构造支付宝格式账单（GBK 编码，金额带负号）。"""
    rows = [
        ["支付宝交易记录明细查询"],
        ["账号:[138****8000]"],
        ["---------------------------------交易记录明细列表------------------------------------"],
        ["交易时间", "交易对方", "商品说明", "收/支", "金额", "支付方式", "交易状态", "交易单号"],
        ["2026-09-01 10:30:00", "极氪极充广州站", "充电服务费", "支出", "-88.50", "余额宝", "交易成功", "2026001"],
        ["2026-09-02 14:20:00", "特来电新能源", "充电费用", "支出", "-56.30", "余额宝", "交易成功", "2026002"],
        ["2026-09-03 09:00:00", "星巴克咖啡", "餐饮", "支出", "-35.00", "余额宝", "交易成功", "2026003"],
        ["2026-09-04 08:00:00", "某商户", "退款", "收入", "20.00", "余额宝", "交易成功", "2026004"],
        ["共4笔记录"],
    ]
    buffer = io.StringIO()
    csv.writer(buffer).writerows(rows)
    return buffer.getvalue().encode("gbk")


def _build_wechat_csv() -> bytes:
    """构造微信格式账单（UTF-8 BOM，金额带 ¥ 前缀）。"""
    rows = [
        ["微信支付账单明细"],
        ["微信昵称：[测试用户]"],
        ["起始时间：[2026-09-01 00:00:00] 终止时间：[2026-09-30 00:00:00]"],
    ]
    for _ in range(14):
        rows.append([""])
    rows.append([
        "交易时间", "交易类型", "交易对方", "商品", "收/支",
        "金额(元)", "支付方式", "当前状态", "交易单号", "商户单号",
    ])
    rows.append([
        "2026-09-01 10:30:00", "商户消费", "极氪极充广州站", "充电服务费", "支出",
        "¥88.50", "零钱", "支付成功", "420001", "4200001",
    ])
    rows.append([
        "2026-09-05 16:45:00", "商户消费", "星星充电", "充电订单", "支出",
        "¥72.80", "零钱", "支付成功", "420002", "4200002",
    ])
    rows.append([
        "2026-09-06 12:00:00", "商户消费", "美团外卖", "餐饮", "支出",
        "¥42.00", "零钱", "支付成功", "420003", "4200003",
    ])
    rows.append(["共3笔记录"])
    buffer = io.StringIO()
    csv.writer(buffer).writerows(rows)
    return buffer.getvalue().encode("utf-8-sig")


class TestBillParsing:
    """账单解析测试。"""

    def test_parse_alipay_gbk(self) -> None:
        """应能正确解析 GBK 编码的支付宝账单。"""
        result = parse_bill(_build_alipay_csv(), source="alipay")
        assert result["success"] is True
        # 3 笔支出 + 1 笔收入（收入应被过滤）
        assert result["total"] == 3
        assert all(r["amount"] > 0 for r in result["records"])

    def test_parse_wechat_utf8_bom(self) -> None:
        """应能正确解析 UTF-8 BOM 的微信账单，并去掉 ¥ 符号。"""
        result = parse_bill(_build_wechat_csv(), source="wechat")
        assert result["success"] is True
        assert result["total"] == 3
        amounts = sorted(r["amount"] for r in result["records"])
        assert amounts == [42.00, 72.80, 88.50]

    def test_header_detection_skips_preamble(self) -> None:
        """应能跳过账单开头的说明文字，正确定位表头。"""
        result = parse_bill(_build_wechat_csv(), source="wechat")
        assert result["success"] is True
        assert result["records"], "表头定位失败将导致解析不到记录"

    def test_income_records_filtered(self) -> None:
        """收入记录必须被过滤，只保留支出。"""
        result = parse_bill(_build_alipay_csv(), source="alipay")
        assert all(r["merchant"] != "某商户" for r in result["records"])

    def test_summary_row_skipped(self) -> None:
        """表尾的「共N笔记录」统计行不应被当作交易。"""
        result = parse_bill(_build_alipay_csv(), source="alipay")
        assert all("共" not in (r["merchant"] or "") for r in result["records"])

    def test_invalid_file_returns_error(self) -> None:
        """非法文件应返回错误而非抛异常。"""
        result = parse_bill(b"this is not a bill", source="auto")
        assert result["success"] is False
        assert result["records"] == []

    def test_empty_file_returns_error(self) -> None:
        """空文件应返回错误。"""
        result = parse_bill(b"", source="auto")
        assert result["success"] is False


# MARK: - 归集与去重


class TestAggregation:
    """充电消费归集测试。"""

    def test_extract_charges_filters_non_charge(self) -> None:
        """只应保留充电消费。"""
        records = [
            {"timestamp": "2026-09-01 10:00:00", "amount": 88.5, "merchant": "极氪极充", "description": ""},
            {"timestamp": "2026-09-01 12:00:00", "amount": 35.0, "merchant": "星巴克咖啡", "description": ""},
            {"timestamp": "2026-09-02 11:00:00", "amount": 56.3, "merchant": "特来电", "description": ""},
        ]
        charges = extract_charges(records)
        assert len(charges) == 2
        assert {c["provider"] for c in charges} == {"zeekr", "teld"}

    def test_cross_platform_dedup(self) -> None:
        """同一笔消费（同分钟同金额）在跨平台时只应保留一条。"""
        records = [
            {"timestamp": "2026-09-01 10:30:00", "amount": 88.5, "merchant": "极氪极充", "description": ""},
            {"timestamp": "2026-09-01 10:30:15", "amount": 88.5, "merchant": "极氪极充", "description": ""},
        ]
        charges = extract_charges(records)
        assert len(charges) == 1, "同分钟同金额应被识别为重复"

    def test_charges_sorted_desc(self) -> None:
        """结果应按时间倒序。"""
        records = [
            {"timestamp": "2026-09-01 10:00:00", "amount": 10.0, "merchant": "极氪极充", "description": ""},
            {"timestamp": "2026-09-05 10:00:00", "amount": 20.0, "merchant": "特来电", "description": ""},
        ]
        charges = extract_charges(records)
        assert charges[0]["timestamp"] > charges[1]["timestamp"]

    def test_build_summary_totals(self) -> None:
        """汇总金额与笔数应正确。"""
        charges = [
            {"timestamp": "2026-09-01 10:00:00", "amount": 100.0, "provider": "zeekr", "energyKwh": 50.0},
            {"timestamp": "2026-09-02 10:00:00", "amount": 50.0, "provider": "teld", "energyKwh": 25.0},
            {"timestamp": "2026-08-15 10:00:00", "amount": 30.0, "provider": "zeekr", "energyKwh": 15.0},
        ]
        summary = build_summary(charges, months=6)
        assert summary["totalAmount"] == 180.0
        assert summary["totalCount"] == 3
        assert summary["totalEnergyKwh"] == 90.0
        assert summary["avgUnitPrice"] == 2.0

    def test_summary_grouping(self) -> None:
        """应按月与服务商正确分组。"""
        charges = [
            {"timestamp": "2026-09-01 10:00:00", "amount": 100.0, "provider": "zeekr"},
            {"timestamp": "2026-09-15 10:00:00", "amount": 50.0, "provider": "zeekr"},
            {"timestamp": "2026-08-15 10:00:00", "amount": 30.0, "provider": "teld"},
        ]
        summary = build_summary(charges)

        months = {m["month"]: m for m in summary["monthly"]}
        assert months["2026-09"]["amount"] == 150.0
        assert months["2026-09"]["count"] == 2
        assert months["2026-08"]["amount"] == 30.0

        providers = {p["provider"]: p for p in summary["byProvider"]}
        assert providers["zeekr"]["amount"] == 150.0
        # 服务商按金额降序
        assert summary["byProvider"][0]["provider"] == "zeekr"

    def test_build_summary_empty(self) -> None:
        """空输入应返回零值结构而非报错。"""
        summary = build_summary([])
        assert summary["totalAmount"] == 0.0
        assert summary["totalCount"] == 0
        assert summary["monthly"] == []
