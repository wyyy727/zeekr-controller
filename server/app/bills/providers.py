"""充电消费服务商识别。

策略：**商户名关键词匹配**。

支付宝 / 微信导出的账单里，充电消费的交易对方名称通常包含
服务商品牌词。这里维护一张关键词表，按优先级依次匹配。

风险提示：关键词匹配无法保证 100% 准确。建议首次导入后人工复核，
并把误判的商户名补充到 `MANUAL_OVERRIDES`。
"""

from __future__ import annotations

# 服务商优先级：数字越小越优先。
# 知名品牌（自有 App、有明确归属）优先于泛化的第三方聚合平台，
# 避免「极氪能源科技」被「能源科技」这类泛词误判。
PROVIDER_PRIORITY: dict[str, int] = {
    "zeekr": 0,
    "starCharge": 1,
    "teld": 2,
    "stateGrid": 3,
    "eCharging": 4,
    "other": 99,
}

# 服务商关键词表
# 品牌词应尽量具体，泛词集中放在 other
PROVIDER_KEYWORDS: dict[str, list[str]] = {
    "zeekr": [
        "极氪", "zeekr", "极充", "极能",
    ],
    "starCharge": [
        "星星充电", "星星能源", "万帮", "星星充",
    ],
    "teld": [
        "特来电", "特来", "teld",
    ],
    "stateGrid": [
        "国家电网", "国网", "网上国网", "电动汽车服务",
    ],
    "eCharging": [
        "e充电", "依威能源", "云快充", "小桔充电", "滴滴充电",
    ],
    "other": [
        "充电", "快充", "超充", "充电桩", "新能源", "能源科技",
        "电力", "电动车", "充电服务",
    ],
}

# 人工修正表：商户名 → 服务商 key
# 首次导入后如发现误判，把商户名加到这里
MANUAL_OVERRIDES: dict[str, str] = {}

# 排除词：命中这些词的**不**算充电消费（避免误伤）
EXCLUDE_KEYWORDS: list[str] = [
    "充电宝", "充电线", "充电器", "充电头", "数据线", "充电插头",
    "话费", "流量", "宽带",
]


def is_excluded(merchant: str, description: str = "") -> bool:
    """判断是否为需要排除的非充电消费。"""
    text = f"{merchant} {description}"
    return any(word in text for word in EXCLUDE_KEYWORDS)


def detect_provider(merchant: str, description: str = "") -> str | None:
    """识别充电服务商。

    匹配策略：**双维度排序** —— 先比服务商优先级，再比关键词长度。

    - 优先级解决「品牌词 vs 泛词」的竞争：
      「极氪能源科技」同时命中「极氪」（zeekr）与「能源科技」（other），
      按优先级判定为 zeekr，而非按长度判定为 other。
    - 长度解决「同优先级内的子串重叠」：
      「小桔充电」与「e充电」同在 eCharging 优先级，
      长词「小桔充电」优先，不会被短词「充电」抢先。

    Args:
        merchant: 交易对方 / 商户名称
        description: 交易说明（部分账单有）

    Returns:
        服务商 key，无法识别时返回 None
    """
    if not merchant and not description:
        return None

    # 人工修正优先
    for name, provider in MANUAL_OVERRIDES.items():
        if name in merchant:
            return provider

    if is_excluded(merchant, description):
        return None

    text = f"{merchant} {description}".lower()

    # 扁平化为 (优先级, -关键词长度, 服务商, 关键词)，升序排列即最优匹配在前
    candidates: list[tuple[int, int, str, str]] = [
        (PROVIDER_PRIORITY.get(provider, 50), -len(keyword), provider, keyword.lower())
        for provider, keywords in PROVIDER_KEYWORDS.items()
        for keyword in keywords
    ]
    candidates.sort()

    for _priority, _neg_len, provider, keyword in candidates:
        if keyword in text:
            return provider

    return None


def provider_display_name(provider: str | None) -> str:
    """服务商 key → 显示名。"""
    names = {
        "zeekr": "极氪极充",
        "starCharge": "星星充电",
        "teld": "特来电",
        "stateGrid": "国家电网",
        "eCharging": "e充电",
        "other": "其他",
    }
    return names.get(provider or "other", "其他")
