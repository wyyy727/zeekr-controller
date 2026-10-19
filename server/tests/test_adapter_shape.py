"""数据源形状一致性回归测试。

为什么需要这个文件：
`MockZeekrClient` 与 `LiveZeekrClient._normalize_status` 的输出会被**同一套
前端**消费（iOS App 与 preview/index.html 的内置模拟数据）。两者形状一旦漂移，症状是
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

CAPABILITY_KEYS = {"capabilities", "permissions", "chargePlan", "verified"}
COMMAND_STATUSES = {"pending", "done", "failed"}


def test_capabilities_shape_matches():
    """两个适配器的权限包返回结构必须一致。"""
    mock_caps = asyncio.run(MockZeekrClient().get_capabilities())
    assert set(mock_caps) == CAPABILITY_KEYS
    assert isinstance(mock_caps["capabilities"], dict)
    # 原始权限包 ID 必须一并返回 —— 设置页要靠它如实展示"开通了什么"
    assert isinstance(mock_caps["permissions"], list)
    assert mock_caps["permissions"], "权限包不应为空列表"
    # mock 是模拟数据，不是真车实测结论，不得谎报为已验证
    assert mock_caps["verified"] is False, "模拟数据不得谎报为真车已验证"


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


# ── 权限包（2026-10-16 真车实测：GET /ms-app-bff/api/1.0/permissions）──
#
# 真车实报形态（key 与结构逐字复刻）：
#   {"code":"000000","msg":"ok","success":true,"data":["vehicle-share", …]}
#
# 返回的是**服务 / 功能权限包 ID**，不是逐项硬件能力 —— 由此定下一条规矩：
# 只有「服务类」功能允许被权限包隐藏，硬件能力必须一律照常显示。

REAL_PERMISSIONS_PAYLOAD = {
    "code": "000000",
    "msg": "ok",
    "success": True,
    "data": [
        "vehicle-share",
        "vehicle-defence",
        "digital-key",
        "owner-digital-key",
        "view-vehicle-location",
        "view-vehicle-album",
        "remote-control",
        "traffic-card-owner",
        "digital-key1.0",
        "digital-key2.0",
        "digital-key3.0",
        "charge-manage",
        "ETC-LU-function",
        "VIVO-watch",
        "journey-h5-owner",
        "owner-vehicle-trail",
        "owner-ai-cloud",
        "owner-ota-server",
        "ZK_face_recognition",
        "Rear_seat_ventilation",
        "half_load_260",
    ],
}


def test_extract_permissions_real_payload():
    """真车实报的权限包结构必须解析得出来。"""
    from app.adapters.live_client import _extract_permissions

    perms = _extract_permissions(REAL_PERMISSIONS_PAYLOAD)
    assert perms is not None
    assert len(perms) == 21
    assert "charge-manage" in perms
    assert "owner-vehicle-trail" in perms


def test_extract_permissions_distinguishes_empty_from_unparsable():
    """`data: []`（确认无权限）与"结构不认识"（None）语义不同，不得混为一谈。

    前者是网关明确回答"这个平台下没有任何权限"，后者是解析失败。
    两者最终都让前端"全部显示"，但把空列表说成解析失败会掩盖
    「tspPlatform 填错了」这类配置问题。
    """
    from app.adapters.live_client import _extract_permissions

    assert _extract_permissions({"code": "000000", "data": []}) == []
    assert _extract_permissions({"code": "000000", "data": {"text": "?"}}) is None
    assert _extract_permissions(None) is None
    assert _extract_permissions("garbage") is None


def test_map_permissions_never_hides_hardware_capabilities():
    """**安全断言**：权限接口只回答"服务开通了什么"，
    绝不能拿它去隐藏硬件功能（胎压 / 空调 / 车窗 / 门锁 …）。

    真车实测返回的 21 项权限里没有任何硬件能力项；若映射逻辑把
    "权限列表里没出现"当成"硬件不支持"，整页控件会凭空消失。
    宁可多显示一个按了没反应的按钮，也不能把真车有的功能藏起来。
    """
    from app.adapters.live_client import _map_permissions

    mapped = _map_permissions(REAL_PERMISSIONS_PAYLOAD["data"])
    assert mapped is not None
    for hardware_key in ("doorLock", "climate", "window", "trunk", "frunk",
                         "tyrePressure", "tyreTemp", "seatHeat", "defrost"):
        assert hardware_key not in mapped, f"{hardware_key} 是硬件能力，不得由权限包推导"


def test_map_permissions_marks_service_caps():
    """权限包里有 → 对应服务类功能可用；没有 → 明确置 False（允许隐藏）。"""
    from app.adapters.live_client import _map_permissions

    mapped = _map_permissions(REAL_PERMISSIONS_PAYLOAD["data"])
    assert mapped["chargingPlan"] is True   # ← charge-manage
    assert mapped["sentinel"] is True       # ← vehicle-defence
    assert mapped["travelPlan"] is True     # ← owner-vehicle-trail
    assert mapped["tripTrack"] is True
    assert mapped["seatVent"] is True       # ← Rear_seat_ventilation

    # 只开通充电管理时，其余服务类功能必须被明确置 False（而不是留空）
    only_charge = _map_permissions(["charge-manage"])
    assert only_charge["chargingPlan"] is True
    assert only_charge["sentinel"] is False
    assert only_charge["travelPlan"] is False
    assert only_charge["seatVent"] is False

    # 解析失败 → 一个键都不写，前端按"全部显示"
    assert _map_permissions(None) is None


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


# ── 报文字段名回归（2026-10-16 真车实测取证）─────────────────────────────────
#
# 来源：真车 `GET /ms-vehicle-status/api/v1.0/vehicle/status/latest` 的实报
# **结构逐字复刻，全部取值已脱敏**（VIN / 车牌 / 坐标 / 里程 / 时间戳均为
# 同形状假值）。⚠️ 真车原始报文属隐私数据，一律只留在本地，禁止入库、禁止上传。
# 别名表若回退成自造名（`doorStatusFrontLeft` / `tyreWarningStatus` /
# `seriesCodeVs` 这类官方包里 0 命中的名字），这些断言会立刻红 —— 这正是它们存在的意义。

REAL_STATUS_PAYLOAD = {
    "code": "000000",
    "msg": "ok",
    "data": {
        "basicVehicleStatus": {
            "speed": "0",
            "distanceToEmpty": "321",
            "position": {
                "latitude": "30.1234567", "longitude": "120.1234567",
                "posCanBeTrusted": "0",
                # 网关自报坐标系：0 = 原始 WGS-84（实测真车就是这个值），
                # 解析层必须转成 GCJ-02，否则地图上偏 400~600 米
                "marsCoordinates": "0",
            },
        },
        "additionalVehicleStatus": {
            "electricVehicleStatus": {
                "chargeLevel": "66.5",
                "timeToFullyCharged": "1800",
                "statusOfChargerConnection": "0",
                "averPowerConsumption": "18.7",
            },
            "drivingSafetyStatus": {
                "centralLockingStatus": "1",
                "doorOpenStatusDriver": "0",
                "doorOpenStatusPassenger": "0",
                "doorOpenStatusDriverRear": "0",
                "doorOpenStatusPassengerRear": "0",
                "trunkOpenStatus": "0",
                "engineHoodOpenStatus": "0",
            },
            "maintenanceStatus": {
                "odometer": 12345,
                "mainBatteryStatus": {"voltage": 12.68, "chargeLevel": ""},
                "tyreStatusDriver": "250", "tyreStatusPassenger": "252",
                "tyreStatusDriverRear": "248", "tyreStatusPassengerRear": "246",
                "tyreTempDriver": 21, "tyreTempPassenger": 20,
                "tyreTempDriverRear": 20, "tyreTempPassengerRear": 20,
                "tyrePreWarningDriver": 0, "tyrePreWarningPassenger": 0,
                "tyrePreWarningDriverRear": 0, "tyrePreWarningPassengerRear": 0,
            },
            "climateStatus": {
                "interiorTemp": "23.0",
                "preClimateActive": False,
                # 驻车锁车时为 2 / 0 —— 语义未确认，解析层必须保持 None
                "winStatusDriver": "2", "winStatusPassenger": "2",
                "winStatusDriverRear": "2", "winStatusPassengerRear": "2",
            },
        },
        "updateTime": 1760000000000,
    },
    "success": True,
}

# 车辆列表的实报结构：车型在 `appModelCode` / `appInnerCode` / `appYearCode`
# （实测值 DC1E-A3 / DC1E-A3-001），**没有** `seriesCodeVs`（自造名，0 命中）。
# VIN / 车牌同为真车隐私数据，此处一律用同形状假值。
REAL_VEHICLE_LIST_PAYLOAD = {
    "code": "000000", "msg": "ok",
    "data": [{
        "userVehId": 1000001,
        "vin": "TESTVIN0000000001",
        "isOwner": True, "defaultVehicle": True,
        "appInnerCode": "DC1E-A3", "appModelCode": "DC1E-A3",
        "appYearCode": "DC1E-A3-001",
        "plateNo": "沪A00000", "nickName": "",
    }],
}


def test_real_status_payload_field_names_parse():
    """实报字段名必须全部解析得到 —— 防别名表回退成自造名。"""
    status = LiveZeekrClient._normalize_status(REAL_STATUS_PAYLOAD, "TESTVIN0000000001")
    assert status["soc"] == 66.5
    assert status["rangeKm"] == 321.0
    assert status["odometerKm"] == 12345.0
    assert status["battery12vVoltage"] == 12.68   # as_float 统一保留 2 位
    # 12V 电瓶电量：真车报的是**空字符串**，必须落成 None ——
    # 绝不能变成 0（会被读成"电瓶已经没电"，性质和"价格缺失≠免费"一样）。
    assert status["battery12vLevel"] is None
    assert status["isLocked"] is True
    assert status["isPlugged"] is False
    assert status["doors"] == {
        "frontLeft": False, "frontRight": False,
        "rearLeft": False, "rearRight": False,
    }
    assert status["trunkOpen"] is False
    assert status["frunkOpen"] is False          # engineHoodOpenStatus
    assert status["tyreFrontLeft"] == 250.0      # tyreStatusDriver
    assert status["tyreFrontRight"] == 252.0     # tyreStatusPassenger
    assert status["tyreRearLeft"] == 248.0       # tyreStatusDriverRear
    assert status["tyreRearRight"] == 246.0      # tyreStatusPassengerRear
    assert status["tyreTempFrontLeft"] == 21.0   # tyreTempDriver
    assert status["tyreTempRearRight"] == 20.0   # tyreTempPassengerRear
    assert status["tyreWarning"] is False        # tyrePreWarning*
    assert status["interiorTemp"] == 23.0        # climateStatus.interiorTemp
    assert status["climateOn"] is False          # preClimateActive
    assert status["avgConsumption"] == 18.7
    # 坐标不走 as_float（会舍到 2 位 ≈ 1.1km 误差），必须保留 6 位
    # 坐标：网关自报 marsCoordinates="0" ⇒ 给的是原始 WGS-84，输出必须是转好的
    # GCJ-02。这里断言"偏移几百米"，而不是硬编码结果 —— 硬编码会随算法微调失效，
    # 而这个区间恰好能区分"忘了转"（偏移为 0）和"转错了"（偏移大得离谱）。
    import math

    dy = (status["latitude"] - 30.123457) * 111320
    dx = (status["longitude"] - 120.123457) * 111320 * math.cos(math.radians(30.123457))
    shift = math.hypot(dx, dy)
    assert 200 < shift < 800, f"WGS-84 未转成 GCJ-02（或转错），偏移 {shift:.0f} 米"
    # updateTime（毫秒）应被用为上报时间，而不是服务端的当前时间
    assert status["lastUpdateTs"] == "2025-10-09 16:53:20"


def test_real_status_windows_stay_unknown_when_semantics_unconfirmed():
    """`winStatus=2` 语义未确认 → windows 必须保持 None（不得谎报"已关"）。"""
    status = LiveZeekrClient._normalize_status(REAL_STATUS_PAYLOAD, "TESTVIN0000000001")
    assert status["windows"] is None


def test_real_vehicle_list_model_name_resolved():
    """车型解析用 appModelCode 前缀（DC1E → 极氪 001），不是 seriesCodeVs。"""
    vehicles = LiveZeekrClient._extract_vehicle_list(REAL_VEHICLE_LIST_PAYLOAD)
    assert vehicles == [{
        "vin": "TESTVIN0000000001",
        "nickname": "",
        "plateNo": "沪A00000",
        "modelName": "极氪 001",
        "isOwner": True,
    }]
