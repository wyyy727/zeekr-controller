"""坐标系转换：WGS-84 ↔ GCJ-02。

**为什么需要这个模块**：极氪车况接口的 `basicVehicleStatus.position` 里带了
一个 `marsCoordinates` 标志，实测值为 `"0"` —— 意思是**不是火星坐标**，
也就是**原始 WGS-84**。而国内所有地图（腾讯/高德/百度）展示的都要求 GCJ-02。

把 WGS-84 直接丢给地图，华东地区会偏 **约 400–600 米**，表现就是
「车的位置整体挪了一大截，但地址看着又大致对」—— 因为偏得不够远，
不会跳到别的城市，只会落到隔壁街区。

⚠️ 不要凭车型硬编码：`marsCoordinates` 是网关自己给的权威标记。
  · `"1"` → 已是 GCJ-02，**不要再转**（再转就反向偏回去）
  · `"0"` → WGS-84，需要转
  · 缺失 → 保持原样（没有证据就不动，宁可不转也不要过转）

算法是公开的 GCJ-02 偏移公式（与 eviltransform 同源），境外坐标原样返回。
"""

from __future__ import annotations

import math

_A = 6378245.0  # 克拉索夫斯基椭球长半轴
_EE = 0.00669342162296594323  # 第一偏心率平方


def out_of_china(lng: float, lat: float) -> bool:
    """粗略国境判断。GCJ-02 只在中国大陆生效，境外做偏移反而会错。"""
    return not (73.66 < lng < 135.05 and 3.86 < lat < 53.55)


def _transform_lat(x: float, y: float) -> float:
    ret = -100.0 + 2.0 * x + 3.0 * y + 0.2 * y * y + 0.1 * x * y + 0.2 * math.sqrt(abs(x))
    ret += (20.0 * math.sin(6.0 * x * math.pi) + 20.0 * math.sin(2.0 * x * math.pi)) * 2.0 / 3.0
    ret += (20.0 * math.sin(y * math.pi) + 40.0 * math.sin(y / 3.0 * math.pi)) * 2.0 / 3.0
    ret += (160.0 * math.sin(y / 12.0 * math.pi) + 320.0 * math.sin(y * math.pi / 30.0)) * 2.0 / 3.0
    return ret


def _transform_lng(x: float, y: float) -> float:
    ret = 300.0 + x + 2.0 * y + 0.1 * x * x + 0.1 * x * y + 0.1 * math.sqrt(abs(x))
    ret += (20.0 * math.sin(6.0 * x * math.pi) + 20.0 * math.sin(2.0 * x * math.pi)) * 2.0 / 3.0
    ret += (20.0 * math.sin(x * math.pi) + 40.0 * math.sin(x / 3.0 * math.pi)) * 2.0 / 3.0
    ret += (150.0 * math.sin(x / 12.0 * math.pi) + 300.0 * math.sin(x / 30.0 * math.pi)) * 2.0 / 3.0
    return ret


def wgs84_to_gcj02(lat: float, lng: float) -> tuple[float, float]:
    """WGS-84 → GCJ-02。返回 (lat, lng)，保留 6 位小数（≈0.1 米）。

    注意参数顺序与项目里的 `status.latitude/longitude` 一致：**先纬度后经度**。
    """
    if out_of_china(lng, lat):
        return lat, lng

    dlat = _transform_lat(lng - 105.0, lat - 35.0)
    dlng = _transform_lng(lng - 105.0, lat - 35.0)

    radlat = lat / 180.0 * math.pi
    magic = math.sin(radlat)
    magic = 1 - _EE * magic * magic
    sqrtmagic = math.sqrt(magic)

    dlat = (dlat * 180.0) / ((_A * (1 - _EE)) / (magic * sqrtmagic) * math.pi)
    dlng = (dlng * 180.0) / (_A / sqrtmagic * math.cos(radlat) * math.pi)

    return round(lat + dlat, 6), round(lng + dlng, 6)


def gcj02_to_wgs84(lat: float, lng: float) -> tuple[float, float]:
    """GCJ-02 → WGS-84 的近似反解（一次迭代，误差约 1–2 米，够展示用）。

    只用于「把地图上的点还原成原始值」这类场景，比如以后要跟
    充电站坐标（GCJ-02）比较时反向换算。**不要**拿它做高精度测绘。
    """
    if out_of_china(lng, lat):
        return lat, lng

    glat, glng = wgs84_to_gcj02(lat, lng)
    return round(lat * 2 - glat, 6), round(lng * 2 - glng, 6)
