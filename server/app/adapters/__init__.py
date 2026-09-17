"""数据源工厂。

根据配置返回合适的数据源实例：
- 配置齐全 → LiveZeekrClient（真实对接）
- 配置缺失 / 显式指定 → MockZeekrClient（模拟数据）

上层通过 `get_client()` 获取，不感知具体实现。
"""

from __future__ import annotations

import logging

from ..core.config import config
from .base import ZeekrClient
from .live_client import LiveZeekrClient
from .mock_client import MockZeekrClient

logger = logging.getLogger(__name__)

_client: ZeekrClient | None = None


def get_client() -> ZeekrClient:
    """获取全局数据源实例（单例）。"""
    global _client

    if _client is not None:
        return _client

    if config.use_mock:
        if config.data_source == "auto":
            missing = config.zeekr.missing_keys()
            logger.warning(
                "极氪配置不完整，使用模拟数据。缺失：%s",
                "、".join(missing) if missing else "无",
            )
        else:
            logger.info("按配置要求使用模拟数据源")
        _client = MockZeekrClient()
    else:
        logger.info("使用真实极氪国区数据源（手机号：%s****）", config.zeekr.phone[:3])
        _client = LiveZeekrClient(config.zeekr)

    return _client


def reset_client() -> None:
    """重置数据源（配置变更后调用）。"""
    global _client
    _client = None


def is_mock() -> bool:
    """当前是否为模拟数据源。"""
    return isinstance(get_client(), MockZeekrClient)
