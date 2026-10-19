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
def _isolate_from_local_env(monkeypatch: pytest.MonkeyPatch, tmp_path):
    """把配置固定成与 `.env` 无关的确定状态。"""
    from app.adapters import reset_client
    from app.core.config import config
    from app.core.store import Store
    import app.main as main_module

    monkeypatch.setattr(config, "data_source", "mock", raising=False)
    monkeypatch.setattr(config, "api_token", "", raising=False)

    # 数据库也必须隔离。
    #
    # `app.main.store` 在**导入时**就按 `config.database` 建好了，而它的默认值
    # 指向 `server/data/zeekr.db`（开发者的真实库）。于是任何打到 `/api/trips`
    # 或 `/api/vehicle/status` 的用例，都会把 mock 生成的假行程 / 假快照写进
    # 真实库 —— 2026-10-19 就是这么攒出 60 条"看起来像真的"假行程的，
    # 排查时差点被当成真实数据。
    #
    # 只改 config 不够：store 是导入时创建的对象，必须一并重建。
    # 路由里用的是 `from ..main import store`（函数内导入），取的是模块属性，
    # 所以重建后立即生效。
    monkeypatch.setattr(config, "database", tmp_path / "test.db", raising=False)
    main_module.store = Store(config.database)

    reset_client()
    try:
        yield
    finally:
        # monkeypatch 会还原字段值，但全局单例里还留着按旧配置建出的实例，
        # 必须清掉，否则会带进下一个用例。
        reset_client()
