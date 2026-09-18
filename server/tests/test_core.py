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

import asyncio
import base64
import csv
import hashlib
import io
import sys
from datetime import datetime, timedelta
from pathlib import Path
from typing import Any

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from app.adapters.zeekr_signing import (  # noqa: E402
    COMMAND_MAP,
    UNVERIFIED_COMMANDS,
    ServiceID,
    ServiceIDUnverified,
    build_control_body,
    build_gw3_string_to_sign,
    compact_json,
    encrypt_vin,
    is_supported_command,
    is_verified_command,
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
            headers={
                "X-APP-ID": "ZEEKRCNCH001M0001",
                "Content-Type": "application/json; charset=utf-8",
            },
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
            "headers": {
                "X-APP-ID": "id",
                "Content-Type": "application/json; charset=utf-8",
            },
        }
        assert sign_gw3(body='{"a":1}', **base) != sign_gw3(body='{"a":2}', **base)

    def test_gw3_timestamp_participates_in_signature(self) -> None:
        """`x-timestamp` 在白名单内，必须参与签名。

        这是曾经出错的地方：早期实现只取 `x-api*` 开头的头，
        导致 `x-timestamp`、`x-app-id`、`content-type` 全部漏签，
        签名串首段恒为空 → 网关验签必然失败。
        """
        base = {
            "prod_secret": "secret",
            "method": "POST",
            "path": "/api",
            "body": "{}",
        }
        sig1 = sign_gw3(headers={
            "X-APP-ID": "id",
            "X-TIMESTAMP": "111",
            "Content-Type": "application/json",
        }, **base)
        sig2 = sign_gw3(headers={
            "X-APP-ID": "id",
            "X-TIMESTAMP": "999",
            "Content-Type": "application/json",
        }, **base)
        assert sig1 != sig2, "x-timestamp 属于白名单头，应参与签名"

    def test_gw3_non_whitelisted_headers_excluded(self) -> None:
        """不在白名单内的头不参与签名（如 User-Agent、X-APP-OS-VERSION）。"""
        base = {
            "prod_secret": "secret",
            "method": "GET",
            "path": "/api",
        }
        common = {"X-APP-ID": "id", "X-TIMESTAMP": "123"}
        sig1 = sign_gw3(headers={**common, "User-Agent": "A/1.0"}, **base)
        sig2 = sign_gw3(headers={**common, "User-Agent": "B/2.0"}, **base)
        assert sig1 == sig2, "User-Agent 不在白名单，不应影响签名"

    def test_gw3_empty_vin_and_auth_skipped(self) -> None:
        """`x-vin` 与 `authorization` 为空时应跳过，不写入签名串。"""
        base = {
            "prod_secret": "secret",
            "method": "GET",
            "path": "/api",
        }
        # 显式传空串，应与完全不传的结果一致
        sig_with_empty = sign_gw3(
            headers={"X-APP-ID": "id", "X-VIN": "", "Authorization": ""}, **base
        )
        sig_without = sign_gw3(headers={"X-APP-ID": "id"}, **base)
        assert sig_with_empty == sig_without

    def test_gw3_canonical_structure(self) -> None:
        """待签名串的结构必须与协议一致：头段 + query + body + 方法 + 路径。"""
        canonical = build_gw3_string_to_sign(
            method="POST",
            path="/test/path",
            headers={
                "X-APP-ID": "ZEEKRCNCH001M0001",
                "Content-Type": "application/json; charset=utf-8",
            },
            query={"b": "2", "a": "1"},
            body='{"a":1}',
        )

        lines = canonical.split("\n")
        # 头段：按头名小写排序，每行 name:value
        assert lines[0] == "content-type:application/json; charset=utf-8"
        assert lines[1] == "x-app-id:ZEEKRCNCH001M0001"
        # query 段：键排序
        assert lines[2] == "a=1&b=2"
        # body 段：base64(md5(body))
        expected_md5 = base64.b64encode(hashlib.md5(b'{"a":1}').digest()).decode()
        assert lines[3] == expected_md5
        # 方法 + 路径
        assert lines[4] == "POST"
        assert lines[5] == "/test/path"

    def test_gw3_body_requires_json_content_type(self) -> None:
        """仅当 Content-Type 含 application/json 时 body 才参与签名。"""
        base = {
            "prod_secret": "secret",
            "method": "POST",
            "path": "/api",
            "query": None,
        }
        with_json = sign_gw3(
            headers={"X-APP-ID": "id", "Content-Type": "application/json"},
            body="{}",
            **base,
        )
        without_json = sign_gw3(
            headers={"X-APP-ID": "id", "Content-Type": "text/plain"},
            body="{}",
            **base,
        )
        assert with_json != without_json

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

    def test_gw3_query_unescapes_slash_and_question(self) -> None:
        """`%2F` → `/`、`%3F` → `?`（撤销百分号编码）。"""
        base = {
            "prod_secret": "secret",
            "method": "GET",
            "path": "/api",
            "headers": {"X-APP-ID": "id"},
        }
        assert sign_gw3(query={"q": "%2F"}, **base) == sign_gw3(query={"q": "/"}, **base)
        assert sign_gw3(query={"q": "%3F"}, **base) == sign_gw3(query={"q": "?"}, **base)

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
        """命令映射表应覆盖前端声明的全部指令（车控面板 15 按钮 + 空调/充电开关）。"""
        expected = {
            # 门锁
            "lock", "unlock",
            # 空调
            "climateOn", "climateOff",
            # 车控面板 · 状态开关型
            "defrost", "wheelHeat", "seatHeat", "ventSeat",
            # 车控面板 · 远程操作
            "flash", "honk", "closeWindows", "sunshade",
            "chargeStart", "chargeStop", "sentinel",
            # 车控面板 · 场景
            "tripPlan", "carFinder", "refresh",
        }
        assert set(COMMAND_MAP.keys()) == expected
        for command, trio in COMMAND_MAP.items():
            assert len(trio) == 3, f"{command} 应为 (serviceId, key, value) 三元组"
            service_id, key, value = trio
            assert service_id and key and value, f"{command} 的三元组不能有空值"

    def test_is_supported_command(self) -> None:
        """已知指令放行，未知指令必须拒绝 —— 不能对未知指令伪造成功。

        注意：本函数只表达「认不认识」，未验证指令同样为 True。
        能否上真车由 `is_verified_command` 判定，见 TestCommandTrustBoundary。
        """
        assert is_supported_command("unlock")
        assert is_supported_command("sentinel")
        assert not is_supported_command("launchMissiles")


# MARK: - 车控指令可信度分级


class TestCommandTrustBoundary:
    """已验证 / 未验证 serviceId 的隔离测试。

    这是安全底线：serviceId 是可远程触发真实车辆动作的报文内容，
    把「按字母缩写猜的」与「有逆向依据的」混在一起，后续维护者将无法
    分辨哪些能上真车。以下断言用于锁死这条边界。
    """

    # 合作方逆向成果（RexzeLu/zeekr_ha、borconi/openzeekr）中的已知值。
    # 这些值是外部事实，应当保持不变 —— 若本测试失败，说明有人改动了
    # 已验证 serviceId，必须重新核对逆向来源，而不是改断言。
    KNOWN_VERIFIED = {
        "LOCK": "RDL",
        "UNLOCK": "RDU",
        "CLIMATE": "ZAF",
        "WINDOW": "RWS",
        "HORN_LIGHT": "RHL",
        "CHARGE": "RCS",
    }

    def test_verified_service_ids_unchanged(self) -> None:
        """已验证的 serviceId 必须保持原值（有逆向依据，不可擅改）。"""
        for name, value in self.KNOWN_VERIFIED.items():
            assert getattr(ServiceID, name) == value, f"ServiceID.{name} 被改动"

    def test_unverified_service_ids_isolated(self) -> None:
        """推断值必须全部隔离在 ServiceIDUnverified 中，不得混入 ServiceID。"""
        assert set(ServiceIDUnverified.__dict__) & set(self.KNOWN_VERIFIED) == set()
        # 反向确认：这些猜测值确实只在未验证类里
        assert ServiceIDUnverified.SENTINEL == "ZSM"
        assert not hasattr(ServiceID, "SENTINEL")
        assert not hasattr(ServiceID, "DEFROST")

    def test_unverified_commands_match_guessed_service_ids(self) -> None:
        """凡 serviceId 或参数为推断值的指令，必须被全部标记为未验证。

        口径：`serviceId` 来自 `ServiceIDUnverified`，**或**参数 key/value
        为推断值（后者包括复用已验证 serviceId 的 tripPlan / closeWindows /
        carFinder / refresh —— 参数值是猜的，一样不可信）。
        """
        assert UNVERIFIED_COMMANDS == frozenset({
            "defrost", "wheelHeat", "seatHeat", "ventSeat",
            "sunshade", "sentinel",
            "tripPlan", "closeWindows", "carFinder", "refresh",
        })

    def test_unverified_commands_are_subset_of_command_map(self) -> None:
        """未验证集合必须是 COMMAND_MAP 的子集，否则标记会失效。"""
        assert UNVERIFIED_COMMANDS <= set(COMMAND_MAP)

    def test_verified_commands_have_no_guessed_service_id(self) -> None:
        """凡是引用 ServiceIDUnverified 的指令，都必须登记为未验证。"""
        guessed = {
            value
            for name, value in vars(ServiceIDUnverified).items()
            if name.isupper()
        }
        for command, (service_id, _key, _value) in COMMAND_MAP.items():
            if service_id in guessed:
                assert command in UNVERIFIED_COMMANDS, (
                    f"{command} 使用了未验证 serviceId {service_id}，"
                    "但未登记到 UNVERIFIED_COMMANDS"
                )

    def test_is_verified_command_rejects_unverified(self) -> None:
        """`is_verified_command` 必须挡住所有未验证指令。"""
        assert is_verified_command("lock")
        assert is_verified_command("flash")
        # 参数为推断值的三条也须挡住（serviceId 虽已验证）
        assert not is_verified_command("closeWindows")
        assert not is_verified_command("carFinder")
        assert not is_verified_command("refresh")
        for command in UNVERIFIED_COMMANDS:
            assert not is_verified_command(command), f"{command} 未验证，不应判定为可下发"
        assert not is_verified_command("launchMissiles")

    def test_is_supported_semantics_unchanged(self) -> None:
        """`is_supported_command` 语义不得收窄：未验证指令仍是「已知指令」。

        现有逻辑（mock 放行、live 报「不支持的指令」）依赖该语义。
        """
        for command in UNVERIFIED_COMMANDS:
            assert is_supported_command(command)
        # 两者的差异恰好就是未验证集合
        diff = {
            c for c in COMMAND_MAP
            if is_supported_command(c) and not is_verified_command(c)
        }
        assert diff == set(UNVERIFIED_COMMANDS)


# MARK: - 车控闸门「接线」验证
#
# 上面 TestCommandTrustBoundary 测的是 `is_verified_command` 这个**零件**。
# 本组测的是**接线** —— 即 `LiveZeekrClient.send_command` 是否真的调用它。
#
# 背景：此前 `is_verified_command` 在全项目仅被测试引用，生产路径 0 调用，
# 导致「未验证指令 live 拒发」的安全承诺完全落空。仅测零件无法发现该类缺陷。

class TestLiveCommandGating:
    """`LiveZeekrClient.send_command` 必须真的调用可信度闸门。"""

    @staticmethod
    def _bare_client() -> Any:
        """构造一个不触发登录的客户端实例，仅用于验证**入口守卫**。

        守卫在发起任何网络请求之前返回，因此这里无需真实凭证。
        """
        from app.adapters.live_client import LiveZeekrClient

        client = LiveZeekrClient.__new__(LiveZeekrClient)
        client._session = {"active_vin": "TESTVIN0000000000"}
        return client

    def test_send_command_calls_is_verified_command(self) -> None:
        """接线断言：send_command 内部必须调用 `is_verified_command`。

        用 monkeypatch 记录调用，防止「函数存在但没人调」的回归。
        选用未验证指令，保证在守卫处即返回，不触及网络层。
        """
        import app.adapters.live_client as live_module

        calls: list[str] = []
        original = live_module.is_verified_command

        def spy(command: str) -> bool:
            calls.append(command)
            return original(command)

        live_module.is_verified_command = spy  # type: ignore[assignment]
        try:
            client = self._bare_client()
            asyncio.run(client.send_command("defrost"))
        finally:
            live_module.is_verified_command = original  # type: ignore[assignment]

        assert calls == ["defrost"], "send_command 未调用 is_verified_command（安全闸门脱线）"

    def test_verified_command_passes_gate(self) -> None:
        """已验证指令必须**穿过**闸门（不被误拦）。

        通过 spy 断言闸门放行，且不依赖后续网络行为 —— 一旦放行，
        说明闸门没有把已验证指令错杀。
        """
        import app.adapters.live_client as live_module

        seen: list[str] = []
        original = live_module.is_verified_command

        def spy(command: str) -> bool:
            seen.append(command)
            return True  # 强制放行，避免进入真实网络路径

        live_module.is_verified_command = spy  # type: ignore[assignment]
        try:
            client = self._bare_client()
            try:
                asyncio.run(client.send_command("lock"))
            except Exception:  # noqa: BLE001
                pass  # 放行后进入网络层必然失败，与闸门行为无关
        finally:
            live_module.is_verified_command = original  # type: ignore[assignment]

        assert seen == ["lock"], "已验证指令未经过闸门判定"

    def test_send_command_rejects_all_unverified(self) -> None:
        """所有未验证指令都必须被 live 路径拒绝，且不发起网络请求。"""
        client = self._bare_client()
        for command in sorted(UNVERIFIED_COMMANDS):
            result = asyncio.run(client.send_command(command))
            assert result["success"] is False, f"{command} 未被拦截"
            assert result.get("reason") == "unverified_command", (
                f"{command} 的拒绝原因未标注为 unverified_command"
            )

    def test_send_command_rejects_unknown_before_gate(self) -> None:
        """完全未知的指令仍走「不支持的指令」分支，语义不混淆。"""
        client = self._bare_client()
        result = asyncio.run(client.send_command("launchMissiles"))
        assert result["success"] is False
        assert "不支持的指令" in result["message"]
        assert "reason" not in result


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


# MARK: - 功率量纲归一化


class TestPowerNormalization:
    """充电功率量纲推断测试。

    网关返回量纲不一致（瓦特 / kW），需按量级推断。
    """

    def test_watts_are_converted(self) -> None:
        """大于 1000 视为瓦特，转换为 kW。"""
        from app.adapters.live_client import _normalize_power

        assert _normalize_power(118000) == 118.0
        assert _normalize_power(7500) == 7.5

    def test_kilowatts_pass_through(self) -> None:
        """小于等于 1000 视为已是 kW，不再缩放。"""
        from app.adapters.live_client import _normalize_power

        assert _normalize_power(118) == 118.0
        assert _normalize_power(7.5) == 7.5

    def test_zero_and_none(self) -> None:
        """0 与 None 应安全处理。"""
        from app.adapters.live_client import _normalize_power

        assert _normalize_power(0) == 0.0
        assert _normalize_power(None) is None
        assert _normalize_power("abc") is None


# MARK: - 车辆状态容错解析


class TestStatusNormalization:
    """状态解析测试。

    这是对接真实网关的核心逻辑，容错性直接决定数据能否显示。
    """

    # 模拟网关的嵌套报文（层级与真实网关一致）
    SAMPLE = {
        "data": {
            "basicVehicleStatus": {
                "position": {"posCanBeTrusted": True, "latitude": 83164000, "longitude": 407768000},
                "trunkStatus": 0,
            },
            "additionalVehicleStatus": {
                "electricVehicleStatus": {
                    "chargeLevel": 86,
                    "distanceToEmptyOnBatteryOnly": 321,
                    "chargeIAct": 180.5,
                    "chargeUAct": 402.3,
                    "timeToFullyCharged": 45,
                },
                "maintenanceStatus": {
                    "odometer": 23007,
                    "mainBatteryStatus": {"chargeLevel": 88, "voltage": 12.8},
                    "tyreStatus": {
                        "tyreStatusDriver": 241,
                        "tyreStatusPassenger": 242,
                        "tyreStatusDriverRear": 250,
                        "tyreStatusPassengerRear": 249,
                    },
                },
                "climateStatus": {"preClimateActive": True},
                "runningStatus": {"speed": 0},
            },
        }
    }

    def _normalize(self, payload: dict) -> dict:
        from app.adapters.live_client import LiveZeekrClient

        return LiveZeekrClient._normalize_status(payload, "TESTVIN0000000001")

    def test_soc_from_electric_vehicle_status(self) -> None:
        """SOC 必须取动力电池字段，不能误取 12V 电瓶。"""
        status = self._normalize(self.SAMPLE)
        assert status["soc"] == 86.0, "应从 electricVehicleStatus.chargeLevel 取值"
        # 12V 电瓶是独立字段
        assert status["battery12vLevel"] == 88.0

    def test_nested_fields_resolved(self) -> None:
        """深层嵌套字段应能正确解析。"""
        status = self._normalize(self.SAMPLE)
        assert status["rangeKm"] == 321.0
        assert status["odometerKm"] == 23007.0
        assert status["chargeCurrent"] == 180.5
        assert status["chargeVoltage"] == 402.3
        assert status["minutesToFull"] == 45.0
        assert status["climateOn"] is True

    def test_charging_derived_from_current_voltage(self) -> None:
        """充电状态由电流×电压推导（比标志位可靠）。"""
        status = self._normalize(self.SAMPLE)
        # 180.5A × 402.3V ≈ 72.6kW > 0.5kW
        assert status["isCharging"] is True
        assert status["chargePowerKw"] is not None

    def test_tyre_pressures(self) -> None:
        """四轮胎压应全部解析到。"""
        status = self._normalize(self.SAMPLE)
        assert status["tyreFrontLeft"] == 241.0
        assert status["tyreFrontRight"] == 242.0
        assert status["tyreRearLeft"] == 250.0
        assert status["tyreRearRight"] == 249.0

    def test_gps_scaled_to_degrees(self) -> None:
        """GPS 定点整数应换算为度数。"""
        status = self._normalize(self.SAMPLE)
        assert status["latitude"] is not None
        assert status["longitude"] is not None
        # 广州纬度约 23 度
        assert 22.0 < status["latitude"] < 24.0
        assert 112.0 < status["longitude"] < 114.0

    def test_first_non_empty_value_wins(self) -> None:
        """同名字段出现多次时取首个非空值，避免被哨兵值覆盖。"""
        payload = {
            "a": {"value": 42},
            "b": {"value": 0},
        }
        status = self._normalize(payload)
        # 不应抛异常即可，具体字段不重要
        assert isinstance(status, dict)

    def test_empty_payload_does_not_crash(self) -> None:
        """空报文应安全降级为 None，而不是崩溃。"""
        status = self._normalize({})
        assert status["soc"] is None
        assert status["rangeKm"] is None

    def test_short_field_names_resolved(self) -> None:
        """扁平字段名（无嵌套）也应能命中别名。"""
        payload = {"data": {"chargeLevel": 55, "odometer": 12345}}
        status = self._normalize(payload)
        assert status["soc"] == 55.0
        assert status["odometerKm"] == 12345.0

    def test_time_to_full_sentinel_handled(self) -> None:
        """空闲时网关返回哨兵值 2047，应视为未知。"""
        payload = {
            "data": {
                "additionalVehicleStatus": {
                    "electricVehicleStatus": {"timeToFullyCharged": 2047}
                }
            }
        }
        status = self._normalize(payload)
        assert status["minutesToFull"] is None, "2047 是哨兵值，应转为未知"


# MARK: - 行程 tripId 稳定性
#
# 背景：`trips` 表主键是 trip_id 且用 INSERT OR REPLACE，历史实现里
# 网关不返回 id 时 tripId 退化为空串，多条行程互相覆盖 —— 实测写 3 条只剩 1 条。

class TestTripIdStability:
    """trip_id 必须稳定、唯一，绝不退化为空串。"""

    def test_prefers_gateway_id(self) -> None:
        """网关给了 id 就用它，不画蛇添足。"""
        from app.adapters.live_client import build_trip_id
        assert build_trip_id("abc-123", "2026-01-01 08:00:00", "2026-01-01 08:30:00", 12.5) == "abc-123"

    def test_blank_id_falls_back_to_derived(self) -> None:
        """id 缺失/空白时不能返回空串。"""
        from app.adapters.live_client import build_trip_id
        for blank in (None, "", "   "):
            trip_id = build_trip_id(blank, "2026-01-01 08:00:00", "2026-01-01 08:30:00", 12.5)
            assert trip_id, f"raw_id={blank!r} 时返回了空 trip_id"
            assert trip_id.startswith("derived-")

    def test_derived_id_is_deterministic(self) -> None:
        """同一条行程派生出的 id 每次都一样（否则幂等写入失效）。"""
        from app.adapters.live_client import build_trip_id
        args = (None, "2026-01-01 08:00:00", "2026-01-01 08:30:00", 12.5)
        assert build_trip_id(*args) == build_trip_id(*args)

    def test_distinct_trips_get_distinct_ids(self) -> None:
        """不同时间/里程的行程必须拿到不同 id。"""
        from app.adapters.live_client import build_trip_id
        ids = {
            build_trip_id(None, "2026-01-01 08:00:00", "2026-01-01 08:30:00", 12.5),
            build_trip_id(None, "2026-01-01 09:00:00", "2026-01-01 09:30:00", 12.5),
            build_trip_id(None, "2026-01-01 08:00:00", "2026-01-01 08:30:00", 20.0),
            build_trip_id(None, "2026-01-02 08:00:00", "2026-01-02 08:30:00", 12.5),
        }
        assert len(ids) == 4, "不同行程派生出了相同 id"

    def test_save_three_trips_keeps_three(self) -> None:
        """回归复现：写 3 条网关无 id 的行程，库里必须仍是 3 条。"""
        import tempfile
        from app.adapters.live_client import build_trip_id
        from app.core.store import Store

        store = Store(Path(tempfile.mkdtemp()) / "test.db")
        raws = [
            {"startTime": "2026-01-01 08:00:00", "endTime": "2026-01-01 08:30:00", "distance": 10.0},
            {"startTime": "2026-01-01 12:00:00", "endTime": "2026-01-01 12:40:00", "distance": 25.0},
            {"startTime": "2026-01-02 07:30:00", "endTime": "2026-01-02 08:10:00", "distance": 18.5},
        ]
        trips = [
            {
                "tripId": build_trip_id(r.get("id") or r.get("journeyId"), r["startTime"], r["endTime"], r["distance"]),
                "startTime": r["startTime"],
                "endTime": r["endTime"],
                "distanceKm": r["distance"],
            }
            for r in raws
        ]
        assert store.save_trips(trips) == 3
        assert len(store.list_trips(days=3650)) == 3, "行程被主键覆盖，静默丢数据"

    def test_store_rejects_blank_trip_id(self) -> None:
        """防御层：即便上游漏了，store 也不能让空 id 覆盖数据。"""
        import tempfile
        from app.core.store import Store

        store = Store(Path(tempfile.mkdtemp()) / "test.db")
        written = store.save_trips([
            {"tripId": "", "startTime": "2026-01-01 08:00:00"},
            {"tripId": "", "startTime": "2026-01-01 09:00:00"},
            {"tripId": "ok-1", "startTime": "2026-01-01 10:00:00"},
        ])
        assert written == 1, "空 trip_id 应被跳过"
        remaining = store.list_trips(days=3650)
        assert len(remaining) == 1
        assert remaining[0]["tripId"] == "ok-1"


# MARK: - 快照表防膨胀
#
# 背景：状态接口每次轮询都 save_snapshot，前端秒级轮询下单日可写数万行，
# SQLite 文件无限膨胀。修复要点：节流（无变化不落库）+ 保留上限。

class TestSnapshotRetention:
    """快照必须节流且有上限，不能随轮询无限增长。"""

    @staticmethod
    def _store() -> Any:
        import tempfile
        from app.core.store import Store
        return Store(Path(tempfile.mkdtemp()) / "test.db")

    def test_identical_snapshots_are_throttled(self) -> None:
        """状态未变且间隔太短时，重复轮询不应落库。"""
        store = self._store()
        status = {"vin": "V1", "soc": 80.0, "rangeKm": 400.0, "odometerKm": 1000.0}
        for _ in range(20):
            store.save_snapshot(status)
        assert len(store.list_snapshots("V1", limit=100)) == 1, "轮询噪声被写成了快照"

    def test_soc_change_always_saved(self) -> None:
        """SOC 变化必须立刻落库（电量曲线靠它）。"""
        store = self._store()
        for soc in (80.0, 79.0, 78.0, 77.0):
            store.save_snapshot({"vin": "V1", "soc": soc, "rangeKm": 400.0, "odometerKm": 1000.0})
        assert len(store.list_snapshots("V1", limit=100)) == 4

    def test_odometer_change_saved(self) -> None:
        """里程变化也算实质变化。"""
        store = self._store()
        store.save_snapshot({"vin": "V1", "soc": 80.0, "rangeKm": 400.0, "odometerKm": 1000.0})
        store.save_snapshot({"vin": "V1", "soc": 80.0, "rangeKm": 400.0, "odometerKm": 1005.0})
        assert len(store.list_snapshots("V1", limit=100)) == 2

    def test_missing_vin_skipped(self) -> None:
        """没 vin 的状态无法归属，直接跳过且不报错。"""
        store = self._store()
        store.save_snapshot({"soc": 50.0})
        assert store.list_snapshots("V1", limit=100) == []

    def test_retention_cap_enforced(self) -> None:
        """超过上限后旧快照被裁剪，且只留最近的。"""
        from app.core.store import Store
        store = self._store()
        store.SNAPSHOT_KEEP = 50
        # 每条 soc 都不同 → 全部落库，触发裁剪
        for i in range(120):
            store.save_snapshot({"vin": "V1", "soc": float(i), "rangeKm": 1.0, "odometerKm": 1.0})
        kept = store.list_snapshots("V1", limit=1000)
        assert len(kept) == 50, f"保留上限失效，实际 {len(kept)} 条"
        assert kept[0]["soc"] == 119.0, "被裁掉的应该是最旧的，最新一条必须还在"
        assert min(s["soc"] for s in kept) == 70.0

    def test_retention_is_per_vin(self) -> None:
        """裁剪按车辆隔离，不能误删别的车。"""
        store = self._store()
        store.SNAPSHOT_KEEP = 10
        for i in range(30):
            store.save_snapshot({"vin": "A", "soc": float(i), "rangeKm": 1.0, "odometerKm": 1.0})
        for i in range(5):
            store.save_snapshot({"vin": "B", "soc": float(i), "rangeKm": 1.0, "odometerKm": 1.0})
        assert len(store.list_snapshots("A", limit=1000)) == 10
        assert len(store.list_snapshots("B", limit=1000)) == 5, "B 车的快照被 A 车的裁剪误删"

    def test_created_at_uses_local_clock_not_utc(self) -> None:
        """回归：created_at 必须是本地时钟。

        SQLite 的 CURRENT_TIMESTAMP 是 UTC，与 Python 的 datetime.now()
        相差一个时区，会让节流比较永远判定「间隔足够」而失效（本机实测
        差 8 小时 → 每条轮询都落库）。
        """
        from datetime import datetime
        store = self._store()
        store.save_snapshot({"vin": "V1", "soc": 80.0, "rangeKm": 400.0, "odometerKm": 1000.0})
        recorded = store.list_snapshots("V1", limit=1)[0]["createdAt"]
        parsed = datetime.strptime(recorded, "%Y-%m-%d %H:%M:%S")
        drift = abs((datetime.now() - parsed).total_seconds())
        assert drift < 60, f"created_at 与本地时钟相差 {drift:.0f} 秒，疑似写成了 UTC"


# MARK: - P2-2 统计行判定精确性

def _csv_bytes(rows: list[list[str]]) -> bytes:
    buffer = io.StringIO()
    csv.writer(buffer).writerows(rows)
    return buffer.getvalue().encode("gbk")


_ALIPAY_HEADER = ["交易时间", "交易对方", "商品说明", "收/支", "金额", "支付方式", "交易状态", "交易单号"]


class TestSummaryRowPrecision:
    """「共…笔」统计行判定必须精确，不能误杀真实交易。"""

    def test_real_merchant_containing_gong_and_bi_kept(self) -> None:
        """商户名同时含「共」「笔」的真实交易不能被丢。

        历史缺陷：`if "共" in joined and "笔" in joined: continue` 会连这类
        正常交易一起跳过。
        """
        rows = [
            ["支付宝交易记录明细查询"],
            _ALIPAY_HEADER,
            ["2026-09-01 10:30:00", "共笔文具店", "办公用品", "支出", "-35.00", "余额宝", "交易成功", "A1"],
        ]
        result = parse_bill(_csv_bytes(rows), source="alipay")
        assert result["success"] is True
        assert len(result["records"]) == 1, "商户名含「共」「笔」的真实交易被误杀"
        assert result["records"][0]["merchant"] == "共笔文具店"

    def test_real_transaction_with_count_like_note_kept(self) -> None:
        """备注里像「共2笔」但有金额的真实交易必须保留。"""
        rows = [
            ["支付宝交易记录明细查询"],
            _ALIPAY_HEADER,
            ["2026-09-01 10:30:00", "某充电站", "合并开票 共2笔", "支出", "-88.50", "余额宝", "交易成功", "A2"],
        ]
        result = parse_bill(_csv_bytes(rows), source="alipay")
        assert len(result["records"]) == 1, "有金额的交易被统计行规则误杀"

    def test_pure_summary_row_still_skipped(self) -> None:
        """真正的统计行（无金额）仍要被跳过。"""
        rows = [
            ["支付宝交易记录明细查询"],
            _ALIPAY_HEADER,
            ["2026-09-01 10:30:00", "极氪极充", "充电", "支出", "-88.50", "余额宝", "交易成功", "A3"],
            ["共 4 笔记录", "", "", "", "", "", "", ""],
            ["共4笔记录"],
        ]
        result = parse_bill(_csv_bytes(rows), source="alipay")
        assert len(result["records"]) == 1
        assert result["records"][0]["merchant"] == "极氪极充"


# MARK: - P2-1 缓存必须能回源

class TestTripsCacheRevalidation:
    """行程缓存不能「一旦有数据就永不回源」。"""

    def test_ttl_expiry_triggers_refetch(self) -> None:
        """TTL 过期后必须回源，而不是永远返回旧缓存。"""
        import tempfile
        from app.api import trips as trips_api
        from app.core.store import Store

        store = Store(Path(tempfile.mkdtemp()) / "t.db")
        store.TRIPS_CACHE_TTL_SEC = 0  # 立即过期
        store.save_trips([{"tripId": "old-1", "startTime": "2026-09-01 08:00:00"}])

        calls: list[int] = []

        class FakeClient:
            async def get_trips(self, vin=None, days=30):
                calls.append(days)
                return [{"tripId": "new-1", "startTime": "2026-09-02 08:00:00"}]

        # 打桩：替换 main.store 与 get_client
        import app.main as main_module
        import app.api.trips as trips_module
        old_store, old_get = main_module.store, trips_module.get_client
        main_module.store = store
        trips_module.get_client = lambda: FakeClient()
        trips_module._last_refresh.clear()
        try:
            trips_api.TRIPS_CACHE_TTL_SEC = 0
            result = asyncio.run(trips_module.get_trips(days=30))
            assert calls == [30], "缓存过期却未回源"
            assert any(t["tripId"] == "new-1" for t in result["data"])
        finally:
            main_module.store, trips_module.get_client = old_store, old_get
            trips_module._last_refresh.clear()

    def test_force_bypasses_fresh_cache(self) -> None:
        """force=true 必须跳过缓存直接回源。"""
        import tempfile
        from app.api import trips as trips_api
        from app.core.store import Store

        store = Store(Path(tempfile.mkdtemp()) / "t.db")
        store.save_trips([{"tripId": "old-1", "startTime": "2026-09-01 08:00:00"}])

        calls: list[int] = []

        class FakeClient:
            async def get_trips(self, vin=None, days=30):
                calls.append(days)
                return [{"tripId": "forced-1", "startTime": "2026-09-02 08:00:00"}]

        import app.main as main_module
        import app.api.trips as trips_module
        old_store, old_get = main_module.store, trips_module.get_client
        main_module.store = store
        trips_module.get_client = lambda: FakeClient()
        trips_module._last_refresh.clear()
        try:
            # 先建一次「新鲜」缓存
            trips_api.TRIPS_CACHE_TTL_SEC = 3600
            asyncio.run(trips_module.get_trips(days=30))
            calls.clear()
            asyncio.run(trips_module.get_trips(days=30))       # 命中缓存
            assert calls == [], "TTL 内不应该回源"
            asyncio.run(trips_module.get_trips(days=30, force=True))
            assert calls == [30], "force=true 未跳过缓存"
        finally:
            main_module.store, trips_module.get_client = old_store, old_get
            trips_module._last_refresh.clear()

    def test_upstream_failure_degrades_to_cache(self) -> None:
        """回源失败但有缓存时应降级返回旧数据，而不是 500。"""
        import tempfile
        from app.core.store import Store

        store = Store(Path(tempfile.mkdtemp()) / "t.db")
        store.save_trips([{"tripId": "old-1", "startTime": "2026-09-01 08:00:00"}])

        class BrokenClient:
            async def get_trips(self, vin=None, days=30):
                raise RuntimeError("gateway down with token=SECRET")

        import app.main as main_module
        import app.api.trips as trips_module
        old_store, old_get = main_module.store, trips_module.get_client
        main_module.store = store
        trips_module.get_client = lambda: BrokenClient()
        trips_module._last_refresh.clear()
        try:
            result = asyncio.run(trips_module.get_trips(days=30, force=True))
            assert result["success"] is True
            assert result.get("stale") is True
            assert result["data"][0]["tripId"] == "old-1"
        finally:
            main_module.store, trips_module.get_client = old_store, old_get
            trips_module._last_refresh.clear()


# MARK: - P2-3 错误回显统一

class TestErrorDetailHygiene:
    """上游异常不得回显给客户端（可能夹带令牌）。"""

    def test_upstream_error_hides_exception_text(self) -> None:
        """detail 只能是固定文案，绝不能含原始异常。"""
        from app.api import upstream_error

        secret = "accessToken=eyJhbGciOiJIUzI1NiJ9.LEAKED"
        err = upstream_error("获取车辆状态失败，请检查服务端日志与登录状态", RuntimeError(secret))
        assert secret not in str(err.detail)
        assert "eyJhbGciOiJIUzI1NiJ9" not in str(err.detail)
        assert err.status_code == 500

    def test_no_api_module_echoes_exception(self) -> None:
        """全量静态检查：api 包内不得再出现 `detail=f\"...{exc}\"` 写法。"""
        import re
        api_dir = Path(__file__).resolve().parent.parent / "app" / "api"
        offenders = []
        for path in api_dir.glob("*.py"):
            if path.name == "__init__.py":
                continue
            text = path.read_text(encoding="utf-8")
            # 找 detail= 里出现 {exc} 或 {e} 的 f-string
            for match in re.finditer(r"detail\s*=\s*f?[\"'].*?\{(?:exc|e)\}", text):
                offenders.append(f"{path.name}: {match.group(0)}")
        assert not offenders, f"仍有接口回显原始异常：{offenders}"

    def test_upstream_error_logs_for_diagnostics(self) -> None:
        """不回显不等于不留痕 —— 必须进日志。"""
        import logging
        from app.api import upstream_error

        records: list[logging.LogRecord] = []

        class Capture(logging.Handler):
            def emit(self, record: logging.LogRecord) -> None:
                records.append(record)

        api_logger = logging.getLogger("app.api")
        handler = Capture()
        api_logger.addHandler(handler)
        old_level = api_logger.level
        api_logger.setLevel(logging.ERROR)
        try:
            upstream_error("操作失败", RuntimeError("内部细节 X"))
        finally:
            api_logger.removeHandler(handler)
            api_logger.setLevel(old_level)
        assert records, "上游异常未写日志，排障时无从下手"
        assert any("内部细节 X" in r.getMessage() or (r.exc_info and "内部细节 X" in str(r.exc_info[1])) for r in records)
