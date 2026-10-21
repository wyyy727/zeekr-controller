"""Mock 数据源。

用途：
1. 无凭据时演示 UI 与接口契约
2. 单元测试与联调
3. 前端的 `#Preview` 预览数据

生成的数据带有确定性随机（以日期为种子），
同一天内多次请求结果稳定，便于观察趋势。
"""

from __future__ import annotations

import calendar
import hashlib
import math
import random
from datetime import datetime, timedelta
from typing import Any

from .base import ZeekrClient
from .zeekr_signing import COMMAND_MAP

MOCK_VIN = "L6TDEMOCK00000001"

# 车辆身份三件套。
#
# 这三个值必须与 ZeekrDash/Core/Mock/MockData.swift 和 preview/index.html 的
# MOCK.status **保持一致** —— 否则同一台手机在「地址=localhost（App 内置模拟）」
# 和「地址=局域网（服务端模拟）」两种情况下会显示成两台不同的车，用户会以为
# 自己连错了后端。一致性由 tests/test_mock_consistency.py 自动校验。
#
# 注意 VIN 故意用明显是假的 L6TDEMOCK... —— 它不会被界面展示，
# 但把"这是模拟数据"写在值里能避免被误当成真车。
MOCK_NICKNAME = "焕新 001"
MOCK_PLATE = "沪A·D8821"
MOCK_MODEL = "ZEEKR 001"


def _seeded_rng(seed_text: str) -> random.Random:
    """基于文本生成确定性随机数发生器。"""
    digest = hashlib.md5(seed_text.encode("utf-8")).hexdigest()
    return random.Random(int(digest[:16], 16))


def _current_period_index(frames: list[str], now: datetime) -> int:
    """按当前时刻找出所处时段下标。

    存在的意义：让模拟模式下"当前时段"高亮也是**真的对**的 ——
    否则这个特性在演示环境里永远指向第一段，等于从没验证过。
    """
    minutes = now.hour * 60 + now.minute
    for index, frame in enumerate(frames):
        start, _, end = frame.partition("-")
        try:
            start_h, start_m = (int(part) for part in start.split(":"))
            end_h, end_m = (int(part) for part in end.split(":"))
        except ValueError:
            continue
        if start_h * 60 + start_m <= minutes <= end_h * 60 + end_m:
            return index
    return 0


class MockZeekrClient(ZeekrClient):
    """生成仿真数据的客户端。"""

    def __init__(self) -> None:
        self._authenticated = False
        self._phone = ""

    # MARK: 认证

    async def send_sms_code(self, phone: str) -> dict[str, Any]:
        self._phone = phone
        return {"success": True, "message": "验证码已发送（模拟模式：任意 6 位数字均可通过）"}

    async def verify_sms_code(self, phone: str, code: str) -> dict[str, Any]:
        if len(code) != 6 or not code.isdigit():
            return {"success": False, "message": "验证码格式不正确"}
        self._phone = phone
        self._authenticated = True
        return {"success": True, "message": "登录成功（模拟模式）", "vehicle_count": 1}

    async def is_authenticated(self) -> bool:
        return self._authenticated

    async def logout(self) -> None:
        self._authenticated = False

    # MARK: 车辆

    async def list_vehicles(self) -> list[dict[str, Any]]:
        return [
            {
                "vin": MOCK_VIN,
                "nickname": MOCK_NICKNAME,
                "plateNo": MOCK_PLATE,
                "modelName": MOCK_MODEL,
                "isOwner": False,
            }
        ]

    async def get_vehicle_status(self, vin: str | None = None) -> dict[str, Any]:
        now = datetime.now()
        rng = _seeded_rng(f"status-{now:%Y%m%d%H}-{now.minute // 5}")

        # 电量按小时缓变，模拟真实使用节奏
        hour_seed = _seeded_rng(f"soc-{now:%Y%m%d}")
        base_soc = 45 + hour_seed.random() * 45
        soc = max(8.0, min(100.0, base_soc + math.sin(now.hour / 24 * math.tau) * 8))

        is_charging = soc < 60 and rng.random() > 0.55
        charge_power = round(rng.uniform(60, 118), 1) if is_charging else 0.0
        # 2026 款 001 搭载 800V 超充，电量越高功率越低
        if is_charging:
            charge_power *= (1.0 - soc / 160.0)

        range_km = round(soc / 100.0 * 700, 1)  # CLTC 700km
        odometer = 12000 + (now - datetime(now.year, 1, 1)).days * 42.5

        return {
            "vin": vin or MOCK_VIN,
            "nickname": MOCK_NICKNAME,
            "plateNo": MOCK_PLATE,
            "modelName": MOCK_MODEL,
            "soc": round(soc, 1),
            "rangeKm": range_km,
            "odometerKm": round(odometer, 1),
            "battery12vVoltage": round(rng.uniform(12.4, 13.1), 2),
            "battery12vLevel": round(rng.uniform(78, 96), 1),
            "isCharging": is_charging,
            "isPlugged": is_charging,
            "chargePowerKw": round(charge_power, 1),
            "chargeVoltage": round(rng.uniform(380, 420), 1) if is_charging else None,
            "chargeCurrent": round(rng.uniform(120, 250), 1) if is_charging else None,
            "minutesToFull": round((100 - soc) / 100 * 100 * 0.85, 0) if is_charging else None,
            "chargeLimit": 90.0,
            "isLocked": rng.random() > 0.15,
            # 字段名与 `live_client._normalize_status` 保持一致 ——
            # 两者的输出会被同一套前端消费，形状漂移会导致"模拟能看、
            # 上真车就缺字段"这种最难查的问题。有回归测试守着（见
            # tests/test_adapter_shape.py）。
            "doors": {
                "frontLeft": False,
                "frontRight": False,
                "rearLeft": False,
                "rearRight": False,
            },
            # 车窗用 driver / passenger 命名主驾与副驾 ——
            # 与 live 侧一致（官方字段是 leftFrontWindowStatus，
            # 但对外的规范键名沿用 driver/passenger）。
            "windows": {
                "driver": False,
                "passenger": False,
                "rearLeft": False,
                "rearRight": False,
            },
            "trunkOpen": False,
            "frunkOpen": False,
            "tyreFrontLeft": round(rng.uniform(235, 252), 0),
            "tyreFrontRight": round(rng.uniform(235, 252), 0),
            "tyreRearLeft": round(rng.uniform(238, 255), 0),
            "tyreRearRight": round(rng.uniform(238, 255), 0),
            # 四轮胎温：官方有 leftFrontTyreTemp 等独立字段，
            # live 侧已解析，mock 侧必须同样给出，否则该卡在模拟模式下没有数据
            "tyreTempFrontLeft": round(rng.uniform(28, 38), 0),
            "tyreTempFrontRight": round(rng.uniform(28, 38), 0),
            "tyreTempRearLeft": round(rng.uniform(28, 38), 0),
            "tyreTempRearRight": round(rng.uniform(28, 38), 0),
            "tyreWarning": False,
            "climateOn": rng.random() > 0.6,
            "climateTargetTemp": 23.0,
            "interiorTemp": round(rng.uniform(18, 28), 1),
            "exteriorTemp": round(rng.uniform(12, 32), 1),
            "latitude": 23.1291 + rng.uniform(-0.02, 0.02),
            "longitude": 113.2644 + rng.uniform(-0.02, 0.02),
            "positionTrusted": True,
            "speedKmh": 0.0,
            "avgConsumption": round(rng.uniform(15.5, 19.8), 1),
            "serviceDistanceKm": round(rng.uniform(3000, 8500), 0),
            "serviceDays": rng.randint(60, 220),
            "lastUpdateTs": now.strftime("%Y-%m-%d %H:%M:%S"),
        }

    async def get_trips(self, vin: str | None = None, days: int = 30) -> list[dict[str, Any]]:
        now = datetime.now()
        trips: list[dict[str, Any]] = []

        places = [
            ("家", "公司"), ("公司", "家"), ("家", "万象城"),
            ("公司", "健身房"), ("家", "机场"), ("公司", "孩子学校"),
            ("家", "超市"), ("公司", "客户处"),
        ]

        for day_offset in range(days):
            day = now - timedelta(days=day_offset)
            rng = _seeded_rng(f"trips-{day:%Y%m%d}")
            # 周末出行少，工作日通勤多
            count = rng.choice([1, 2, 2, 3, 3, 4]) if day.weekday() < 5 else rng.choice([0, 1, 2])

            for i in range(count):
                start = day.replace(
                    hour=rng.randint(7, 20), minute=rng.choice([0, 15, 30, 45]), second=0, microsecond=0
                )
                distance = round(rng.uniform(3.5, 46.0), 1)
                duration = round(distance / rng.uniform(18, 42) * 60, 0)
                consumption = round(rng.uniform(14.2, 21.5), 1)
                energy = round(distance / 100 * consumption, 2)
                origin, dest = rng.choice(places)

                trips.append({
                    "tripId": f"{day:%Y%m%d}-{i}",
                    "startTime": start.strftime("%Y-%m-%d %H:%M:%S"),
                    "endTime": (start + timedelta(minutes=duration)).strftime("%Y-%m-%d %H:%M:%S"),
                    "distanceKm": distance,
                    "energyKwh": energy,
                    "avgSpeedKmh": round(distance / (duration / 60), 1) if duration else None,
                    "maxSpeedKmh": round(rng.uniform(60, 118), 0),
                    "consumption": consumption,
                    "startPlace": origin,
                    "endPlace": dest,
                    "durationMinutes": duration,
                })

        trips.sort(key=lambda t: t["startTime"], reverse=True)
        return trips

    async def get_charge_sessions(self, vin: str | None = None) -> list[dict[str, Any]]:
        """模拟官方「充电记录」（约 10 个月，形状与真实接口归一化后一致）。

        刻意让数据带上真实世界的几个特征，否则演示页看不出问题：
          · 当月次数少于历史月（月初/月中视角）；
          · 直流占绝大多数，交流零星几笔（家充上报本来就少）；
          · 单次电量差异大（20~90 度），免得平均值看起来像"每次一样多"。
        站点名与金额**留空** —— 真实接口就没有这两个字段，
        演示数据如果编出来，上线后用户会以为"本来有、后来丢了"。
        """
        now = datetime.now()
        sessions: list[dict[str, Any]] = []

        for month_offset in range(10):
            anchor = (now.replace(day=1) - timedelta(days=month_offset * 28)).replace(day=1)
            year, month = anchor.year, anchor.month
            last_day = calendar.monthrange(year, month)[1]
            # 当月只到"今天"为止，历史月给满
            upper = now.day if month_offset == 0 else last_day
            rng = _seeded_rng(f"charge-{year}{month:02d}")

            count = rng.randint(3, 6) if month_offset else max(1, min(4, now.day // 8 + 1))
            for i in range(count):
                day = rng.randint(1, max(1, upper))
                start = datetime(
                    year, month, day,
                    rng.choice([7, 12, 18, 21, 22]), rng.choice([3, 15, 28, 41, 55]), 0,
                )
                is_ac = rng.random() < 0.12
                power = round(rng.uniform(18, 32) if is_ac else rng.uniform(38, 88), 1)
                duration = round(power / (rng.uniform(6.5, 7.2) if is_ac else rng.uniform(60, 95)) * 60)

                sessions.append(
                    {
                        "sessionId": f"zeekr:mock-{year}{month:02d}-{i}",
                        "source": "zeekr",
                        "startTime": start.strftime("%Y-%m-%d %H:%M:%S"),
                        "endTime": (start + timedelta(minutes=duration)).strftime(
                            "%Y-%m-%d %H:%M:%S"
                        ),
                        "durationMin": float(duration),
                        "energyKwh": power,
                        "chargeType": "ac" if is_ac else "dc",
                        "chargeTypeName": "交流" if is_ac else "直流",
                    }
                )

        sessions.sort(key=lambda s: s["startTime"], reverse=True)
        return sessions

    async def get_daily_energy(
        self,
        vin: str | None = None,
        days: int = 30,
        scope: str = "window",
        year_month: str | None = None,
    ) -> dict[str, Any]:
        """模拟「行程与能耗」日统计（形状与官方接口一致）。"""
        now = datetime.now()
        if year_month and year_month not in ("currentMonth", "current"):
            year, month = (int(x) for x in year_month.split("-")[:2])
            last_day = calendar.monthrange(year, month)[1]
            days = last_day
            first = datetime(year, month, 1)
            last = datetime(year, month, last_day)
        else:
            if scope == "month":
                days = now.day
            days = max(1, min(int(days), 31))
            first = datetime(now.year, now.month, now.day) - timedelta(days=days - 1)
            last = now

        series: list[dict[str, Any]] = []
        total_km = 0.0
        total_kwh = 0.0

        for offset in range(days):
            day = first + timedelta(days=offset)
            rng = _seeded_rng(f"energy-{day:%Y%m%d}")
            # 演示：约五分之一的天数不动车，其余通勤为主
            if rng.random() < 0.2:
                continue
            distance = round(rng.uniform(18, 52), 1)
            consumption = round(rng.uniform(14.8, 19.6), 1)
            energy = round(distance / 100 * consumption, 2)
            total_km += distance
            total_kwh += energy
            series.append({
                "date": day.strftime("%Y-%m-%d"),
                "distanceKm": distance,
                "energyKwh": energy,
                "minutes": int(distance / rng.uniform(0.5, 0.9)),
                "consumption": consumption,
            })

        avg = round(total_kwh / total_km * 100, 1) if total_km > 0 else 0.0
        return {
            "days": days,
            "startDate": first.strftime("%Y年%m月%d日"),
            "endDate": last.strftime("%Y年%m月%d日"),
            "distanceKm": round(total_km, 1),
            "energyKwh": round(total_kwh, 2),
            "dynamicEnergyKwh": round(total_kwh * 0.94, 2),
            "avgConsumption": round(avg * 1.06, 1),
            "avgDynamicConsumption": avg,
            "fastChargeCount": max(0, days // 9),
            "slowChargeCount": max(0, days // 21),
            "series": series,
        }

    async def get_energy_months(self, vin: str | None = None) -> dict[str, Any]:
        """模拟可选月份清单（本月 + 前 5 个月）。"""
        now = datetime.now()
        months = [{"yearMonth": "currentMonth", "label": "本月"}]
        for i in range(1, 6):
            year, month = now.year, now.month - i
            if month <= 0:
                year, month = year - 1, month + 12
            months.append({"yearMonth": f"{year}-{month:02d}", "label": f"{year}年{month}月"})
        month_brief = await self.get_daily_energy(scope="month")
        return {
            "months": months,
            "monthMileageKm": month_brief["distanceKm"],
            "monthEnergyKwh": month_brief["energyKwh"],
        }

    async def get_energy_trend(self, vin: str | None = None, days: int = 30) -> list[dict[str, Any]]:
        now = datetime.now()
        series: list[dict[str, Any]] = []

        for offset in range(days - 1, -1, -1):
            day = now - timedelta(days=offset)
            rng = _seeded_rng(f"trend-{day:%Y%m%d}")
            is_weekend = day.weekday() >= 5
            distance = round(rng.uniform(8, 32) if is_weekend else rng.uniform(28, 68), 1)
            consumption = round(rng.uniform(14.5, 20.5), 1)
            # 冬季能耗偏高
            if day.month in (12, 1, 2):
                consumption = round(consumption * 1.18, 1)

            series.append({
                "date": day.strftime("%Y-%m-%d"),
                "distanceKm": distance,
                "energyKwh": round(distance / 100 * consumption, 2),
                "consumption": consumption,
                "tripCount": rng.choice([1, 2, 2, 3, 3, 4]),
            })

        return series

    # MARK: 车控

    async def send_command(
        self,
        command: str,
        params: dict[str, Any] | None = None,
        vin: str | None = None,
    ) -> dict[str, Any]:
        # 指令白名单直接取自 COMMAND_MAP，避免两处定义漂移
        if command not in COMMAND_MAP:
            return {"success": False, "message": f"不支持的指令: {command}", "command": command}
        # commandId 是查询车端执行结果用的凭据；模拟模式下用指令名构造一个稳定的值
        return {
            "success": True,
            "message": f"指令「{command}」已下发（模拟模式）",
            "command": command,
            "commandId": f"mock-{command}",
        }

    async def get_command_result(
        self,
        command_id: str,
        vin: str | None = None,
    ) -> dict[str, Any]:
        """模拟车端已执行。

        刻意返回 `done` 而不是 `pending`：模拟模式的目的就是让"下发 →
        等待确认 → 已执行"这条链路可视，卡在 pending 就看不到后半段。
        """
        return {"status": "done", "message": "车端确认已执行（模拟）"}

    # MARK: 附近充电站

    async def get_nearby_stations(
        self,
        lat: float,
        lng: float,
        zoom: int = 13,
    ) -> list[dict[str, Any]]:
        """附近充电站（模拟），**含站名与电价**。

        与真实侧的唯一差别：真实侧这两样必须另问浩汉网关才有，
        这里一并给出 —— 离线演示时若整页只有坐标没名字，看不出设计好坏。

        用**传入坐标做随机种子**：同一位置反复请求结果稳定，换个位置结果就变。
        这一点是有意设计的 —— 若无论怎么定位列表都纹丝不动，说明坐标根本没
        传下去，而这种故障光看界面是发现不了的。

        站名一律带「演示」字样：模拟数据不该长得像真实场站，
        否则截图流出后会被当成真的站点信息。
        """
        rng = _seeded_rng(f"stations-{lat:.3f}-{lng:.3f}")

        # (站名, 距离km, 可用枪, 总枪, 交流枪, 直流枪, 自营)
        presets: list[tuple[str, float, int, int, int, int, bool]] = [
            ("极氪超充·演示站 A", 0.35, 6, 8, 0, 8, True),
            ("演示站 B · 商场地下层", 0.80, 2, 12, 12, 0, False),
            ("演示站 C · 高架旁", 1.40, 11, 16, 4, 12, False),
            ("极氪超充·演示站 D", 2.10, 3, 4, 0, 4, True),
            ("演示站 E · 写字楼", 2.60, 0, 6, 6, 0, False),
            ("演示站 F · 客运站", 3.20, 9, 10, 0, 10, False),
            # 下面这批是为了让**分页真的能翻**：首屏 10 条，
            # 只有 6 个站的话界面上永远只有一页，"滚动分页"无从验证。
            ("演示站 G · 小区门口", 3.80, 1, 4, 4, 0, False),
            ("极氪超充·演示站 H", 4.30, 8, 12, 0, 12, True),
            ("演示站 I · 医院停车场", 4.90, 4, 8, 8, 0, False),
            ("演示站 J · 酒店地库", 5.40, 6, 8, 4, 4, False),
            ("演示站 K · 物流园", 6.10, 8, 12, 0, 12, False),
            ("演示站 L · 学校对面", 6.70, 2, 6, 6, 0, False),
            ("极氪超充·演示站 M", 7.30, 5, 8, 0, 8, True),
            ("演示站 N · 商场 B2", 7.90, 10, 16, 8, 8, False),
            ("演示站 O · 体育馆", 8.60, 7, 10, 0, 10, False),
            ("演示站 P · 科技园", 9.20, 3, 6, 0, 6, False),
            ("演示站 Q · 加油站旁", 9.90, 5, 6, 0, 6, False),
            ("演示站 R · 农贸市场", 10.50, 2, 4, 4, 0, False),
            ("极氪超充·演示站 S", 11.30, 6, 10, 0, 10, True),
            ("演示站 T · 度假村", 12.10, 4, 8, 8, 0, False),
            ("演示站 U · 汽车城", 12.90, 9, 12, 4, 8, False),
            ("演示站 V · 火车站", 13.80, 12, 20, 10, 10, False),
            ("演示站 W · 产业园区", 14.60, 5, 8, 0, 8, False),
            ("极氪超充·演示站 X", 15.40, 7, 12, 0, 12, True),
        ]
        # 分时电价：(电费, 服务费) 序列，长度 1 = 全天一口价，>1 = 尖峰平谷
        plans: list[list[tuple[float, float]]] = [
            [(1.10, 0.80)],
            [(0.37, 0.98), (0.72, 0.98), (1.10, 0.55), (0.83, 0.72)],
            [(0.95, 0.60)],
            [(0.42, 1.05), (1.05, 0.60), (0.78, 0.80)],
            [(1.20, 0.90)],
            [(0.55, 0.85), (0.95, 0.65)],
        ]
        frames: list[list[str]] = [
            ["00:00-23:59"],
            ["00:00-06:00", "06:00-11:00", "11:00-22:00", "22:00-23:59"],
            ["00:00-23:59"],
            ["00:00-07:00", "07:00-10:00", "10:00-23:59"],
            ["00:00-23:59"],
            ["00:00-08:00", "08:00-23:59"],
        ]
        # 固定方位角：让坐标与距离大致自洽（距离由服务端 haversine 重算）
        bearings = [35, 110, 200, 290, 155, 245]
        now = datetime.now()

        stations: list[dict[str, Any]] = []
        for index, (name, distance, available, total, ac, dc, self_operate) in enumerate(presets):
            bearing = math.radians(bearings[index % len(bearings)])
            # 纬度 1° ≈ 111km；经度还要除以 cos(纬度)
            lat_offset = (distance / 111.0) * math.cos(bearing)
            lng_offset = (distance / (111.0 * max(math.cos(math.radians(lat)), 0.2))) * math.sin(bearing)

            station_frames = frames[index % len(frames)]
            station_plan = plans[index % len(plans)]
            current = _current_period_index(station_frames, now)
            periods = [
                {
                    "timeFrame": frame,
                    "electric": plan[0],
                    "service": plan[1],
                    "total": round(plan[0] + plan[1], 2),
                }
                for frame, plan in zip(station_frames, station_plan)
            ]
            active = periods[current]
            # 可用枪按"直流优先"拆分（只是一个自洽的演示分配，不追求真实调度）
            able_dc = min(available, dc)
            able_ac = max(0, available - able_dc)

            stations.append({
                "stationId": f"mock-station-{index + 1}",
                "name": name,
                "address": f"演示路 {index + 1} 号（模拟数据）",
                "lat": round(lat + lat_offset, 6),
                "lng": round(lng + lng_offset, 6),
                "score": round(rng.uniform(3.6, 4.9), 1),
                "tags": ["演示数据"],
                "selfOperate": self_operate,
                "marketingPrice": False,
                "availableCount": available,
                "totalCount": total,
                "acCount": ac,
                "dcCount": dc,
                "ableAcCount": able_ac,
                "ableDcCount": able_dc,
                "stationStatus": 50,
                "price": {
                    "totalPrice": active["total"],
                    "feeElectric": active["electric"],
                    "serviceFee": active["service"],
                    "currentPeriod": active["timeFrame"],
                    "periods": periods,
                    "parkingFee": "按停车场标准收费" if not self_operate else "充电期间免费",
                    "parkFree": self_operate,
                    "holdFee": index == 3,
                    "feeDesc": "模拟数据：分时段计费，不同枪功率存在定价差异",
                },
            })

        return stations

    async def get_capabilities(self, vin: str | None = None) -> dict[str, Any]:
        """车辆权限包 + 能力集（模拟）。

        刻意让这台"车"缺少座椅通风 / 遮阳帘 / 车载冰箱 / 香氛 / 供氧 /
        哨兵照片 —— 用来演示 UI 如何按能力裁剪控件（这些按钮根本不会出现）。

        `permissions` 与 `capabilities` 的关系照抄真实侧：
        权限包只覆盖「服务类」功能（充电管理 / 车辆守卫 / 行程），
        硬件能力（胎压 / 空调 / 车窗…）由 `capabilities` 表达 ——
        真实侧对硬件能力**不下判断**，这里保留完整表只是为了演示裁剪效果。

        `verified=False`：这是模拟数据，不是真车实测结论。
        """
        return {
            "permissions": [
                "vehicle-share", "remote-control", "charge-manage",
                "view-vehicle-location", "owner-vehicle-trail",
            ],
            "capabilities": {
                "doorLock": True,
                "climate": True,
                "window": True,
                "trunk": True,
                "frunk": True,
                "tyrePressure": True,
                "tyreTemp": True,
                "seatHeat": True,
                "seatVent": False,
                "wheelHeat": True,
                "defrost": True,
                "sunshade": False,
                "sentinel": True,
                "sentinelPhoto": False,
                "carFridge": False,
                "fragrance": False,
                "oxygenSupply": False,
                "chargingPlan": True,
                "travelPlan": True,
                "tripTrack": True,
                "geofence": True,
            },
            "chargePlan": {
                "enabled": True,
                "startTime": "23:30",
                "endTime": "06:30",
                "targetSoc": 90,
                "mode": "谷电优先",
            },
            "verified": False,
        }
