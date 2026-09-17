"""充电消费归集服务。

职责：
1. 从账单原始记录中**筛出充电消费**
2. **跨平台去重**（同一笔消费可能同时出现在支付宝和微信）
3. 按服务商 / 月份维度**聚合统计**

去重策略：以「时间（分钟级）+ 金额」作为指纹。
同一笔充电不太可能在同一分钟、同一金额发生两次。
"""

from __future__ import annotations

import uuid
from collections import defaultdict
from datetime import datetime
from typing import Any

from .parsers import parse_bill
from .providers import detect_provider, provider_display_name


def _dedup_key(record: dict[str, Any]) -> str:
    """生成去重指纹。

    时间精确到分钟 —— 容忍不同平台记录的秒级差异，
    同时保证同一笔消费的指纹一致。
    """
    timestamp = str(record.get("timestamp") or "")
    # 截断到分钟
    minute = timestamp[:16] if len(timestamp) >= 16 else timestamp
    amount = record.get("amount")
    return f"{minute}|{round(float(amount or 0), 2)}"


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


def build_summary(charges: list[dict[str, Any]], months: int = 6) -> dict[str, Any]:
    """构建充电消费汇总。

    Args:
        charges: 充电消费记录
        months: 按月汇总时保留的月数

    Returns:
        ChargeSummary 契约结构
    """
    if not charges:
        return {
            "totalAmount": 0.0,
            "totalEnergyKwh": 0.0,
            "totalCount": 0,
            "avgUnitPrice": None,
            "monthly": [],
            "byProvider": [],
        }

    total_amount = sum(float(c.get("amount") or 0) for c in charges)
    # 只有部分记录有电量，按有值部分统计
    energies = [float(c["energyKwh"]) for c in charges if c.get("energyKwh")]
    total_energy = sum(energies) if energies else None

    # 按月聚合
    monthly_map: dict[str, dict[str, Any]] = defaultdict(
        lambda: {"amount": 0.0, "energyKwh": 0.0, "count": 0, "energyCount": 0}
    )
    # 按服务商聚合
    provider_map: dict[str, dict[str, Any]] = defaultdict(
        lambda: {"amount": 0.0, "energyKwh": 0.0, "count": 0, "energyCount": 0}
    )

    for charge in charges:
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
        "totalCount": len(charges),
        "avgUnitPrice": round(total_amount / total_energy, 2) if total_energy else None,
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
