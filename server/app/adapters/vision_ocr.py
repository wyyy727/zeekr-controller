"""充电账单截图识别（DeepSeek Vision）。

**为什么需要它**：极氪的充电记录接口只有电量，没有金额；车端报文里也没有任何
`fee/cost/amount/price` 叶子字段（车不知道电价）。官方 App 的「补能订单」金额页
数据在第三方服务商（浩汉）的网关后面，要浩汉自己的账号态，极氪 token 不通用
⇒ **不可自动化**。所以金额只剩三条路：截图识别（主线）/ 手工录入 / 电价估算。

**红线（改这段前先读）**
  1. 图片**不落盘**：只在内存里 → base64 → 上游，不写临时文件、不进对象存储；
  2. 不回传敏感字段：prompt 里明确禁止输出 VIN / 车牌 / 手机号 / 完整订单号，
     回传后还要再按正则过滤一遍（模型不听话是常态，不能只靠 prompt）；
  3. 日志只记 `sha256[:8]`、字节数、耗时、字段数 —— 不记图片、不记上游原文。

截图本身已核实不含 VIN（极氪充电订单列表、第三方账单与凭证都不含），
所以不做框选/涂黑，一次上传零操作。
"""

from __future__ import annotations

import asyncio
import base64
import json
import logging
import re
import time
from hashlib import sha256
from typing import Any

import httpx

from ..core.config import config

logger = logging.getLogger(__name__)


class VisionUnavailable(RuntimeError):
    """未配置或上游不可用。调用方应转成 503，并把"去配 key"的指引带出去。"""


class VisionFailed(RuntimeError):
    """识别本身失败（超时、格式错、模型拒绝）。"""


# 只允许这些键回传 —— 白名单之外的字段一律丢弃，
# 这样即使模型"顺手"输出了 VIN、手机号或完整订单号，也进不了我们这一层。
ALLOWED_KEYS = (
    "amount", "currency", "energyKwh", "startAt", "endAt", "durationMin",
    "stationName", "payStatus", "starter", "stopReason",
    "orderNoTail4", "serviceFeeAmount", "serviceFeeOriginal", "totalAmount",
    "confidence", "evidenceText",
)

# 单张截图最多接受的条数。补能订单列表一屏 7 条，给到 30 已经够宽松；
# 再大只会放大幻觉面积。
MAX_ROWS = 30

# 从带单位的字符串里抠数字（"80.146度" → 80.146）
_NUMBER_RE = re.compile(r"-?\d+(?:\.\d+)?")

# 抓 VIN / 长串凭据（订单号、流水号）。
# 真实 VIN 不含 I/O/Q 且正好 17 位，但这里按「15 位以上大写字母或数字连串」来删：
# 一是精确 17 位 + `\b` 匹配不上被前后字符粘住的情况，二是带 O 的假 VIN 也会漏。
# 展示文本里出现这么长的连续大写数字串，几乎只可能是标识符 —— 删掉没有副作用。
_VIN_RE = re.compile(r"\b[A-Z0-9]{15,}\b")
_PHONE_RE = re.compile(r"\b1[3-9]\d{9}\b")
_LONG_DIGITS_RE = re.compile(r"\b\d{12,}\b")
# 站点名里的门牌/楼层/房号：只留"站点叫什么"，不留"在几层几号"
_ADDRESS_TAIL_RE = re.compile(r"\s*\d+\s*[号栋层室].*$")
# 「充电时长 00:18:25」这类时分秒（理想超充的版式）。
# ⚠️ 不能交给 _as_float：它会从 "00:18:25" 里抠出 "00" 当分钟 —— 时长凭空变 0，
# 平均功率（电量÷时长）跟着变 inf/None，配对的弱窗口也塌了。
#
# 不要用 ^...$ 锚定：模型常把标签一起抄回来（"充电时长 00:18:25"），
# 一旦带前缀就匹配不上，又退化成 _as_float 抠出 "00"。用"前后不接数字/冒号"的
# 边界断言，既能在句子里找，也不会从 "2026-10-16 22:10" 里误取。
_CLOCK_RE = re.compile(r"(?<![\d:])(\d{1,3}):(\d{2})(?::(\d{2}))?(?![\d:])")
# 日期（"2026-10-16" / "2026/10/16"）：出现在时长字段里说明模型抄错了字段
_DATE_LIKE_RE = re.compile(r"\d{4}[-/]\d{1,2}[-/]\d{1,2}")
# 中文单位：1小时30分 / 18分25秒 / 37分钟（各段都可缺，全缺就不算命中）
_CN_DURATION_RE = re.compile(
    r"(?:(\d+)\s*(?:小时|时|h))?\s*(?:(\d+)\s*分(?:钟)?)?\s*(?:(\d+)\s*秒)?",
    re.I,
)

PROMPT = """你是充电账单字段抽取器。只做抽取，不做推测、不做补全、不做单位换算。
图中若出现车架号(VIN)、车牌、手机号、完整订单号、地址门牌、账户余额，一律忽略，不要输出、不要复述。

先判断截图类型：
- 一屏多行、每行是「站点名 + 状态(已支付/待支付) + 起止时间 + 金额」→ type="list_row"
- 单笔订单详情（有「费用明细」「订单信息」分块）→ type="order_detail"
- 其他（支付凭证、桩端屏幕）→ type="receipt"

只返回如下 JSON（rows 按截图行序，不合并、不补行；字段缺失填 null）：
{
  "type": "list_row" 或 "order_detail" 或 "receipt",
  "rows": [
    {
      "amount": 数字或null,
      "currency": "CNY",
      "energyKwh": 数字或null,
      "startAt": "YYYY-MM-DD HH:mm" 或 null,
      "endAt": "YYYY-MM-DD HH:mm" 或 null,
      "durationMin": 数字或null,
      "stationName": 字符串或null,
      "payStatus": 字符串或null,
      "starter": 字符串或null,
      "stopReason": 字符串或null,
      "orderNoTail4": 字符串或null,
      "serviceFeeAmount": 数字或null,
      "serviceFeeOriginal": 数字或null,
      "totalAmount": 数字或null,
      "confidence": 0~1,
      "evidenceText": 你据以判断金额的那一行原文片段
    }
  ]
}
金额必须命中该行右侧带 ¥ 的数字；不要把服务费原价当金额。

第三方账单的常见版式（字段名各家长得不一样，都要兼容）：
- 「充电62.370度 · 用时37分钟」→ energyKwh=62.370，durationMin=37
- 「充电时长 00:18:25」→ durationMin=18.4（时分秒折算成分钟，保留一位小数）
- 「充电电量：56.9710度」→ energyKwh=56.971
- 时间字段可能叫「下单时间」「充电时间」，也可能只是行首一个裸时间 ——
  都填进 startAt：它是截图里**最接近充电开始**的已知时间，
  不要因为字段名叫"下单时间"就留空。
- 页面顶部的「累计花费 / 累计充电」是汇总，不是一笔订单，不要输出成 row。"""


def _as_float(value: Any) -> float | None:
    """转数字。模型经常带单位（`"80.146度"`、`"¥28.85"`、`"1,234.5"`），
    所以整串解析失败时再抠一次数字 —— 否则电量会静默变成 None，
    后面的"每度多少钱"和配对就全废了。
    """
    if isinstance(value, bool):
        return None
    if isinstance(value, (int, float)):
        return float(value)
    if isinstance(value, str):
        cleaned = value.replace("¥", "").replace("￥", "").replace(",", "").strip()
        try:
            return float(cleaned)
        except ValueError:
            pass
        match = _NUMBER_RE.search(cleaned)
        return float(match.group()) if match else None
    return None


def _duration_to_minutes(value: Any) -> float | None:
    """时长文本折算成分钟（18.4）。认三种写法，认不出返回 None 交给调用方兜底。

    各家第三方账单不统一：改充电给「用时37分钟」、理想超充给「00:18:25」、
    有的给「1小时30分」。模型常连标签一起抄回来（"充电时长 00:18:25"），
    所以一律用"在文本里找"而不是整串匹配。
    """
    if not isinstance(value, str):
        return None
    text = value.strip()
    if not text:
        return None

    # 时间戳不是时长：模型偶尔把 startAt 抄进 durationMin，不能把日期算成 23 小时
    if _DATE_LIKE_RE.search(text):
        return None

    # ① 中文单位最明确，先试（"1小时30分" / "18分25秒" / "37分钟"）
    #    各段都是可选的，`search` 会先命中空串 —— 所以要挨个找"至少有一段数字"的匹配
    for cn in _CN_DURATION_RE.finditer(text):
        if not any(cn.groups()):
            continue
        hours, minutes, seconds = (int(g) if g else 0 for g in cn.groups())
        total = hours * 60 + minutes + seconds / 60
        if total > 0 and minutes < 60 and seconds < 60:
            return round(total, 1)
        break

    # ② 时钟写法（"00:18:25" / "18:25" / "充电时长 00:18:25"）
    match = _CLOCK_RE.search(text)
    if not match:
        return None
    first = int(match.group(1))
    second = int(match.group(2))
    third = match.group(3)
    if third is None:
        # 两段式有歧义："1:30" 更像 1 小时 30 分，"18:25" 更像 18 分 25 秒。
        # 判据用常识：一次充电超过 12 小时极罕见，所以首段 ≥12 按 分:秒 读。
        if second >= 60:
            return None
        return round(first + second / 60, 1) if first >= 12 else round(first * 60 + second, 1)

    seconds = int(third)
    if second >= 60 or seconds >= 60:
        return None       # "99:99" 这种明显不是时长，宁可判不出也别编
    return round(first * 60 + second + seconds / 60, 1)


def _scrub_text(value: Any) -> str | None:
    """把文本里的 VIN / 手机号 / 长数字清掉。"""
    if not isinstance(value, str):
        return None
    text = _VIN_RE.sub("", value)
    text = _PHONE_RE.sub("", text)
    text = _LONG_DIGITS_RE.sub("", text)
    text = re.sub(r"\s{2,}", " ", text).strip()
    return text or None


def scrub_row(row: dict[str, Any]) -> dict[str, Any]:
    """按白名单裁字段，并做回传过滤。

    ⚠️ **不要只依赖 prompt**：模型偶尔会把订单号整串吐出来，
    或者把 VIN 塞进 evidenceText。这里再兜一层，落库前就是干净的。
    """
    out: dict[str, Any] = {key: row.get(key) for key in ALLOWED_KEYS}

    out["amount"] = _as_float(out.get("amount"))
    out["energyKwh"] = _as_float(out.get("energyKwh"))
    # 时长先试时分秒（"00:18:25"），不行再当普通数字（"用时37分钟" → 37）
    minutes = _duration_to_minutes(row.get("durationMin"))
    if minutes is None:
        minutes = _as_float(row.get("durationMin"))
    out["durationMin"] = minutes
    out["serviceFeeAmount"] = _as_float(out.get("serviceFeeAmount"))
    out["serviceFeeOriginal"] = _as_float(out.get("serviceFeeOriginal"))
    out["totalAmount"] = _as_float(out.get("totalAmount"))
    out["confidence"] = _as_float(out.get("confidence"))

    # 订单号只保留后四位：完整单号属于支付侧凭据，没有落库的必要
    tail = out.get("orderNoTail4")
    if tail not in (None, ""):
        digits = re.sub(r"\D", "", str(tail))
        out["orderNoTail4"] = digits[-4:] or None
    else:
        out["orderNoTail4"] = None

    station = _scrub_text(out.get("stationName"))
    if station:
        station = _ADDRESS_TAIL_RE.sub("", station).strip()
    out["stationName"] = station or None

    for key in ("startAt", "endAt"):
        value = _scrub_text(out.get(key))
        out[key] = value

    out["evidenceText"] = _scrub_text(out.get("evidenceText"))
    out["payStatus"] = _scrub_text(out.get("payStatus"))
    out["starter"] = _scrub_text(out.get("starter"))
    out["stopReason"] = _scrub_text(out.get("stopReason"))
    out["currency"] = "CNY"

    return out


def _parse_payload(text: str) -> dict[str, Any]:
    """从模型回复里抠出 JSON。模型偶尔会套 ```json 围栏或加一句解释。"""
    cleaned = text.strip()
    if cleaned.startswith("```"):
        cleaned = re.sub(r"^```[a-zA-Z]*\s*", "", cleaned)
        cleaned = re.sub(r"\s*```$", "", cleaned)
    try:
        data = json.loads(cleaned)
    except json.JSONDecodeError:
        start, end = cleaned.find("{"), cleaned.rfind("}")
        if start < 0 or end <= start:
            raise VisionFailed("识别结果不是 JSON") from None
        try:
            data = json.loads(cleaned[start : end + 1])
        except json.JSONDecodeError as exc:
            raise VisionFailed("识别结果不是合法 JSON") from exc
    if not isinstance(data, dict):
        raise VisionFailed("识别结果结构异常")
    return data


async def extract_receipts(
    image: bytes, mime: str = "image/jpeg", *, include_raw: bool = False
) -> dict[str, Any]:
    """识别一张充电账单截图。

    Args:
        image: 原始图片字节。**只存在于内存**，调用方负责不做落盘。
        mime: `image/jpeg` / `image/png` / `image/webp` / `image/gif`。
        include_raw: 额外带回模型**原文**与未清洗字段。
            ⚠️ 只许调试接口用：原文可能含 prompt 没拦住的 VIN / 手机号 /
            完整订单号 —— 不入库、不进日志、不进正式链路。

    Returns:
        {"type": "list_row|order_detail|receipt", "rows": [清洗后的字段], "imageSha8": str}
        include_raw=True 时另有 "raw"（模型原文）与 "parsedRows"（未清洗字段）。

    Raises:
        VisionUnavailable: 没有配置 key（调用方转 503，并提示去配）。
        VisionFailed: 上游超时 / 限流 / 返回不可解析。
    """
    if not config.deepseek_api_key:
        raise VisionUnavailable("未配置 DEEPSEEK_API_KEY，无法使用截图识别")

    started = time.perf_counter()
    image_sha8 = sha256(image).hexdigest()[:8]
    b64 = base64.b64encode(image).decode("ascii")

    payload = {
        "model": config.vision_model,
        "messages": [
            {
                "role": "user",
                "content": [
                    {"type": "text", "text": PROMPT},
                    {
                        "type": "image_url",
                        "image_url": {"url": f"data:{mime};base64,{b64}"},
                    },
                ],
            }
        ],
        "response_format": {"type": "json_object"},
        "temperature": 0.2,
    }
    headers = {
        "Authorization": f"Bearer {config.deepseek_api_key}",
        "Content-Type": "application/json",
    }
    url = config.deepseek_base_url.rstrip("/") + "/chat/completions"

    # 429 / 超时按 1s、3s、9s 退避 —— 上游限流是常态，一次失败不该让用户重传图片
    last_error: Exception | None = None
    for attempt, delay in enumerate((1, 3, 9)):
        try:
            async with httpx.AsyncClient(timeout=60.0) as client:
                resp = await client.post(url, headers=headers, json=payload)
            if resp.status_code == 429 or resp.status_code >= 500:
                last_error = VisionFailed(f"上游返回 {resp.status_code}")
                await asyncio.sleep(delay)
                continue
            if resp.status_code != 200:
                # 401/403 是 key 或权限问题，重试没有意义
                raise VisionFailed(f"上游拒绝请求（HTTP {resp.status_code}）")
            body = resp.json()
            content = (
                body.get("choices", [{}])[0].get("message", {}).get("content") or ""
            )
            parsed = _parse_payload(content)
            rows = parsed.get("rows")
            if not isinstance(rows, list):
                rows = []
            cleaned = [scrub_row(r) for r in rows if isinstance(r, dict)][:MAX_ROWS]
            cleaned = [r for r in cleaned if r.get("amount") is not None]

            logger.info(
                "账单识别完成：sha=%s %dKB %.0fms，%d 行",
                image_sha8, len(image) // 1024, (time.perf_counter() - started) * 1000, len(cleaned),
            )
            result: dict[str, Any] = {
                "type": str(parsed.get("type") or "receipt"),
                "rows": cleaned,
                "imageSha8": image_sha8,
            }
            if include_raw:
                # 调试用：模型原文 + 未清洗字段。白名单过滤把"模型到底读了什么"
                # 也一起裁掉了 —— 评测识别质量恰恰要看的就是被裁掉的那部分。
                result["raw"] = content
                result["parsedRows"] = [r for r in rows if isinstance(r, dict)][:MAX_ROWS]
            return result
        except VisionFailed as exc:
            last_error = exc
            if attempt < 2:
                await asyncio.sleep(delay)
            continue
        except (httpx.HTTPError, json.JSONDecodeError) as exc:
            last_error = exc
            logger.warning("账单识别失败（第 %d 次）：%s", attempt + 1, type(exc).__name__)
            if attempt < 2:
                await asyncio.sleep(delay)
            continue

    raise VisionFailed(f"截图识别失败：{last_error or '上游无响应'}")
