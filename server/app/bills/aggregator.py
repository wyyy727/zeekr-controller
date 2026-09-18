"""充电消费归集服务。

职责：
1. 从账单原始记录中**筛出充电消费**
2. **跨平台去重**（同一笔消费可能同时出现在支付宝和微信）
3. 按服务商 / 月份维度**聚合统计**

去重策略（订单号优先，无订单号时退化为时间指纹）：

- **有订单号** → 指纹为 `no:<交易单号>`。同平台重复导入被精确识别，
  且不会误伤「同分钟同额的两笔真实消费」。
- **无订单号** → 指纹为 `ts:<分钟>|<金额>`。此时无更强依据，只能按
  「同分钟同额即同一笔」处理，以保住跨平台去重能力。

两种指纹**互斥使用**而非叠加：时间指纹是弱证据，若与订单号并存会让
「同分钟同额的两笔不同订单」被时间指纹抢先判重 —— 这正是要修的 bug。

已知权衡：同一笔消费在支付宝与微信**各带一个不同的交易单号**时，
会被记为两笔（重复）。这是有意为之 —— 多记一笔在对账时能被发现，
少记一笔（静默吞掉）用户永远察觉不到。安全侧偏向「宁可重复」。

历史缺陷：早期实现只有「分钟 + 金额」且完全忽略 `orderNo`，导致同一
分钟内在不同充电站的两笔同额消费被静默丢弃。
"""

from __future__ import annotations

import uuid
from collections import defaultdict
from datetime import datetime
from typing import Any

from .parsers import parse_bill
from .providers import detect_provider, provider_display_name


def _dedup_key(record: dict[str, Any]) -> str:
    """生成去重指纹（订单号优先，无订单号时退化为时间指纹）。

    返回形如：
      `no:<订单号>`        —— 订单号指纹
      `ts:<分钟>|<金额>`    —— 时间指纹（无订单号时的兜底）

    时间指纹**不含渠道**：跨平台去重的核心场景是同一笔消费在支付宝和
    微信各出现一次（渠道不同），带渠道会让它去重失败。
    """
    order_no = str(record.get("orderNo") or "").strip()
    if order_no:
        return f"no:{order_no.upper()}"

    timestamp = str(record.get("timestamp") or "")
    # 截断到分钟 —— 容忍不同平台记录的秒级差异
    minute = timestamp[:16] if len(timestamp) >= 16 else timestamp
    amount = record.get("amount")
    return f"ts:{minute}|{round(float(amount or 0), 2)}"


def extract_charges(records: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """从账单记录中提取充电消费，并去重。

    Args:
        records: 解析出的原始支出记录

    Returns:
        充电消费记录列表（已去重，按时间倒序）
    """
    charges: list[dict[str, Any]] = []
    seen: set[str] = set()
    duplicate_count = 0

    for record in records:
        merchant = record.get("merchant") or ""
        description = record.get("description") or ""

        provider = detect_provider(merchant, description)
        if provider is None:
            continue

        key = _dedup_key(record)
        if key in seen:
            duplicate_count += 1
            continue
        seen.add(key)

        charges.append({
            "recordId": str(uuid.uuid4())[:12],
            "timestamp": record.get("timestamp"),
            "amount": round(float(record.get("amount") or 0), 2),
            "energyKwh": None,          # 账单里通常没有充电量，需服务商订单补充
            "provider": provider,
            "channel": record.get("channel") or "other",
            "merchant": merchant,
            "stationName": description or None,
            "unitPrice": None,
            "orderNo": record.get("orderNo"),
        })

    charges.sort(key=lambda x: str(x.get("timestamp") or ""), reverse=True)
    return charges


def _filter_by_months(
    charges: list[dict[str, Any]], months: int
) -> list[dict[str, Any]]:
    """截取「最近 N 个月」的记录（含当月，当月算第 1 个月）。"""
    if months <= 0:
        return list(charges)

    today = datetime.now()
    year, month = today.year, today.month - (months - 1)
    while month <= 0:
        month += 12
        year -= 1
    start = f"{year:04d}-{month:02d}"

    return [c for c in charges if str(c.get("timestamp") or "")[:7] >= start]


def build_summary(charges: list[dict[str, Any]], months: int = 6) -> dict[str, Any]:
    """构建充电消费汇总。

    **口径一次说清**：所有统计一律限定在最近 `months` 个月内 —— 总额、笔数、
    总电量、平均单价、月度列表、服务商分布，全部同一范围。

    此前总额与笔数统计的是**全量历史**，而月度列表被 `[:months]` 截成最近
    N 个月，两者口径不一致。前端把「累计充电消费」和「近 6 个月月度图」并排
    展示时，会让人以为两个数字是同一范围。返回值里的 `windowMonths` 供前端
    明确标注范围。

    Args:
        charges: 充电消费记录（全量，本函数内部按窗口截取）
        months: 统计窗口的月数

    Returns:
        ChargeSummary 契约结构
    """
    window = _filter_by_months(charges, months)

    if not window:
        return {
            "totalAmount": 0.0,
            "totalEnergyKwh": None,
            "totalCount": 0,
            "avgUnitPrice": None,
            "windowMonths": months,
            "monthly": [],
            "byProvider": [],
        }

    total_amount = sum(float(c.get("amount") or 0) for c in window)
    # 只有部分记录有电量（账单里通常没有），按有值的部分统计
    energies = [float(c["energyKwh"]) for c in window if c.get("energyKwh")]
    total_energy = sum(energies) if energies else None

    # 按月聚合
    monthly_map: dict[str, dict[str, Any]] = defaultdict(
        lambda: {"amount": 0.0, "energyKwh": 0.0, "count": 0, "energyCount": 0}
    )
    # 按服务商聚合
    provider_map: dict[str, dict[str, Any]] = defaultdict(
        lambda: {"amount": 0.0, "energyKwh": 0.0, "count": 0, "energyCount": 0}
    )

    for charge in window:
        amount = float(charge.get("amount") or 0)
        energy = charge.get("energyKwh")
        month = str(charge.get("timestamp") or "")[:7]

        bucket = monthly_map[month]
        bucket["amount"] += amount
        bucket["count"] += 1

        provider_key = charge.get("provider") or "other"
        pbucket = provider_map[provider_key]
        pbucket["amount"] += amount
        pbucket["count"] += 1

        if energy:
            bucket["energyKwh"] += float(energy)
            bucket["energyCount"] += 1
            pbucket["energyKwh"] += float(energy)
            pbucket["energyCount"] += 1

    monthly = [
        {
            "month": month,
            "amount": round(data["amount"], 2),
            "energyKwh": round(data["energyKwh"], 2) if data["energyCount"] else None,
            "count": data["count"],
        }
        for month, data in sorted(monthly_map.items(), reverse=True)
    ][:months]

    by_provider = [
        {
            "provider": provider,
            "amount": round(data["amount"], 2),
            "energyKwh": round(data["energyKwh"], 2) if data["energyCount"] else None,
            "count": data["count"],
        }
        for provider, data in sorted(
            provider_map.items(), key=lambda item: item[1]["amount"], reverse=True
        )
    ]

    return {
        "totalAmount": round(total_amount, 2),
        "totalEnergyKwh": round(total_energy, 2) if total_energy else None,
        "totalCount": len(window),
        "avgUnitPrice": round(total_amount / total_energy, 2) if total_energy else None,
        # 明确告诉前端统计范围，便于把"累计消费"标注成"近 N 个月消费"
        "windowMonths": months,
        "monthly": monthly,
        "byProvider": by_provider,
    }


def import_bill(raw: bytes, source: str = "auto", store: Any = None) -> dict[str, Any]:
    """导入账单并归集充电消费。

    Args:
        raw: 文件字节
        source: alipay / wechat / auto
        store: 可选的存储实例，用于持久化

    Returns:
        导入结果摘要
    """
    parsed = parse_bill(raw, source)
    if not parsed["success"]:
        return {
            "success": False,
            "message": parsed["message"],
            "imported": 0,
            "duplicates": 0,
        }

    charges = extract_charges(parsed["records"])

    if store is not None:
        existing = {_dedup_key(c) for c in store.list_charges(limit=100000)}
        fresh = [c for c in charges if _dedup_key(c) not in existing]
        store.save_charges(fresh)
        duplicates = len(charges) - len(fresh)
    else:
        fresh = charges
        duplicates = 0

    return {
        "success": True,
        "message": f"已归集 {len(fresh)} 笔充电消费",
        "imported": len(fresh),
        "duplicates": duplicates,
        "totalParsed": parsed["total"],
    }


def provider_name(provider: str | None) -> str:
    """服务商显示名（供接口层使用）。"""
    return provider_display_name(provider)
