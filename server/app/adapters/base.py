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

    # MARK: - 车辆能力集

    @abstractmethod
    async def get_capabilities(self, vin: str | None = None) -> dict[str, Any]:
        """获取车辆能力集（以及预约充电计划）。

        「先问车支持什么，再决定 UI 显示什么」—— 前端据此裁剪控件，
        避免出现按了没反应的死按钮。

        Returns:
            {
              "capabilities": dict[str, bool] | None,   # None = 未取到（前端按"全部显示"处理）
              "chargePlan": dict | None,
              "verified": bool,                          # 能力集映射是否已真车确认
            }
        """
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
            {"success": bool, "message": str, "command": str, "commandId": str}
        """
        raise NotImplementedError

    @abstractmethod
    async def get_command_result(
        self,
        command_id: str,
        vin: str | None = None,
    ) -> dict[str, Any]:
        """查询车控指令的**车端执行结果**。

        为什么需要它：网关返回"已提交"只代表它收下了，**不代表车动了**。
        不查结果的客户端会把"已提交"当成功，造成"以为锁了车其实没锁"的
        假成功 —— 这是安全问题，不是体验问题。

        对应官方接口 `ms-remote-control/api/v1.0/remoteControl/queryProcessResult`。

        Returns:
            {"status": "pending" | "done" | "failed", "message": str}
        """
        raise NotImplementedError
