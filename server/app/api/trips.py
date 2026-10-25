"""行程与能耗接口。"""

from __future__ import annotations

import logging
import re
import time

from datetime import datetime, timedelta

from fastapi import APIRouter, HTTPException

from ..adapters import get_client, is_mock
from . import fail


class EnergyWindowError(ValueError):
    """窗口或参数错误：文案可以安全回给前端（不含内部实现细节）。"""

logger = logging.getLogger(__name__)

router = APIRouter()

# 行程缓存有效期（秒）。
#
# 历史缺陷：`if cached: return cached` 意味着只要库里**有过**数据，就永远
# 不再回源 —— 新行程再也进不来，用户看到的是永远停在第一次拉取那天的列表。
# 现在缓存只保证「短时间内不重复打网关」，超过 TTL 仍会回源刷新。
TRIPS_CACHE_TTL_SEC = 300

# 进程内记录各缓存键的上次刷新时刻（keys: f"{vin}:{days}"）。
# 单进程自用场景够用；多进程部署时应改为落库的时间戳。
_last_refresh: dict[str, float] = {}


def _cache_key(vin: str | None, days: int) -> str:
    return f"{vin or '-'}:{days}"


def _is_cache_fresh(vin: str | None, days: int) -> bool:
    """缓存是否仍在 TTL 内。"""
    stamped = _last_refresh.get(_cache_key(vin, days))
    if stamped is None:
        return False
    return (time.monotonic() - stamped) < TRIPS_CACHE_TTL_SEC


# MARK: - 逐日电耗落库
#
# 官方日统计接口只允许回查 60 天（A010，见 live_client.get_daily_energy），
# 不落库的话三个月前的逐日里程/电耗就永久丢了。策略：
#   · 读路径（GET /trips/energy）回源成功后顺手写库，不需要额外操作；
#   · POST /trips/energy/sync 用于首次安装后一次性补齐，或长期没开 App 时补洞；
#   · 回源失败时用库里的数据兜底，离线也能看柱图。
# mock 模式一律不写，避免演示数据污染真库。


def _resolve_vin(client, vin: str | None) -> str:
    """尽力拿到当前车架号：显式参数 > 客户端会话 > 空串。"""
    if vin:
        return vin
    session = getattr(client, "_session", None) or {}
    if isinstance(session, dict):
        return str(session.get("active_vin") or "")
    return ""


def _persist_energy_daily(client, vin: str | None, data: dict | None) -> int:
    """把日统计结果按 (vin, date) 幂等写入；任何失败都不影响本次返回。"""
    if is_mock():
        return 0
    series = (data or {}).get("series") or []
    target = _resolve_vin(client, vin)
    if not series or not target:
        return 0
    from ..main import store

    try:
        return store.save_energy_daily(target, series)
    except Exception:  # noqa: BLE001
        logger.exception("日电耗落库失败（本次请求照常返回）")
        return 0


def _energy_from_store(vin: str | None, days: int) -> dict | None:
    """用本地库拼一份和官方接口同形的结果，供回源失败时兜底。"""
    if not vin:
        return None
    from ..main import store

    rows = store.list_energy_daily(vin, days=days)
    if not rows:
        return None

    total_distance = round(sum(r["distanceKm"] for r in rows), 1)
    total_energy = round(sum(r["energyKwh"] for r in rows), 2)
    split_rows = [r for r in rows if r.get("dynamicKwh") is not None]
    total_dynamic = round(sum(r["dynamicKwh"] for r in split_rows), 2) if split_rows else None
    total_static = round(sum(r["staticKwh"] for r in split_rows), 2) if split_rows else None
    return {
        "days": days,
        "startDate": rows[0]["date"],
        "endDate": rows[-1]["date"],
        "distanceKm": total_distance,
        "energyKwh": total_energy,
        # 动态/静态拆分只有新写入的行才有（老行该列是 NULL），
        # 没有拆分行时给 null，前端 fmt() 显示「--」，不会崩。
        "dynamicEnergyKwh": total_dynamic,
        "staticEnergyKwh": total_static,
        "avgConsumption": round(total_energy / total_distance * 100, 1) if total_distance > 0 else None,
        "avgDynamicConsumption": None,
        "fastChargeCount": None,
        "slowChargeCount": None,
        "series": rows,
        "fromCache": True,
    }


@router.get("/trips")
async def get_trips(
    days: int = 30,
    vin: str | None = None,
    # 默认值用裸 False 而非 Query(False)：Query(...) 返回的是 FieldInfo 对象，
    # 直接调用函数时它是真值，会让 `not force` 永远为假、缓存判定被短路跳过。
    force: bool = False,
) -> dict:
    """获取行程记录。

    策略：TTL 内直接用本地库（快）；缓存过期或 `force=true` 时回源刷新并落库。
    网关失败时降级返回已有缓存，而不是把空结果糊给用户。
    """
    if not 1 <= days <= 365:
        raise HTTPException(status_code=400, detail="days 取值范围为 1–365")

    from ..main import store

    cached = store.list_trips(days=days)
    if cached and not force and _is_cache_fresh(vin, days):
        return {"success": True, "data": cached, "cached": True}

    client = get_client()
    try:
        trips = await client.get_trips(vin=vin, days=days)
    except Exception as exc:  # noqa: BLE001
        logger.error("获取行程失败：%s", exc)
        if cached:
            # 回源失败但有旧数据 —— 降级返回旧数据，好过直接报错
            logger.warning("回源失败，降级返回 %d 条缓存行程", len(cached))
            return {"success": True, "data": cached, "cached": True, "stale": True}
        # 不回显原始异常：网关报文可能含令牌片段
        fail("获取行程失败，请检查服务端日志与登录状态", exc)

    # ⚠️ 模拟数据**绝不落库**。
    #
    # 历史事故（2026-10-19 发现）：mock 客户端会返回一整套生成的行程，这里曾经
    # 无条件 `save_trips`，于是「跑一次模拟模式 / 跑一次测试」就把假行程写进了
    # 生产库。更糟的是它**长得像真的**（日期连续、距离合理），而读路径又分不清
    # 来源 —— 结果整页行程都是编的，还会一直"新鲜"（mock 以当天为基准生成）。
    # 判据只能是数据源本身：mock 就不写。
    if trips and not is_mock():
        try:
            store.save_trips(trips)
        except Exception as exc:  # noqa: BLE001
            logger.warning("行程落库失败：%s", exc)

    # 无论本次是否拿到新数据，都记一次刷新时刻，避免网关异常时被打爆
    _last_refresh[_cache_key(vin, days)] = time.monotonic()

    return {"success": True, "data": trips or cached}


@router.get("/trips/energy")
async def get_daily_energy(
    days: int = 30,
    vin: str | None = None,
    scope: str = "window",
    yearMonth: str | None = None,
) -> dict:
    """官方「行程与能耗」日统计：汇总（里程/电耗/充电次数）+ 逐日序列。

    数据源是官方 App「行程统计」页同一个接口，口径与 App 一致。
    `days` 上限 31 是**服务端约束**（超了返回 A008），不是我们的选择。
    `scope=month` 取「本月 1 日至今」——**要跟官方 App 对得上就必须用这个**，
    否则「近 7 天」的充电次数天然小于 App 的本月值。
    `yearMonth=2026-09` 取指定月份：本月走日统计，历史月走月度报告
    （日统计接口对 60 天以前报 `A010`）。
    """
    if scope not in ("window", "month"):
        raise HTTPException(status_code=400, detail="scope 只能为 window 或 month")
    if scope == "window" and not 1 <= days <= 31:
        raise HTTPException(
            status_code=400, detail="days 取值范围为 1–31（官方接口单次最多 31 个自然日）"
        )
    if yearMonth and yearMonth not in ("currentMonth",):
        if not re.fullmatch(r"\d{4}-\d{2}", yearMonth):
            raise HTTPException(status_code=400, detail="yearMonth 格式应为 YYYY-MM")

    client = get_client()
    try:
        data = await client.get_daily_energy(
            vin=vin, days=days, scope=scope, year_month=yearMonth
        )
    except Exception as exc:  # noqa: BLE001
        # 回源失败：库里有多天数据就先兜底（离线也能看柱图）；实在没有才报错。
        cached = _energy_from_store(_resolve_vin(client, vin), days)
        if cached:
            logger.warning("能耗统计回源失败，改用本地库兜底：%s", exc.__class__.__name__)
            return {"success": True, "data": cached, "cached": True}
        # 不回显原始异常：网关报文可能含令牌片段
        fail("获取能耗统计失败，请检查服务端日志与登录状态", exc)

    # 回源成功：顺手落库，让 60 天窗口外的历史慢慢攒下来。
    _persist_energy_daily(client, vin, data)
    return {"success": True, "data": data}


async def sync_energy_window(days: int = 60, vin: str | None = None) -> dict:
    """把最近 N 天的逐日电耗补齐到本地库。

    官方日统计单次最多 31 个自然日、只允许回查 60 天，所以按 31 天分批，
    这里的 days 上限也就是 60。written 是写入或更新的行数 —— 重复调用
    同一天是覆盖而不是累加（表主键是 vin + date）。

    抽成模块级函数而不是只留在路由里，是为了让 core/scheduler.py 的保底
    任务复用同一段逻辑，避免"HTTP 端点与定时任务各写一份"。参数或登录态
    有问题抛 ValueError，上游失败仍走 fail()，由调用方决定怎么包装。
    """
    if not 1 <= days <= 60:
        raise EnergyWindowError("days 取值范围为 1–60（官方日统计只允许回查 60 天）")

    if is_mock():
        return {"mode": "mock", "written": 0, "days": days, "batches": 0}

    client = get_client()
    target = _resolve_vin(client, vin)
    if not target:
        raise EnergyWindowError("未找到车辆 VIN，请先登录并选择车辆")

    from ..main import store

    # 从今天 23:59:59 往回数，每批最多 31 天
    end = datetime.now().replace(hour=23, minute=59, second=59, microsecond=0)
    remaining = days
    written = 0
    batches = 0
    earliest: str | None = None

    while remaining > 0:
        span = min(remaining, 31)
        start = (end - timedelta(days=span - 1)).replace(
            hour=0, minute=0, second=0, microsecond=0
        )
        try:
            data = await client.get_daily_energy(
                vin=target,
                days=span,
                start_ms=int(start.timestamp() * 1000),
                end_ms=int(end.timestamp() * 1000),
            )
        except Exception as exc:  # noqa: BLE001
            fail("补齐日电耗失败，请检查服务端日志与登录状态", exc)

        rows = (data or {}).get("series") or []
        written += store.save_energy_daily(target, rows)
        batches += 1
        if rows:
            earliest = rows[0]["date"]

        remaining -= span
        # 下一批的终点 = 本批起点前一天 23:59:59
        end = start - timedelta(seconds=1)

    return {
        "vin": target,
        "days": days,
        "batches": batches,
        "written": written,
        "earliest": earliest,
        "latest": store.energy_daily_latest(target),
    }


@router.post("/trips/energy/sync")
async def sync_energy_daily(days: int = 60, vin: str | None = None) -> dict:
    """手动补齐端点：与后台保底任务共用 sync_energy_window。"""
    try:
        data = await sync_energy_window(days, vin)
    except EnergyWindowError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    except Exception as exc:  # noqa: BLE001
        # 其他异常（网关超时、签名失败……）只回通用文案，细节进日志：
        # str(exc) 可能带内网地址、令牌片段甚至 SQL。
        fail("补齐逐日电耗失败，请检查服务端日志与登录状态", exc)
    return {"success": True, "data": data}


@router.get("/trips/energy/months")
async def get_energy_months(vin: str | None = None) -> dict:
    """可选月份清单（官方 `mileageBaseInfo.existingMonth`）+ 车辆总里程。"""
    client = get_client()
    try:
        data = await client.get_energy_months(vin=vin)
    except Exception as exc:  # noqa: BLE001
        fail("获取可查月份失败，请检查服务端日志与登录状态", exc)

    return {"success": True, "data": data}


@router.get("/energy/trend")
async def get_energy_trend(days: int = 30, vin: str | None = None) -> dict:
    """获取能耗趋势（逐日）。"""
    if not 1 <= days <= 365:
        raise HTTPException(status_code=400, detail="days 取值范围为 1–365")

    client = get_client()
    try:
        trend = await client.get_energy_trend(vin=vin, days=days)
    except Exception as exc:  # noqa: BLE001
        # 不回显原始异常：网关报文可能含令牌片段
        fail("获取能耗趋势失败，请检查服务端日志与登录状态", exc)

    return {"success": True, "data": trend}
