"""模拟数据不得写入持久化库。

背景（2026-10-19）：开发库里出现了 60 条行程，起终点、距离、能耗齐全，
日期连续覆盖 25 天 —— 看上去像真的。实际全是 `mock_client` 现场生成的：
`api/trips.py` 无条件 `save_trips`，而测试又没有隔离数据库，于是
「跑一次测试 / 跑一次模拟模式」就往真实库写一批假数据。

这类污染的坏处不是"多了几条脏数据"，而是**假数据长得像真的**：
读路径分不清来源，页面照常展示，排查时还会被当成"接口曾经成功过"的证据
（这次就是这么误判的）。

所以这里钉两条：
1. mock 模式下，接口返回的数据不落库；
2. 测试用的必须是临时库 —— 否则跑测试本身就在污染开发数据。
"""

from __future__ import annotations


class TestMockDataIsNotPersisted:

    def test_trips_endpoint_returns_data_but_writes_nothing(self) -> None:
        from fastapi.testclient import TestClient

        from app.main import app, store

        before = len(store.list_trips(days=365))
        resp = TestClient(app).get("/api/trips", params={"days": 30})
        assert resp.status_code == 200

        # mock 客户端确实会返回一批行程（界面在无后端时要能演示），
        # 但**一条都不能进库**。
        assert resp.json()["data"], "mock 模式下 /api/trips 应返回演示数据"
        assert len(store.list_trips(days=365)) == before, "mock 行程被写进了库"

    def test_status_endpoint_does_not_store_snapshot(self) -> None:
        from fastapi.testclient import TestClient

        from app.main import app, store

        resp = TestClient(app).get("/api/vehicle/status")
        assert resp.status_code == 200

        vin = resp.json()["data"]["vin"]
        assert store.list_snapshots(vin=vin, limit=10) == [], "mock 快照被写进了库"

    def test_test_database_is_not_the_development_one(self) -> None:
        """夹具把库指向临时文件 —— 这条断言守的是夹具本身。"""
        from app.core.config import config

        assert config.database.name == "test.db", (
            f"测试库没有被隔离：{config.database}"
        )
