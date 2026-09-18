"""充电消费接口。"""

from __future__ import annotations

import logging

from fastapi import APIRouter, File, Form, HTTPException, UploadFile

from ..bills.aggregator import build_summary, import_bill
from ..bills.providers import provider_display_name
from . import fail

logger = logging.getLogger(__name__)

router = APIRouter()


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
