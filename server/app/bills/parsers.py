"""支付宝 / 微信账单解析器。

两个平台的导出格式差异很大，且官方会不定期调整字段。
这里做了**宽容解析**：自动识别编码、自动定位表头行、按列名模糊匹配。

## 支付宝账单特点
- CSV 编码通常是 **GBK**
- 前若干行是说明，表头行以「交易时间」开头
- 金额列可能带正负号，支出为负
- 有「交易对方」「商品说明」「收/支」等列

## 微信账单特点
- CSV 编码通常是 **UTF-8**
- 表头行以「交易时间」开头，前有 16 行左右说明
- 金额列形如 `¥123.45`，需去掉货币符号
- 有「交易对方」「商品」「收/支」等列
"""

from __future__ import annotations

import csv
import io
import re
from datetime import datetime
from typing import Any

# 候选编码，按尝试顺序
CANDIDATE_ENCODINGS = ("utf-8-sig", "utf-8", "gbk", "gb18030", "utf-16")

# 列名别名表：统一字段 → 可能的原始列名
COLUMN_ALIASES: dict[str, list[str]] = {
    "timestamp": ["交易时间", "交易创建时间", "支付时间", "时间", "交易日期"],
    "amount": ["金额", "金额(元)", "交易金额", "金额（元）", "发生金额"],
    "direction": ["收/支", "收支", "收/支类型", "资金流向"],
    "merchant": ["交易对方", "对方", "商户名称", "交易对象", "收/付款方"],
    "description": ["商品说明", "商品", "交易说明", "备注", "商品名称", "交易类型"],
    "status": ["交易状态", "当前状态", "状态"],
    "orderNo": ["交易单号", "交易号", "商户订单号", "订单号", "流水号"],
    "channel": ["支付方式", "付款方式", "支付渠道"],
}


def _decode(raw: bytes) -> str:
    """自动探测编码并解码。"""
    for encoding in CANDIDATE_ENCODINGS:
        try:
            text = raw.decode(encoding)
            # 解码后出现大量替换字符说明编码不对
            if text.count("\ufffd") < len(text) * 0.01:
                return text
        except (UnicodeDecodeError, LookupError):
            continue
    # 兜底：忽略错误
    return raw.decode("utf-8", errors="ignore")


def _locate_header(rows: list[list[str]]) -> int | None:
    """定位表头行。

    支付宝 / 微信的账单文件前面都有说明文字，
    表头行的特征是**同时包含「交易时间」和时间/金额类列名**。
    """
    for index, row in enumerate(rows[:40]):
        joined = " ".join(cell.strip() for cell in row)
        if "交易时间" in joined and ("金额" in joined or "收/支" in joined or "收支" in joined):
            return index
    # 退而求其次：找任意含「交易时间」的行
    for index, row in enumerate(rows[:40]):
        if any("交易时间" in cell for cell in row):
            return index
    return None


def _map_columns(header: list[str]) -> dict[str, int]:
    """把表头映射为统一字段 → 列索引。"""
    mapping: dict[str, int] = {}
    cleaned = [cell.strip().lstrip("\ufeff") for cell in header]

    for field, aliases in COLUMN_ALIASES.items():
        for alias in aliases:
            for index, cell in enumerate(cleaned):
                if cell == alias:
                    mapping[field] = index
                    break
            if field in mapping:
                break

        # 精确匹配失败则退化为包含匹配
        if field not in mapping:
            for alias in aliases:
                for index, cell in enumerate(cleaned):
                    if alias in cell and cell:
                        mapping[field] = index
                        break
                if field in mapping:
                    break

    return mapping


def _parse_amount(text: str) -> float | None:
    """解析金额，去除货币符号与千分位。"""
    if not text:
        return None
    cleaned = re.sub(r"[¥￥,\s元]", "", str(text).strip())
    # 处理括号负数：(123.45)
    negative = cleaned.startswith("(") and cleaned.endswith(")")
    cleaned = cleaned.strip("()")
    try:
        value = float(cleaned)
    except ValueError:
        return None
    return -value if negative else value


def _parse_datetime(text: str) -> datetime | None:
    """解析交易时间。"""
    if not text:
        return None
    text = str(text).strip()
    formats = (
        "%Y-%m-%d %H:%M:%S",
        "%Y-%m-%d %H:%M",
        "%Y/%m/%d %H:%M:%S",
        "%Y/%m/%d %H:%M",
        "%Y-%m-%d",
        "%Y/%m/%d",
        "%Y年%m月%d日 %H:%M:%S",
        "%Y年%m月%d日",
    )
    for fmt in formats:
        try:
            return datetime.strptime(text, fmt)
        except ValueError:
            continue
    return None


def _detect_channel(text: str, source: str) -> str:
    """识别支付渠道。"""
    text = (text or "").lower()
    if "支付宝" in text or source == "alipay":
        return "alipay"
    if "微信" in text or "零钱" in text or source == "wechat":
        return "wechat"
    if "极氪" in text or "zeekr" in text:
        return "zeekr"
    return "other"


def parse_bill(raw: bytes, source: str = "auto") -> dict[str, Any]:
    """解析账单文件。

    Args:
        raw: 文件原始字节
        source: "alipay" / "wechat" / "auto"

    Returns:
        {
            "success": bool,
            "message": str,
            "records": [...],   # 原始解析结果（未过滤充电消费）
            "total": int,
        }
    """
    text = _decode(raw)
    if not text.strip():
        return {"success": False, "message": "文件内容为空", "records": [], "total": 0}

    reader = csv.reader(io.StringIO(text))
    rows = [row for row in reader]

    header_index = _locate_header(rows)
    if header_index is None:
        return {
            "success": False,
            "message": "未找到表头行，请确认是支付宝/微信导出的账单 CSV",
            "records": [],
            "total": 0,
        }

    header = rows[header_index]
    mapping = _map_columns(header)

    if "timestamp" not in mapping or "amount" not in mapping:
        missing = []
        if "timestamp" not in mapping:
            missing.append("交易时间")
        if "amount" not in mapping:
            missing.append("金额")
        return {
            "success": False,
            "message": f"账单缺少必要列：{'、'.join(missing)}",
            "records": [],
            "total": 0,
        }

    def cell(row: list[str], field: str) -> str:
        index = mapping.get(field)
        if index is None or index >= len(row):
            return ""
        return row[index].strip()

    records: list[dict[str, Any]] = []
    for row in rows[header_index + 1:]:
        if not row or not any(cell.strip() for cell in row):
            continue

        # 跳过表尾的统计行（如「共 123 笔记录」）
        joined = " ".join(row)
        if "共" in joined and "笔" in joined:
            continue

        timestamp = _parse_datetime(cell(row, "timestamp"))
        amount = _parse_amount(cell(row, "amount"))
        if timestamp is None or amount is None:
            continue

        direction = cell(row, "direction")
        # 只保留支出；微信的「/」表示不计收支，需剔除
        if direction and direction not in ("支出", "支"):
            if "收" in direction and "支" not in direction:
                continue
            if direction in ("/", "不计收支", ""):
                continue

        # 支出取绝对值
        amount = abs(amount)

        records.append({
            "timestamp": timestamp.strftime("%Y-%m-%d %H:%M:%S"),
            "amount": round(amount, 2),
            "merchant": cell(row, "merchant"),
            "description": cell(row, "description"),
            "orderNo": cell(row, "orderNo"),
            "status": cell(row, "status"),
            "channel": _detect_channel(cell(row, "channel"), source),
        })

    return {
        "success": True,
        "message": f"解析成功，共 {len(records)} 笔支出记录",
        "records": records,
        "total": len(records),
    }


def parse_bill_file(path: str, source: str = "auto") -> dict[str, Any]:
    """从文件路径解析账单。"""
    try:
        with open(path, "rb") as handle:
            return parse_bill(handle.read(), source)
    except OSError as exc:
        return {"success": False, "message": f"读取文件失败：{exc}", "records": [], "total": 0}
