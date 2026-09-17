"""Mock 数据源。

用途：
1. 无凭据时演示 UI 与接口契约
2. 单元测试与联调
3. 前端的 `#Preview` 预览数据

生成的数据带有确定性随机（以日期为种子），
同一天内多次请求结果稳定，便于观察趋势。
"""

from __future__ import annotations

import hashlib
import math
import random
from datetime import datetime, timedelta
from typing import Any

from .base import ZeekrClient
from .zeekr_signing import COMMAND_MAP

MOCK_VIN = "L6TDEMOCK00000001"


def _seeded_rng(seed_text: str) -> random.Random:
    """基于文本生成确定性随机数发生器。"""
    digest = hashlib.md5(seed_text.encode("utf-8")).hexdigest()
    return random.Random(int(digest[:16], 16))


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
                "nickname": "我的极氪 001",
                "plateNo": "粤A·D88888",
                "modelName": "极氪 001",
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
            "nickname": "我的极氪 001",
            "plateNo": "粤A·D88888",
            "modelName": "极氪 001",
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
            "doors": {
                "frontLeft": False,
                "frontRight": False,
                "rearLeft": False,
                "rearRight": False,
            },
            "windows": {
                "frontLeft": False,
                "frontRight": False,
                "rearLeft": False,
                "rearRight": False,
            },
            "trunkOpen": False,
            "frunkOpen": False,
            "tyreFrontLeft": round(rng.uniform(235, 252), 0),
            "tyreFrontRight": round(rng.uniform(235, 252), 0),
            "tyreRearLeft": round(rng.uniform(238, 255), 0),
            "tyreRearRight": round(rng.uniform(238, 255), 0),
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
        return {
            "success": True,
            "message": f"指令「{command}」已下发（模拟模式）",
            "command": command,
        }
