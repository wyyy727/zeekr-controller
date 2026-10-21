"""金额与充电流水的配对。

OCR / 手工录入产出的是"一笔支付"，落到哪一次充电上要靠**电量 + 时间窗**判断
（官方订单与充电流水能这样对齐：80.146 度 ↔ power 80.1、起止时间逐秒吻合，
所以不需要订单号）。

规则（来自 REPORT-charge-bill-import.md §2 第 1 层，别自己改口径）：

    强匹配 = |session.power - energyKwh| / session.power <= 0.05
             且 |session.start - T1| <= 10 分钟
    弱匹配 = session.start - 30min <= T1 <= session.end + 30min

    唯一命中 → 自动绑定（high）
    多命中   → 取时间最接近的，标 low，进「待确认」
    零命中   → 进「未配对」（可能是停车费/服务费/占位费，或别人付的）

**未配对 / 低置信度一律不静默丢** —— 宁可让用户点一下，也不能把钱吞掉。
"""

from __future__ import annotations

from datetime import datetime, timedelta
from typing import Any

# 电量相对误差上限（强匹配）
ENERGY_TOLERANCE = 0.05
# 强匹配的时间窗（分钟）
STRONG_WINDOW_MIN = 10
# 弱匹配的时间窗（分钟）：起点前 / 终点后各放宽这么多
WEAK_WINDOW_MIN = 30

_TIME_FORMATS = (
    "%Y-%m-%d %H:%M:%S",
    "%Y-%m-%d %H:%M",
    "%Y/%m/%d %H:%M:%S",
    "%Y/%m/%d %H:%M",
    "%Y-%m-%dT%H:%M:%S",
    "%Y-%m-%dT%H:%M",
    "%Y.%m.%d %H:%M",
)


def parse_time(value: Any) -> datetime | None:
    """把各种写法的本地时间解析成 `datetime`。解析不出来就返回 None。

    上游/OCR 会给 `2026-10-16 22:10`、`2026/10/16 22:10`、`2026-10-16T22:10`
    这些变体，统一都试一遍；**不做时区换算**（都是本地时间）。
    """
    if isinstance(value, datetime):
        return value
    if not isinstance(value, str):
        return None

    raw = value.strip()
    variants = [raw]
    if "/" in raw:
        variants.append(raw.replace("/", "-"))
    elif "-" in raw:
        variants.append(raw.replace("-", "/"))

    for text in variants:
        for fmt in _TIME_FORMATS:
            try:
                return datetime.strptime(text, fmt)
            except ValueError:
                continue
    try:
        return datetime.fromisoformat(raw)
    except ValueError:
        return None


def _session_start(session: dict[str, Any]) -> datetime | None:
    return parse_time(session.get("startTime"))


def _session_end(session: dict[str, Any]) -> datetime | None:
    end = parse_time(session.get("endTime"))
    if end is not None:
        return end
    start = _session_start(session)
    minutes = session.get("durationMin")
    if start is not None and isinstance(minutes, (int, float)):
        return start + timedelta(minutes=float(minutes))
    return start


def _energy_close(session_kwh: Any, payment_kwh: Any) -> bool:
    if not isinstance(session_kwh, (int, float)) or session_kwh <= 0:
        return False
    if not isinstance(payment_kwh, (int, float)) or payment_kwh <= 0:
        return False
    return abs(float(session_kwh) - float(payment_kwh)) / float(session_kwh) <= ENERGY_TOLERANCE


def candidate_matches(
    payment: dict[str, Any],
    sessions: list[dict[str, Any]],
    limit: int = 5,
) -> list[dict[str, Any]]:
    """给一笔支付找出候选充电流水（按可信度排序）。

    Args:
        payment: 至少含 `paidAt`（或 `startAt`）、可选 `energyKwh`。
        sessions: 本地充电流水（`startTime`/`endTime`/`energyKwh`）。

    Returns:
        [{"sessionId", "startTime", "energyKwh", "kind": strong|weak,
          "confidence": high|low, "deltaMin": 整数}]
    """
    paid_at = parse_time(payment.get("paidAt") or payment.get("startAt"))
    if paid_at is None:
        return []

    payment_kwh = payment.get("energyKwh")
    found: list[dict[str, Any]] = []

    for session in sessions:
        start = _session_start(session)
        if start is None:
            continue
        end = _session_end(session) or start
        delta_min = abs((start - paid_at).total_seconds()) / 60

        strong = (
            _energy_close(session.get("energyKwh"), payment_kwh)
            and delta_min <= STRONG_WINDOW_MIN
        )
        weak = (
            start - timedelta(minutes=WEAK_WINDOW_MIN)
            <= paid_at
            <= end + timedelta(minutes=WEAK_WINDOW_MIN)
        )
        if not (strong or weak):
            continue

        found.append(
            {
                "sessionId": session.get("sessionId"),
                "startTime": session.get("startTime"),
                "endTime": session.get("endTime"),
                "energyKwh": session.get("energyKwh"),
                "kind": "strong" if strong else "weak",
                # 单条候选时最终置信度由 choose 决定；这里先按匹配种类给一个默认值
                "confidence": "high" if strong else "low",
                "deltaMin": round(delta_min),
            }
        )

    # 强匹配优先，其次时间差小的
    found.sort(key=lambda item: (item["kind"] != "strong", item["deltaMin"]))
    return found[:limit]


def choose_match(candidates: list[dict[str, Any]]) -> dict[str, Any] | None:
    """从候选里挑一个。

    唯一命中才是 high；多命中一律降为 low（"取时间最接近的"只是默认值，
    是不是同一笔得人来确认 —— 同一天充两次、金额相同是很常见的情况）。
    """
    if not candidates:
        return None
    best = dict(candidates[0])
    if len(candidates) > 1:
        best["confidence"] = "low"
    elif best["kind"] != "strong":
        # 只有一条弱匹配也算低置信：时间挨着不代表是同一笔
        best["confidence"] = "low"
    return best


def unit_price(amount: Any, energy_kwh: Any) -> float | None:
    """每度单价。缺电量就返回 None —— 绝不拿 0 去顶，那会算出"免费充电"。"""
    if not isinstance(amount, (int, float)) or not isinstance(energy_kwh, (int, float)):
        return None
    if energy_kwh <= 0:
        return None
    return round(float(amount) / float(energy_kwh), 2)


def sanity_check(payment: dict[str, Any]) -> tuple[bool, str]:
    """防幻觉校验（金额读错比没有更糟）。

    这里只做本地能判断的两条：金额为正、单价落在合理区间。
    与充电流水的交叉校验由调用方在识别后做（需要先拿到 sessions）。
    """
    amount = payment.get("amount")
    if not isinstance(amount, (int, float)) or amount <= 0:
        return False, "金额无效"
    kwh = payment.get("energyKwh")
    if isinstance(kwh, (int, float)) and kwh > 0:
        price = float(amount) / float(kwh)
        if not (0.2 <= price <= 5.0):
            return False, f"单价异常（{price:.2f} 元/度）"
    confidence = payment.get("confidence")
    if isinstance(confidence, (int, float)) and confidence < 0.7:
        return False, "模型置信度偏低"
    return True, ""
