"""充电消费接口。

两组数据源，**不要混着理解**：

1. `charge_sessions`（自动化，已经打通）——官方「充电记录」接口给的
   电量 / 时长 / 交直流。它没有金额、没有站点名，因为车不知道电价，
   站点也不在这条链路上。
2. `charge_records`（历史遗留，实测 0 行）——支付账单解析出来的金额。
   文档结论：金额当前只有「截图 OCR / 手工」两条路，文件导入已废弃。

所以这个页面的正确形态是：**电量自动同步 + 金额按需补录**，
而不是让用户每月导一次账单。`/summary` 与 `/records` 保持旧契约不动
（前端已改用电量口径），新逻辑都走 `/sessions` 系列。
"""

from __future__ import annotations

import logging
import re
import time
import uuid
from datetime import datetime
from hashlib import sha256
from typing import Any

from fastapi import APIRouter, Body, File, Form, HTTPException, UploadFile

from ..adapters import get_client, is_mock
from ..adapters.vision_ocr import VisionFailed, VisionUnavailable, extract_receipts
from ..bills.aggregator import build_summary, import_bill
from ..bills.matching import candidate_matches, choose_match, parse_time, sanity_check
from ..bills.providers import provider_display_name
from ..core.config import config
from . import fail

logger = logging.getLogger(__name__)

router = APIRouter()

# 两次同步之间的最小间隔（秒）。
#
# 同步是**打官方网关**的（一次请求给两年全量），不加最小间隔的话，
# 用户连点按钮就会连打网关 —— 这类重复请求在极氪侧是有风控的。
# 本地已入库的数据不受影响，页面展示永远走本地库。
SYNC_MIN_INTERVAL_SEC = 10
_last_sync_at: float = 0.0

_MONTH_RE = re.compile(r"^\d{4}-(0[1-9]|1[0-2])$")


def _resolve_month(year_month: str | None) -> str:
    """把 `currentMonth` / 空值解析成真实的 `YYYY-MM`，并校验格式。"""
    if not year_month or year_month in ("currentMonth", "current"):
        return datetime.now().strftime("%Y-%m")
    if not _MONTH_RE.match(year_month):
        raise HTTPException(status_code=400, detail="yearMonth 格式应为 YYYY-MM")
    return year_month


def _month_label(ym: str) -> str:
    year, month = ym.split("-")
    return f"{year}年{int(month)}月"


async def _session_rows(year_month: str | None = None) -> list[dict[str, Any]]:
    """读充电流水。

    真实模式读**本地库**（不打网关）；模拟模式现算，**绝不落库**。

    为什么模拟模式不落库：历史上 `save_trips` 无条件写入，于是"跑一次模拟模式 /
    跑一次测试"就把 60 条假行程写进了真实库，排查时差点被当成真数据。
    所以这里显式分流，并在测试里守着（`test_sync_does_not_persist_mock`）。
    """
    if is_mock():
        rows = await get_client().get_charge_sessions()
        if year_month:
            rows = [r for r in rows if str(r.get("startTime", "")).startswith(year_month)]
        rows.sort(key=lambda r: str(r.get("startTime") or ""), reverse=True)
        # 补齐与真实库一致的键：模拟端没有金额/站点字段，但**契约必须一样**，
        # 否则前端要从"键不存在"和"值为 null"两种情况下都猜一遍。
        return [
            {
                "sessionId": r.get("sessionId"),
                "source": r.get("source") or "zeekr",
                "startTime": r.get("startTime"),
                "endTime": r.get("endTime"),
                "durationMin": r.get("durationMin"),
                "energyKwh": r.get("energyKwh"),
                "chargeType": r.get("chargeType"),
                "stationName": r.get("stationName"),
                "amount": r.get("amount"),
                "amountSource": r.get("amountSource"),
            }
            for r in rows
        ]

    from ..main import store

    return store.list_sessions(year_month=year_month)


async def _month_rows() -> list[dict[str, Any]]:
    """按月聚合清单。真实模式走 SQL；模拟模式在内存里聚合。"""
    if is_mock():
        rows = await get_client().get_charge_sessions()
        buckets: dict[str, dict[str, Any]] = {}
        for r in rows:
            ym = str(r.get("startTime") or "")[:7]
            if not ym:
                continue
            item = buckets.setdefault(
                ym,
                {"yearMonth": ym, "count": 0, "kwh": 0.0, "minutes": 0.0,
                 "amount": 0.0, "amountCount": 0, "dcCount": 0, "acCount": 0},
            )
            item["count"] += 1
            if isinstance(r.get("energyKwh"), (int, float)):
                item["kwh"] += float(r["energyKwh"])
            if isinstance(r.get("durationMin"), (int, float)):
                item["minutes"] += float(r["durationMin"])
            if r.get("chargeType") == "dc":
                item["dcCount"] += 1
            elif r.get("chargeType") == "ac":
                item["acCount"] += 1
        out = []
        for ym in sorted(buckets, reverse=True):
            item = buckets[ym]
            item["kwh"] = round(item["kwh"], 1)
            item["minutes"] = round(item["minutes"])
            item["avgMinutes"] = round(item["minutes"] / item["count"]) if item["count"] else None
            out.append(item)
        return out

    from ..main import store

    return store.session_months()


def _summarize_month(ym: str, rows: list[dict[str, Any]]) -> dict[str, Any]:
    """单月汇总 + 逐笔记录。

    口径与官方 App「充电记录」页对齐：
      · `count` 是笔数，**含电量缺失的记录**（充了几次和充了多少度是两件事）；
      · `totalKwh` 只累加有值的（NULL 不参与 SUM）；
      · `avgPowerKw` = 总电量 / 总时长 → 平均充电功率，能直观看快慢；
      · 金额只统计**有来源标记**的，`estimated` 单独计数，绝不与真值混算。
    """
    total_kwh = 0.0
    total_minutes = 0.0
    dc_count = dc_kwh = ac_count = ac_kwh = 0
    amount_total = 0.0
    amount_count = 0
    priced_kwh = 0.0          # 已确认金额对应的电量（算单价的分母）
    priced_missing_kwh = 0    # 有金额但电量缺失的笔数（单价算不准的信号）
    unpriced_kwh = 0.0        # 还没补录金额的电量（估算的分母）
    estimated_total = 0.0
    estimated_count = 0
    # 平均功率必须用**同一批**记录：某笔有电量没时长时，
    # 分子加了电量、分母没加时长，功率会凭空虚高。
    power_kwh = 0.0
    power_minutes = 0.0

    records: list[dict[str, Any]] = []
    for row in rows:
        kwh = row.get("energyKwh")
        minutes = row.get("durationMin")
        if isinstance(kwh, (int, float)):
            total_kwh += float(kwh)
        if isinstance(minutes, (int, float)):
            total_minutes += float(minutes)
            if isinstance(kwh, (int, float)):
                power_kwh += float(kwh)
                power_minutes += float(minutes)

        charge_type = row.get("chargeType")
        if charge_type == "dc":
            dc_count += 1
            dc_kwh += float(kwh or 0)
        elif charge_type == "ac":
            ac_count += 1
            ac_kwh += float(kwh or 0)

        amount = row.get("amount")
        source = row.get("amountSource")
        if isinstance(amount, (int, float)) and source:
            # 估算值与真值**分母不同**：混算会让"每度多少钱"变成一个既不是
            # 实际支出、也不是估价的第三个数字。
            if source == "estimate":
                estimated_total += float(amount)
                estimated_count += 1
            else:
                amount_total += float(amount)
                amount_count += 1
                if isinstance(kwh, (int, float)):
                    priced_kwh += float(kwh)
                else:
                    priced_missing_kwh += 1
        elif isinstance(kwh, (int, float)):
            unpriced_kwh += float(kwh)

        records.append(
            {
                **row,
                "chargeTypeName": {"dc": "直流", "ac": "交流"}.get(str(charge_type), "未知"),
                # 单笔单价：只在金额与电量都真实存在时给，缺一个就是 None
                "unitPrice": (
                    round(float(amount) / float(kwh), 2)
                    if isinstance(amount, (int, float))
                    and source != "estimate"
                    and isinstance(kwh, (int, float))
                    and kwh > 0
                    else None
                ),
            }
        )

    return {
        "yearMonth": ym,
        "label": _month_label(ym),
        "count": len(rows),
        "totalKwh": round(total_kwh, 1),
        "dcCount": dc_count,
        "dcKwh": round(dc_kwh, 1),
        "acCount": ac_count,
        "acKwh": round(ac_kwh, 1),
        "totalMinutes": round(total_minutes),
        "avgKwh": round(total_kwh / len(rows), 1) if rows else 0.0,
        "avgMinutes": round(total_minutes / len(rows)) if rows else 0,
        # 平均充电功率（kW）= 电量 / 小时
        "avgPowerKw": (
            round(power_kwh / (power_minutes / 60), 1) if power_minutes > 0 else None
        ),
        # 已确认金额：只含配对成功的真值。`amountTotal / pricedKwh` 才是"每度多少钱"。
        "amountTotal": round(amount_total, 2) if amount_count else None,
        "amountCount": amount_count,
        "pricedKwh": round(priced_kwh, 1),
        # 单价只在「分子分母同一批记录」时可算：只要有金额的笔里缺电量，
        # 分母就少了一块，算出来必然偏高 —— 宁可给 None。
        "unitPrice": (
            round(amount_total / priced_kwh, 2)
            if priced_kwh > 0 and priced_missing_kwh == 0
            else None
        ),
        # 还没补录金额的电量（界面据此提示"还有多少度没算钱"）
        "unpricedCount": len(rows) - amount_count - estimated_count,
        "unpricedKwh": round(unpriced_kwh, 1),
        "estimatedTotal": round(estimated_total, 2) if estimated_count else None,
        "estimatedCount": estimated_count,
        "records": records,
    }


@router.post("/sync")
async def sync_sessions() -> dict:
    """从官方「充电记录」同步充电流水（幂等，重复同步无副作用）。

    这是整个充电页的主线：**用户零操作就能看到"充了多少电"**。
    金额不在这个接口里 —— 它只能来自截图 OCR / 手工录入。
    """
    global _last_sync_at

    now = time.monotonic()
    if now - _last_sync_at < SYNC_MIN_INTERVAL_SEC:
        raise HTTPException(
            status_code=429,
            detail=f"同步过于频繁，请 {SYNC_MIN_INTERVAL_SEC} 秒后再试",
        )
    # 先占位再请求：原来只在**成功后**才写 `_last_sync_at`，
    # 两个请求同时到达时都能通过上面的判断，实测上游会被打两次 ——
    # 冷却是为了防极氪风控，被并发击穿就失去意义了。
    _last_sync_at = now

    from ..main import store

    try:
        sessions = await get_client().get_charge_sessions()
    except Exception as exc:  # noqa: BLE001 - 统一转 HTTP 错误，不回显原始报文
        # 令牌过期要明说「请重新登录」，而不是含糊的"同步失败" ——
        # 否则用户会以为是自己网络问题，反复重试。
        message = str(exc)
        if "079021" in message or "401" in message or "登录" in message:
            raise HTTPException(status_code=401, detail="登录状态已失效，请重新登录后再同步") from exc
        fail("同步充电记录失败，请检查登录状态与服务端日志", exc)

    if is_mock():
        # 模拟数据只是"给界面看形状"，没有任何写入意义 —— 落库反而会污染真实数据
        return {
            "success": True,
            "data": {
                "fetched": len(sessions),
                "inserted": 0,
                "updated": 0,
                "total": len(sessions),
                "persisted": False,
            },
        }

    result = store.save_sessions(sessions)

    logger.info(
        "充电流水同步完成：上游 %d 条，新增 %d，更新 %d",
        len(sessions), result["inserted"], result["updated"],
    )
    return {
        "success": True,
        "data": {
            "fetched": len(sessions),
            "inserted": result["inserted"],
            "updated": result["updated"],
            "total": store.count_sessions(),
            "persisted": True,
        },
    }


@router.get("/sessions")
async def get_sessions(yearMonth: str | None = None) -> dict:
    """按月查询充电流水（默认本月）。

    **只读本地库**，不打网关 —— 页面每次切月份都去打官方接口既慢又容易被风控。
    想刷新数据请显式调 `POST /sync`。
    """
    ym = _resolve_month(yearMonth)
    rows = await _session_rows(year_month=ym)
    data = _summarize_month(ym, rows)

    # 金额补录的进度：这个月还有几笔支付没配对。
    # 只在真实数据源下有意义（模拟模式没有可配对的流水，也不落库）。
    if is_mock():
        data["pendingPayments"] = 0
        data["unmatchedPayments"] = 0
    else:
        from ..main import store

        counts = store.payment_counts(year_month=ym)
        data["pendingPayments"] = counts.get("pending", 0)
        data["unmatchedPayments"] = counts.get("unmatched", 0)

    return {"success": True, "data": data}


@router.get("/months")
async def get_months() -> dict:
    """可查月份清单（含每月电量、时长与已补录金额），供月份选择器与累计金额使用。"""
    rows = await _month_rows()
    current = datetime.now().strftime("%Y-%m")

    months: list[dict[str, Any]] = []
    seen_current = False
    for row in rows:
        item = {
            "yearMonth": row["yearMonth"],
            "label": _month_label(row["yearMonth"]),
            "count": row["count"],
            "kwh": row["kwh"],
            # 每次充电时长。没有流水的月份给 None —— 画成 0 会读成"充得特别快"。
            "avgMinutes": row.get("avgMinutes"),
            # 已补录的真值金额（估算不计入）。前端把所有月份加起来就是「累计金额」。
            "amount": row.get("amount") or 0.0,
            "amountCount": row.get("amountCount") or 0,
            "dcCount": row["dcCount"],
            "acCount": row["acCount"],
        }
        if row["yearMonth"] == current:
            # 当月对外统一叫 `currentMonth`，与行程页保持一致 ——
            # 前端不需要自己判断"哪个月是本月"。
            item["yearMonth"] = "currentMonth"
            item["label"] = "本月"
            seen_current = True
        months.append(item)

    if not seen_current:
        months.insert(
            0,
            {"yearMonth": "currentMonth", "label": "本月", "count": 0, "kwh": 0.0,
             "avgMinutes": None, "amount": 0.0, "amountCount": 0,
             "dcCount": 0, "acCount": 0},
        )

    total_kwh = sum(float(m["kwh"] or 0) for m in months)
    return {
        "success": True,
        "data": {
            "months": months,
            "totalCount": sum(int(m["count"] or 0) for m in months),
            "totalKwh": round(total_kwh, 1),
            # 所有可查月份的金额之和。
            # ⚠️ 不要拿它除 `totalKwh` 求均价：分母含**未补录金额**的电量，
            # 除出来会明显偏低（实测能差 3 倍）。要均价请用 `/sessions` 的 unitPrice。
            "totalAmount": round(sum(float(m["amount"] or 0) for m in months), 2),
            "hasData": bool(rows),
        },
    }


# ── 金额补录 ────────────────────────────────────────────────────────────
#
# 三条路，一条都不能堵死：
#   1. **截图识别**（主线）：`POST /receipts/ocr` → 人工核对 → `POST /receipts/commit`
#   2. **手工录入**（零依赖）：`POST /payments/manual`
#   3. **电价估算**（兜底）：不落库、只展示，开关是 `CHARGE_ESTIMATE_PRICE`
#
# 截图识别**不直接入库**：识别结果先回给前端让用户核对。
# 模型会把服务费原价当金额、会把一笔看成两笔，而"金额读错"比"没有金额"更糟。
#
# 隐私：图片只在这个函数的内存里 → base64 → 上游，不写盘、不进日志；
# 日志只有 sha8 / 字节数 / 耗时。详见 `adapters/vision_ocr.py`。

_ALLOWED_IMAGE_MIME = {"image/jpeg", "image/png", "image/webp", "image/gif"}
_MAX_IMAGE_BYTES = 12 * 1024 * 1024


def _make_payment_id(
    image_sha: str, amount: float, paid_at: str | None, order_tail: str | None
) -> str:
    """幂等键：图 hash + 金额 + 时间（+ 订单尾号）。

    同一张截图重跑 OCR 不会插两遍 —— 这也是 commit 用 `INSERT OR IGNORE` 的前提。

    ⚠️ 时间**必须归一**再进键：同一笔钱模型两次可能写成 `2026/10/16 22:10` 与
    `2026-10-16 22:10`，拿原始字符串做键会算成两笔支付 —— 钱被记两遍，
    而且第二次会把第一次的绑定顶掉，旧的留在「待确认」里永远清不掉。
    """
    stamp = parse_time(paid_at) if paid_at else None
    canonical = stamp.strftime("%Y-%m-%d %H:%M") if stamp else (paid_at or "")
    raw = f"{image_sha}|{amount:.2f}|{canonical}|{order_tail or ''}"
    return sha256(raw.encode()).hexdigest()[:16]


def _row_paid_at(row: dict[str, Any]) -> str | None:
    """支付时间：优先取充电开始时间（能直接和 session 比），没有就退结束时间。"""
    for key in ("startAt", "paidAt", "endAt"):
        value = row.get(key)
        if isinstance(value, str) and value.strip():
            return value.strip()
    return None


def _persist_payments(
    rows: list[dict[str, Any]], image_sha: str, source: str
) -> dict[str, Any]:
    """把识别/手工结果落成 payment，并尝试配对。

    配对失败的**不丢**：零命中落 `unmatched`，多命中落 `pending`。
    这条原则与旧账单去重一致 —— 宁可让用户点一下，也不能把钱吞掉。
    """
    from ..main import store

    # 取全量（两年高频充电可超 1000 条）：截断会让较早的账单稳定落 unmatched，
    # 用户看到"没有时间窗内的充电流水"，而库里其实有。
    sessions = store.list_sessions(limit=5000)
    pairs: list[tuple[dict[str, Any], dict[str, Any]]] = []
    invalid = 0

    for row in rows:
        # 元素不是对象（前端传了 1 / "x"）就跳过而不是 500 ——
        # 这类请求是调用方写错，不该冒出 Internal Server Error
        if not isinstance(row, dict):
            invalid += 1
            continue
        amount = row.get("amount")
        if not isinstance(amount, (int, float)) or float(amount) <= 0:
            # 退款行 / 用户把金额改成 0 / 模型吐 NaN：**不存，但要报数**。
            # 以前静默 continue，接口回 200 且全 0，用户以为成功了。
            invalid += 1
            continue
        paid_at = _row_paid_at(row)
        tail = row.get("orderNoTail4") or row.get("orderTail")
        payment_id = row.get("paymentId") or _make_payment_id(
            image_sha, float(amount), paid_at, tail
        )
        payment = {
            "paymentId": payment_id,
            "source": source,
            "paidAt": paid_at,
            "amount": float(amount),
            "energyKwh": row.get("energyKwh"),
            "stationName": row.get("stationName"),
            "orderTail": tail,
            "confidence": row.get("confidence"),
            "status": "pending",
            "imageSha": image_sha or None,
        }
        pairs.append((payment, row))

    saved = store.save_payments([p for p, _ in pairs])

    linked = pending = unmatched = 0
    for payment, row in pairs:
        # 已经配对成功的跳过：同一张截图重跑（或前端重试）不该把
        # 用户手工绑好的结果冲成 pending/unmatched —— 钱还在，状态却自相矛盾。
        if store.payment_status(payment["paymentId"]) == "matched":
            linked += 1
            continue

        target = row.get("sessionId")
        if isinstance(target, str) and target:
            store.link_payment(target, payment["paymentId"], "manual", "high")
            linked += 1
            continue

        best = choose_match(
            candidate_matches(
                {"paidAt": payment["paidAt"], "energyKwh": payment["energyKwh"]},
                sessions,
            )
        )
        if best is None:
            store.set_payment_status(
                payment["paymentId"], "unmatched", "没有时间窗内的充电流水"
            )
            unmatched += 1
        elif best["confidence"] == "high":
            store.link_payment(
                best["sessionId"], payment["paymentId"], best["kind"], "high"
            )
            linked += 1
        else:
            # 多候选 / 只有弱匹配：默认值先填，但不替用户拍板
            store.set_payment_status(
                payment["paymentId"], "pending", "存在多条候选，需人工确认"
            )
            pending += 1

    return {
        "inserted": saved["inserted"],
        "skipped": saved["skipped"],
        "invalid": invalid,
        "linked": linked,
        "pending": pending,
        "unmatched": unmatched,
    }


@router.get("/receipts/status")
async def receipts_status() -> dict:
    """截图识别是否可用（未配 key 时前端据此把按钮降级成提示）。"""
    return {
        "success": True,
        "data": {
            "configured": bool(config.deepseek_api_key),
            "model": config.vision_model if config.deepseek_api_key else None,
        },
    }


async def _read_and_ocr(file: UploadFile, *, include_raw: bool = False) -> dict[str, Any]:
    """校验并识别一张截图（`/receipts/ocr` 与调试口共用）。

    错误文案直接点名该做什么：没配 key 就说去配哪个变量，
    识别失败就说换张清楚的图 —— 用户能自己解决的事不该让他来翻日志。
    """
    mime = (file.content_type or "").split(";")[0].strip().lower()
    if mime and mime not in _ALLOWED_IMAGE_MIME:
        raise HTTPException(status_code=400, detail="只支持 JPG / PNG / WebP / GIF 截图")

    raw = await file.read()
    if not raw:
        raise HTTPException(status_code=400, detail="上传的图片为空")
    if len(raw) > _MAX_IMAGE_BYTES:
        raise HTTPException(status_code=413, detail="图片过大（上限 12MB）")

    try:
        return await extract_receipts(raw, mime or "image/jpeg", include_raw=include_raw)
    except VisionUnavailable as exc:
        raise HTTPException(
            status_code=503,
            detail="未配置 DEEPSEEK_API_KEY：在 .env 填入并重启服务后即可使用截图识别；"
                   "在此之前可以用「手动录入」补金额。",
        ) from exc
    except VisionFailed as exc:
        # 上游异常（超时/限流/URL）不回显，只留日志。
        logger.warning("截图识别失败：%s", exc)
        raise HTTPException(
            status_code=502, detail="截图识别失败，请确认图片清晰、包含金额，稍后重试"
        ) from exc


@router.post("/receipts/ocr")
async def ocr_receipt(file: UploadFile = File(..., description="充电订单截图")) -> dict:
    """识别一张截图，返回**待确认**的金额行（不入库、不落盘）。

    前端拿到 rows 后要让用户核对/改数，再调 `/receipts/commit`。
    """
    result = await _read_and_ocr(file)

    # 附上候选流水 + 本地防幻觉校验，用户在确认框里就能直接挑
    sessions: list[dict[str, Any]] = []
    if not is_mock():
        from ..main import store

        sessions = store.list_sessions(limit=5000)

    for row in result["rows"]:
        row["candidates"] = candidate_matches(
            {"paidAt": _row_paid_at(row), "energyKwh": row.get("energyKwh")}, sessions
        )
        ok, note = sanity_check(row)
        row["needsReview"] = not ok
        row["reviewNote"] = note

    return {
        "success": True,
        "data": {
            "type": result["type"],
            "imageSha8": result["imageSha8"],
            "rows": result["rows"],
            "configured": True,
        },
    }


@router.post("/receipts/ocr-debug")
async def ocr_receipt_debug(file: UploadFile = File(..., description="充电订单截图")) -> dict:
    """调试接口：把模型**原始输出**原样带回，供 /preview/ocr-test.html 评测识别质量。

    正式链路（`/receipts/ocr`）走白名单过滤，把"模型到底读了什么"也一起裁掉了；
    评测识别质量恰恰要看被裁掉的那部分，所以这里额外带 `raw`（模型原文）
    与 `parsedRows`（未清洗字段）。

    ⚠️ **只许本机调试**：这两样可能含 prompt 没拦住的 VIN / 手机号 / 完整订单号
    —— 不入库、不进日志、不进正式链路；正式入口永远是 `/receipts/ocr`。
    """
    result = await _read_and_ocr(file, include_raw=True)
    return {"success": True, "data": result}


@router.post("/receipts/commit")
async def commit_receipts(payload: dict[str, Any] = Body(...)) -> dict:
    """把用户确认过的识别结果入库（幂等）。"""
    _assert_writable()
    rows = payload.get("rows")
    if not isinstance(rows, list) or not rows:
        raise HTTPException(status_code=400, detail="rows 不能为空")
    image_sha = str(payload.get("imageSha8") or "")
    return {"success": True, "data": _persist_payments(rows, image_sha, "ocr")}


@router.post("/payments/manual")
async def add_manual_payment(payload: dict[str, Any] = Body(...)) -> dict:
    """手工补录一笔（金额 / 电量 / 站点 / 时间，4 个字段就能兜底）。"""
    _assert_writable()
    amount = payload.get("amount")
    if not isinstance(amount, (int, float)) or float(amount) <= 0:
        raise HTTPException(status_code=400, detail="amount 必须是正数")

    paid_at = payload.get("paidAt")
    if not isinstance(paid_at, str) or not parse_time(paid_at):
        raise HTTPException(status_code=400, detail="paidAt 格式应为 YYYY-MM-DD HH:mm")

    row = {
        "paymentId": f"manual:{uuid.uuid4().hex[:12]}",
        "amount": float(amount),
        "energyKwh": payload.get("energyKwh"),
        "stationName": payload.get("stationName"),
        "startAt": paid_at,
        "sessionId": payload.get("sessionId"),
        "confidence": 1.0,
    }
    return {"success": True, "data": _persist_payments([row], "", "manual")}


@router.get("/payments")
async def list_payments(status: str | None = None) -> dict:
    """金额证据列表（默认全部）。未配对的会附上候选，前端可直接点绑定。"""
    if status not in (None, "pending", "unmatched", "matched"):
        raise HTTPException(status_code=400, detail="status 只能为 pending / unmatched / matched")

    if is_mock():
        return {"success": True, "data": {"payments": [], "counts": {}}}

    from ..main import store

    payments = store.list_payments(status=status)
    sessions = store.list_sessions(limit=5000)
    for item in payments:
        if item["status"] != "matched":
            item["candidates"] = candidate_matches(
                {"paidAt": item["paidAt"], "energyKwh": item["energyKwh"]}, sessions
            )
    return {
        "success": True,
        "data": {"payments": payments, "counts": store.payment_counts()},
    }


@router.post("/payments/{payment_id}/link")
async def link_payment(payment_id: str, payload: dict[str, Any] = Body(...)) -> dict:
    """手工指定某笔支付属于哪次充电。"""
    _assert_writable()
    session_id = payload.get("sessionId")
    if not isinstance(session_id, str) or not session_id:
        raise HTTPException(status_code=400, detail="sessionId 不能为空")

    from ..main import store

    try:
        store.link_payment(session_id, payment_id, "manual", "high")
    except KeyError as exc:
        raise HTTPException(status_code=404, detail="支付记录或充电流水不存在") from exc
    return {"success": True, "data": {"sessionId": session_id, "paymentId": payment_id}}


@router.delete("/payments/{payment_id}/link")
async def unlink_payment(payment_id: str) -> dict:
    """解绑：金额退回待确认，session 的金额清空（不删任何证据）。"""
    _assert_writable()

    from ..main import store

    session_id = store.session_for_payment(payment_id)
    if session_id is None:
        raise HTTPException(status_code=404, detail="这笔支付当前没有绑定充电记录")
    store.unlink_session(session_id)
    return {"success": True, "data": {"sessionId": session_id}}


def _assert_writable() -> None:
    """模拟数据源下不允许写金额。

    模拟模式没有真实充电流水可配对，写进去只会让"待确认"列表变成一堆
    谁也绑不上的孤儿 —— 和当年把 60 条假行程写进真库是同一类问题。
    """
    if is_mock():
        raise HTTPException(
            status_code=503,
            detail="当前是模拟数据模式，没有真实充电流水可配对。切到真实数据源后再试。",
        )


@router.get("/summary")
async def get_summary(months: int = 6) -> dict:
    """获取充电消费汇总。"""
    if not 1 <= months <= 60:
        raise HTTPException(status_code=400, detail="months 取值范围为 1–60")

    from ..main import store

    charges = store.list_charges(limit=100000)
    summary = build_summary(charges, months=months)

    # 补上服务商显示名，前端不用再维护映射
    for item in summary.get("byProvider") or []:
        item["providerName"] = provider_display_name(item.get("provider"))

    return {"success": True, "data": summary}


@router.get("/records")
async def get_records(limit: int = 50, months: int | None = None) -> dict:
    """获取充电消费明细。"""
    if not 1 <= limit <= 2000:
        raise HTTPException(status_code=400, detail="limit 取值范围为 1–2000")

    from ..main import store

    charges = store.list_charges(limit=limit, months=months)
    for charge in charges:
        charge["providerName"] = provider_display_name(charge.get("provider"))

    return {"success": True, "data": charges}


@router.post("/import")
async def import_charges(
    file: UploadFile = File(..., description="支付宝/微信导出的账单 CSV"),
    source: str = Form("auto", description="alipay / wechat / auto"),
) -> dict:
    """导入账单文件，归集充电消费。"""
    if source not in ("auto", "alipay", "wechat"):
        raise HTTPException(status_code=400, detail="source 只能为 auto / alipay / wechat")

    # 扩展名白名单 —— 避免无意义的大文件解析开销
    filename = (file.filename or "").lower()
    if filename and not filename.endswith((".csv", ".txt")):
        raise HTTPException(
            status_code=400,
            detail="仅支持 CSV / TXT 格式的账单文件（支付宝与微信均可导出 CSV）",
        )

    raw = await file.read()
    if not raw:
        raise HTTPException(status_code=400, detail="上传的文件为空")

    # 大小保护：账单文件通常几百 KB
    if len(raw) > 20 * 1024 * 1024:
        raise HTTPException(status_code=413, detail="文件过大（上限 20MB）")

    from ..main import store

    try:
        result = import_bill(raw, source=source, store=store)
    except Exception as exc:  # noqa: BLE001
        # 不回显原始异常：解析链路可能带出文件内容片段
        fail("账单导入失败，请检查文件格式与服务端日志", exc)

    return {
        "success": result["success"],
        "data": result,
        "error": None if result["success"] else result.get("message"),
    }


@router.delete("/records")
async def clear_records() -> dict:
    """清空所有充电消费记录。"""
    from ..main import store

    count = store.clear_charges()
    return {"success": True, "data": {"cleared": count}}
