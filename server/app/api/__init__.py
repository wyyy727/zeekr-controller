"""API 包。

这里放各路由共用的**错误构造助手**，统一「对外说人话、对内留细节」的约定。
"""

from __future__ import annotations

import logging
from typing import NoReturn

from fastapi import HTTPException

logger = logging.getLogger(__name__)


def upstream_error(
    user_message: str,
    exc: BaseException,
    *,
    status_code: int = 500,
) -> HTTPException:
    """构造「上游调用失败」的 HTTP 错误，**不把原始异常回显给客户端**。

    为什么统一：网关报文里可能夹带 accessToken / JWT 片段，直接把 `exc`
    拼进 `detail` 会顺着响应体泄给浏览器。完整异常只进服务端日志。

    历史缺陷：auth / charges / trips 三处写的是
    `detail=f"……失败：{exc}"`，而 vehicle 处已正确地不回显 —— 同类错误
    两套写法，导致是否泄露取决于具体接口。
    """
    logger.error(user_message, exc_info=exc)
    return HTTPException(status_code=status_code, detail=user_message)


def fail(user_message: str, exc: BaseException, *, status_code: int = 500) -> NoReturn:
    """`upstream_error` 的 raise 版，便于一行写完。"""
    raise upstream_error(user_message, exc, status_code=status_code)


__all__ = ["upstream_error", "fail"]
