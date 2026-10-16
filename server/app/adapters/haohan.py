"""浩汉充电接入层（第三方网关）。

**为什么会有这个模块**：极氪 App 的充电地图并不是极氪自己实现的 —— 地图页
内嵌的是浩汉能源（`haohanpower.tech`）的 SDK（APK 里的 `com.haohan.*` 包）。
极氪侧 `zeekrlife-bbs-theme/.../bubble/charge/getListV2` 只给坐标与枪数，
23 个字段里**没有任何价格数值**（`marketingPriceFlag` 只是布尔标记），
也没有站点名；电价与站名都在浩汉网关。

**认证与极氪毫无关系**，而且是全套里最简单的一环：

    POST {host}/haohan-charge/find/station/detail
    Header: channelId: 1          ← 唯一凭证
    Body:   {"stationId": "..."}

不需要登录、不需要签名、不需要 X-VIN、不需要极氪 JWT。渠道号 `1` 取自浩汉
小程序前端的硬编码（`{"sourceCode":4,"channelId":1,...}`），故做成配置项
（见 `core/config.py`）—— 逆向得到的常量不该散落在代码里。

**隐私边界（重要，勿破坏）**：本模块**只发 stationId，从不发送用户坐标**。
也就是说第三方拿不到"你在哪"；坐标只发给极氪自己的网关（本来就是它家的数据）。
"""

from __future__ import annotations

import logging
from typing import Any

import httpx

logger = logging.getLogger(__name__)

DEFAULT_HOST = "https://gateway-prod.haohanpower.tech"
TIMEOUT = 15.0

# 浩汉的成功码是**四位** `0000`（极氪那边是六位 `000000`，两者别混）
CODE_SUCCESS = "0000"

PATH_STATION_DETAIL = "/haohan-charge/find/station/detail"
PATH_STATION_DYNAMIC = "/haohan-charge/find/station/dynamic"


def _to_float(value: Any) -> float | None:
    """宽松转 float，失败返回 None。

    必要：上游同一语义的字段类型并不统一 —— `totalPrice` 是数字（1.9），
    而 `feeElectric` / `serviceFee` / 分时表里的 `totalPrice` 都是**字符串**
    （"1.10"），`lat`/`lng` 也是字符串。
    """
    if value is None or value == "":
        return None
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


class HaohanClient:
    """浩汉充电网关客户端：站点详情（价格）与实时动态。"""

    def __init__(self, host: str = DEFAULT_HOST, channel_id: str = "1") -> None:
        self._host = (host or DEFAULT_HOST).rstrip("/")
        self._channel_id = str(channel_id or "1")
        self._http = httpx.AsyncClient(timeout=TIMEOUT, follow_redirects=True)

    async def _post(self, path: str, body: dict[str, Any]) -> Any:
        """POST 并返回 `data`；任何失败都返回 `None`（由调用方决定降级）。

        为什么这里吞掉异常、不往上抛：本模块只服务于「给列表补价格」这一件事，
        补不上就不显示价格，**不该让整个充电站页面失败**。于是把"网络失败"
        与"业务失败"统一收敛成 `None`，降级策略集中在上层。

        注意网关的错误信息具有误导性，遇到时别顺着它排查：
        `52003 渠道信息缺失` 与 `1027 当前站点暂未开放` 两个错**都在说
        "channelId 请求头没带或不对"**，与站点是否开放无关。
        """
        try:
            resp = await self._http.post(
                f"{self._host}{path}",
                headers={"channelId": self._channel_id},
                json=body,
            )
            payload = resp.json()
        except (httpx.HTTPError, ValueError) as exc:
            logger.warning("浩汉接口请求失败 %s：%s", path, exc)
            return None

        if not isinstance(payload, dict):
            return None

        if str(payload.get("code", "")).strip() != CODE_SUCCESS:
            logger.debug(
                "浩汉接口 %s 返回 %s / %s",
                path,
                payload.get("code"),
                payload.get("msg") or payload.get("message"),
            )
            return None

        return payload.get("data")

    async def get_station_detail(self, station_id: str) -> dict[str, Any] | None:
        """站点详情（含电价、分时表、停车费、占位费规则）。"""
        data = await self._post(PATH_STATION_DETAIL, {"stationId": station_id})
        return data if isinstance(data, dict) else None

    async def get_station_dynamic(self, station_id: str) -> dict[str, Any] | None:
        """站点实时动态（枪数、即将结束占用的枪数、功率区间）。

        当前未接入 UI —— 气泡接口已给可用枪数，此处先备着。
        """
        data = await self._post(PATH_STATION_DYNAMIC, {"stationId": station_id})
        return data if isinstance(data, dict) else None

    async def aclose(self) -> None:
        """释放底层连接。"""
        await self._http.aclose()


def map_price(detail: dict[str, Any]) -> dict[str, Any]:
    """把浩汉 detail 归一化成前端价格契约。

    只取界面要展示的部分。原响应有 35+ 个字段，绝大多数是营销位、图层配置
    与后台开关；全量透传只会让前端契约跟着上游一起漂 ——
    最后变成"改一处 UI 要读三个厂商的字段表"。
    """
    periods: list[dict[str, Any]] = []
    raw_periods = detail.get("electricFeeList") or detail.get("detailElectricFeeList") or []
    if isinstance(raw_periods, list):
        for item in raw_periods:
            if not isinstance(item, dict):
                continue
            periods.append(
                {
                    "timeFrame": str(item.get("timeFrame") or ""),
                    "electric": _to_float(item.get("feeElectric")),
                    "service": _to_float(item.get("feeService")),
                    "total": _to_float(item.get("totalPrice")),
                }
            )

    return {
        # 当前时段总价（元/度）—— 界面上那个大数字
        "totalPrice": _to_float(detail.get("totalPrice")),
        "feeElectric": _to_float(detail.get("feeElectric")),
        "serviceFee": _to_float(detail.get("serviceFee")),
        # 当前计费时段，如 "00:00-23:59"
        "currentPeriod": detail.get("electricFeeTime"),
        # 分时电价表：单一时段站点长度为 1，尖峰平谷站点会有多段
        "periods": periods,
        "parkingFee": detail.get("parkingFee"),
        "parkFree": bool(detail.get("parkFreeFlag")),
        "holdFee": bool(detail.get("holdFeeFlag")),
        "feeDesc": detail.get("chargeFeeDesc"),
    }


def map_station_info(detail: dict[str, Any]) -> dict[str, Any]:
    """从 detail 里取出**极氪侧拿不到**的那几个展示字段。

    气泡列表接口（`getListV2`）的 23 个字段里**没有站点名、没有地址、没有评分**
    —— 只有坐标、枪数与运营商 logo。这也正好解释了浩汉前端为什么要逐站预取
    detail 再合并成列表：不预取的话，列表上连站名都显示不出来。

    这里**只回这四个**：运营商 logo 与自营标记极氪侧已经给了，两边都取会制造
    "两个来源打架"的隐患 —— 将来值不一致时，以谁为准是说不清的。
    """
    tags: list[str] = []
    for item in detail.get("stationTagList") or []:
        if isinstance(item, dict) and item.get("tagDesc"):
            tags.append(str(item["tagDesc"]))

    return {
        "name": str(detail.get("stationName") or ""),
        "address": str(detail.get("address") or ""),
        # 注意上游拼写就是 `peaseScore`（不是 please），照抄，别"修正"
        "score": _to_float(detail.get("peaseScore")),
        "tags": tags,
    }
