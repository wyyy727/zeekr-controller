"""进程内定时任务。

目前只有一件事：**日电耗保底同步**。

为什么需要：`GET /api/trips/energy` 回源成功时会把逐日电耗 upsert 进
`energy_daily`（见 `api/trips.py::_persist_energy_daily`），也就是说数据是
"用户打开行程页"这个动作顺带攒下来的。连续几天不打开页面，那几天就要等到
下次打开才补。官方日统计只允许回查 60 天，所以真正丢数据的风险很低，但
用户明确要一个"不用管也在攒"的保底，于是加了这个循环。

成本：默认每 6 小时一次、每次回看 7 天，落在官方单次 ≤31 天的窗口内，
所以一次只打一个请求；写入是 `ON CONFLICT DO UPDATE`，重复跑不会翻倍。
"""

from __future__ import annotations

import asyncio
import logging

logger = logging.getLogger(__name__)

# 启动后先等一会儿再跑第一次：进程刚起来时登录态可能还没恢复完（session.json
# 在第一次取 client 时才装载），立刻打官方接口容易白跑一次。
STARTUP_DELAY_SEC = 20.0


async def _run_once(days: int) -> dict:
    # 延迟导入避免循环依赖：api.trips → ..main → core.scheduler → api.trips
    from ..api.trips import sync_energy_window

    return await sync_energy_window(days)


async def energy_sync_loop(interval_hours: float, days: int) -> None:
    """每 interval_hours 小时把最近 days 天的逐日电耗补一次。

    任何一次失败都只记日志、不退出循环 —— 保底任务本身不该成为新的故障点。
    """
    logger.info(
        "日电耗保底同步已启动：每 %s 小时回看最近 %s 天", interval_hours, days
    )
    try:
        await asyncio.sleep(STARTUP_DELAY_SEC)
        while True:
            try:
                data = await _run_once(days)
                if data.get("mode") == "mock":
                    logger.info("日电耗保底同步跳过：当前为模拟数据模式")
                else:
                    logger.info(
                        "日电耗保底同步完成：写入 %s 行，最新 %s",
                        data.get("written"),
                        data.get("latest"),
                    )
            except asyncio.CancelledError:
                raise
            except Exception:  # noqa: BLE001
                logger.warning(
                    "日电耗保底同步失败，%s 小时后重试", interval_hours, exc_info=True
                )
            await asyncio.sleep(interval_hours * 3600)
    except asyncio.CancelledError:
        logger.info("日电耗保底同步已停止")
        raise
