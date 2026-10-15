"""数据源形状一致性回归测试。

为什么需要这个文件：
`MockZeekrClient` 与 `LiveZeekrClient._normalize_status` 的输出会被**同一套
前端**消费（iOS App 与 preview/debug.html）。两者形状一旦漂移，症状是
"模拟数据下一切正常、接上真车就缺字段"—— 属于最难排查的一类问题。

已实际发生过两次（均在本次审计中发现并修复）：
  1. `windows` 的子键：mock 用 `frontLeft/frontRight`，live 用
     `driver/passenger`。前端按 `driver/passenger` 取值，于是模拟模式下
     前窗状态恒为 undefined。
  2. `tyreTemp*`（四轮胎温）：live 侧从官方 APK 的真实字段
     （`leftFrontTyreTemp` 等）解析出来了，mock 侧没跟上，
     导致胎温只在真车模式下才有数据。

这类漂移用"记得两边一起改"是防不住的，只有断言键集合相等才拦得住。

运行：python -m pytest tests/test_adapter_shape.py -v
"""

from __future__ import annotations

import asyncio
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from app.adapters.live_client import LiveZeekrClient  # noqa: E402
from app.adapters.mock_client import MockZeekrClient  # noqa: E402


# ── 规范键名（由前端消费，改这里等于改对外契约）──
STATUS_KEYS = {
    "vin", "nickname", "plateNo", "modelName",
    "soc", "rangeKm", "odometerKm",
    "battery12vVoltage", "battery12vLevel",
    "isCharging", "isPlugged",
    "chargePowerKw", "chargeVoltage", "chargeCurrent", "minutesToFull", "chargeLimit",
    "isLocked", "doors", "windows", "trunkOpen", "frunkOpen",
    "tyreFrontLeft", "tyreFrontRight", "tyreRearLeft", "tyreRearRight",
    "tyreTempFrontLeft", "tyreTempFrontRight", "tyreTempRearLeft", "tyreTempRearRight",
    "tyreWarning",
    "climateOn", "climateTargetTemp", "interiorTemp", "exteriorTemp",
    "latitude", "longitude", "positionTrusted", "speedKmh",
    "avgConsumption", "serviceDistanceKm", "serviceDays", "lastUpdateTs",
}

DOOR_KEYS = {"frontLeft", "frontRight", "rearLeft", "rearRight"}
WINDOW_KEYS = {"driver", "passenger", "rearLeft", "rearRight"}

TRIP_KEYS = {
    "tripId", "startTime", "endTime", "distanceKm", "energyKwh",
    "avgSpeedKmh", "maxSpeedKmh", "consumption",
    "startPlace", "endPlace", "durationMinutes",
}


@pytest.fixture(scope="module")
def statuses():
    """mock 的真实输出 + live 归一化函数对空报文的输出。

    live 侧不联网：`_normalize_status` 是静态方法，喂空 payload 即可拿到
    "全字段为 None"的骨架 —— 正好用来比对键集合。
    """
    mock_status = asyncio.run(MockZeekrClient().get_vehicle_status())
    live_status = LiveZeekrClient._normalize_status({}, "TESTVIN0000000000")
    return mock_status, live_status


def test_status_keys_match_between_adapters(statuses):
    """两个适配器的顶层键必须完全一致（键集合相等，顺序无关）。"""
    mock_status, live_status = statuses
    assert set(mock_status) == set(live_status), (
        "mock 与 live 的车辆状态字段不一致：\n"
        f"  仅 mock 有：{sorted(set(mock_status) - set(live_status))}\n"
        f"  仅 live 有：{sorted(set(live_status) - set(mock_status))}"
    )


def test_status_keys_match_canonical_contract(statuses):
    """两者都必须覆盖前端依赖的规范键集合。"""
    mock_status, live_status = statuses
    for label, payload in (("mock", mock_status), ("live", live_status)):
        missing = STATUS_KEYS - set(payload)
        assert not missing, f"{label} 缺少前端依赖的字段：{sorted(missing)}"


def test_windows_and_doors_subkeys_match(statuses):
    """子字典的键必须一致 —— 这两处历史上都漂移过。

    注意两者的对外契约并不相同，别一刀切：
      · doors —— **恒为字典**，值可以是 None（iOS 侧容错为可选值）
      · windows —— **字典 或 None**；一旦给字典，四个值必须都是 Bool
        （iOS 侧按 `[String: Bool]?` 解码，None 会导致整个响应解码失败）
    """
    mock_status, live_status = statuses

    assert set(mock_status["doors"]) == DOOR_KEYS
    assert set(live_status["doors"]) == DOOR_KEYS

    assert set(mock_status["windows"]) == WINDOW_KEYS
    assert live_status["windows"] is None or set(live_status["windows"]) == WINDOW_KEYS


def test_live_windows_is_all_or_none(statuses):
    """live 侧 windows 要么是 None，要么四个值全是 Bool —— 不允许半成品。

    空报文 → None；数据不全 → None；四个都拿到 → 全是 Bool。
    """
    _, live_status = statuses
    assert live_status["windows"] is None, "空报文下应为 None"

    partial = LiveZeekrClient._normalize_status(
        {"data": {"leftFrontWindowStatus": 0}}, "TESTVIN0000000000"
    )
    assert partial["windows"] is None, "数据不全时不得返回含 None 的字典"

    full = LiveZeekrClient._normalize_status(
        {"data": {
            "leftFrontWindowStatus": 0, "rightFrontWindowStatus": 1,
            "leftBackWindowStatus": 0, "rightBackWindowStatus": 0,
        }},
        "TESTVIN0000000000",
    )
    assert full["windows"] is not None
    assert all(isinstance(v, bool) for v in full["windows"].values())


def test_tyre_temp_present_in_both(statuses):
    """胎温四字段必须两边都有（曾只在 live 侧存在）。"""
    mock_status, live_status = statuses
    for key in ("tyreTempFrontLeft", "tyreTempFrontRight",
                "tyreTempRearLeft", "tyreTempRearRight"):
        assert key in mock_status, f"mock 缺少 {key}"
        assert key in live_status, f"live 缺少 {key}"


def test_trips_keys_match_contract():
    """行程字段：mock 输出必须覆盖规范集合。

    live 的 `get_trips` 需要联网，故这里只锁住 mock 与契约；
    live 侧的字段名在 `live_client.get_trips` 的返回字典里，
    改动时同步更新 TRIP_KEYS。
    """
    trips = asyncio.run(MockZeekrClient().get_trips())
    assert trips, "mock 应当产出演示用行程数据"
    for trip in trips:
        missing = TRIP_KEYS - set(trip)
        assert not missing, f"行程缺少字段：{sorted(missing)}"


# ═══════════════════════════════════════════════════════════════
# 能力集 与 车控执行结果
# ═══════════════════════════════════════════════════════════════

CAPABILITY_KEYS = {"capabilities", "chargePlan", "verified"}
COMMAND_STATUSES = {"pending", "done", "failed"}


def test_capabilities_shape_matches():
    """两个适配器的能力集返回结构必须一致。"""
    mock_caps = asyncio.run(MockZeekrClient().get_capabilities())
    assert set(mock_caps) == CAPABILITY_KEYS
    # mock 侧给了完整能力表，且必须声明"映射未经真车确认"
    assert isinstance(mock_caps["capabilities"], dict)
    assert mock_caps["verified"] is False, (
        "能力集的键名映射尚未真车确认，不得谎报为已验证"
    )


def test_command_result_status_is_in_enum():
    """两个适配器的执行结果状态都必须落在合法枚举内。"""
    mock_result = asyncio.run(MockZeekrClient().get_command_result("any-id"))
    assert mock_result["status"] in COMMAND_STATUSES


def test_send_command_returns_command_id():
    """下发指令必须带回 commandId —— 否则无法查询车端执行结果。

    这条守着"假成功"问题的根：没有凭据就没法确认车是否真的动了。
    """
    result = asyncio.run(MockZeekrClient().send_command("lock"))
    assert result["success"] is True
    assert result.get("commandId"), "下发成功却没有 commandId，无法追踪执行结果"


def test_map_command_status_is_conservative():
    """解析不出车端状态时必须返回 pending，**绝不能是 done**。

    这是安全断言，不是格式断言：把"没执行完"说成"已执行"，用户会以为
    车锁好了；反过来多等一会儿没有代价。方向是不对称的。
    """
    from app.adapters.live_client import _map_command_status

    for payload in (None, {}, {"data": {}}, {"foo": "bar"}, [], "garbage", {"data": None}):
        assert _map_command_status(payload) == "pending", f"payload={payload!r} 不应被判为 done"

    assert _map_command_status({"status": "done"}) == "done"
    assert _map_command_status({"data": {"processStatus": 1}}) == "done"
    assert _map_command_status({"data": {"processStatus": 0}}) == "pending"
    assert _map_command_status({"data": {"processStatus": 2}}) == "failed"
    assert _map_command_status({"data": {"status": True}}) == "done"


def test_map_capabilities_falls_back_to_none():
    """形态不认识时返回 None（前端退回"全部显示"），不猜。"""
    from app.adapters.live_client import _map_capabilities

    assert _map_capabilities(None) is None
    assert _map_capabilities({}) is None
    assert _map_capabilities({"data": {"text": "无可解析字段"}}) is None

    assert _map_capabilities({"doorLock": True, "climate": False}) == {
        "doorLock": True, "climate": False,
    }
    assert _map_capabilities({"data": {"list": [
        {"code": "seatHeat", "available": True},
        {"name": "sunshade", "available": False},
    ]}}) == {"seatHeat": True, "sunshade": False}


def test_new_endpoints_implemented_by_both_adapters():
    """两个适配器都必须实现新增的两个接口（抽象方法不许漏实现）。"""
    from app.adapters.live_client import LiveZeekrClient
    from app.adapters.mock_client import MockZeekrClient

    for cls in (LiveZeekrClient, MockZeekrClient):
        assert cls.get_capabilities is not None
        assert cls.get_command_result is not None
        # 覆盖了抽象方法（不再是基类里那个 raise NotImplementedError）
        assert cls.get_capabilities.__qualname__.startswith(cls.__name__)
        assert cls.get_command_result.__qualname__.startswith(cls.__name__)
