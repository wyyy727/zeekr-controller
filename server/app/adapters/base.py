"""极氪国区接入层的抽象接口。

设计目的：**让上层业务与具体数据源解耦**。
- `LiveZeekrClient`：真实对接极氪国区网关（需密钥）
- `MockZeekrClient`：生成合理模拟数据，便于无凭据开发与演示

上层通过 `get_client()` 获取实例，不关心底层是真实还是模拟。
"""

from __future__ import annotations

from abc import ABC, abstractmethod
from typing import Any


class ZeekrClient(ABC):
    """极氪车辆数据客户端抽象基类。"""

    # MARK: - 认证

    @abstractmethod
    async def send_sms_code(self, phone: str) -> dict[str, Any]:
        """请求短信验证码。

        Returns:
            {"success": bool, "message": str}
        """
        raise NotImplementedError

    @abstractmethod
    async def verify_sms_code(self, phone: str, code: str) -> dict[str, Any]:
        """校验短信验证码并建立会话。

        Returns:
            {"success": bool, "message": str, "vehicle_count": int}
        """
        raise NotImplementedError

    @abstractmethod
    async def is_authenticated(self) -> bool:
        """当前是否持有可用会话。"""
        raise NotImplementedError

    @abstractmethod
    async def logout(self) -> None:
        """清除本地会话。"""
        raise NotImplementedError

    # MARK: - 车辆数据

    @abstractmethod
    async def list_vehicles(self) -> list[dict[str, Any]]:
        """获取账号下的车辆列表。"""
        raise NotImplementedError

    @abstractmethod
    async def get_vehicle_status(self, vin: str | None = None) -> dict[str, Any]:
        """获取车辆实时状态（已归一化为前端契约字段）。"""
        raise NotImplementedError

    @abstractmethod
    async def get_trips(self, vin: str | None = None, days: int = 30) -> list[dict[str, Any]]:
        """获取行程记录。"""
        raise NotImplementedError

    @abstractmethod
    async def get_energy_trend(self, vin: str | None = None, days: int = 30) -> list[dict[str, Any]]:
        """获取能耗趋势。"""
        raise NotImplementedError

    # MARK: - 车控

    @abstractmethod
    async def send_command(
        self,
        command: str,
        params: dict[str, Any] | None = None,
        vin: str | None = None,
    ) -> dict[str, Any]:
        """下发车控指令。

        Returns:
            {"success": bool, "message": str, "command": str}
        """
        raise NotImplementedError
