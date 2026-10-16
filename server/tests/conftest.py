"""pytest 全局夹具。

**测试环境必须与本机 `.env` 隔离。**

不隔离会出这种问题：本机 `.env` 里密钥填齐时 `use_mock` 为 False，
`get_client()` 返回 `LiveZeekrClient`，于是任何打真实路由的测试都会去连
极氪真网关（未登录时抛 `ValueError: VIN 不能为空` 并冒成 500）。

结果是「测试红不红」取决于**开发者本机有没有配密钥**，而不是取决于代码
对不对 —— 这类失败极具误导性：看起来是代码坏了，其实是环境不同。

所以这里统一把数据源固定为 mock，并重置全局单例。需要真实网关行为的用例
应**直接构造** `LiveZeekrClient`（不经 `get_client()`），或在用例自己的
夹具里显式改回来。

`api_token` 一并归零，理由相同：`TestApiTokenMiddleware` 断言的是代码的
默认行为（不设令牌即不鉴权），不该被本机 `.env` 里的值左右。
"""

from __future__ import annotations

import pytest


@pytest.fixture(autouse=True)
def _isolate_from_local_env(monkeypatch: pytest.MonkeyPatch):
    """把配置固定成与 `.env` 无关的确定状态。"""
    from app.adapters import reset_client
    from app.core.config import config

    monkeypatch.setattr(config, "data_source", "mock", raising=False)
    monkeypatch.setattr(config, "api_token", "", raising=False)
    reset_client()
    try:
        yield
    finally:
        # monkeypatch 会还原字段值，但全局单例里还留着按旧配置建出的实例，
        # 必须清掉，否则会带进下一个用例。
        reset_client()
