"""坐标系转换。用公开参考值校验，避免"自己算的跟自己比"。

背景：极氪车况的 `position` 带 `marsCoordinates` 标志，实测为 `"0"`
（原始 WGS-84）。直接拿去给腾讯/高德显示会偏 400~600 米，
这里守的就是这段转换不出错。
"""

from __future__ import annotations

from app.core.coords import gcj02_to_wgs84, out_of_china, wgs84_to_gcj02


def test_matches_public_reference():
    """eviltransform 的公开样例（上海），用来确认算法实现没写错。"""
    lat, lng = wgs84_to_gcj02(31.1774276, 121.5272106)
    assert abs(lat - 31.17530398364597) < 1e-5
    assert abs(lng - 121.531541859215) < 1e-5


def test_outside_china_is_untouched():
    """境外不偏移 —— 做了反而会把正确坐标弄错。"""
    assert out_of_china(2.3522, 48.8566) is True
    assert wgs84_to_gcj02(48.8566, 2.3522) == (48.8566, 2.3522)
    assert gcj02_to_wgs84(48.8566, 2.3522) == (48.8566, 2.3522)


def test_shift_magnitude_is_plausible():
    """国内偏移应在几百米量级。

    太小（≈0）说明没转，太大（>2km）说明算错了 —— 这两种都会被这条断言抓住。
    """
    # 演示坐标（**不是真车位置**）：只要落在国内，偏移量就在同一量级
    lat, lng = 30.123456, 120.123456
    glat, glng = wgs84_to_gcj02(lat, lng)
    dy = (glat - lat) * 111320
    dx = (glng - lng) * 111320 * 0.855  # 该纬度上 1° 经度 ≈ 95.2 km
    dist = (dx * dx + dy * dy) ** 0.5
    assert 200 < dist < 800, f"偏移 {dist:.0f} m 不合常理"


def test_roundtrip_within_two_meters():
    """反解回原始坐标的误差应可忽略（只用于展示级还原）。"""
    lat, lng = 30.123456, 120.123456
    back_lat, back_lng = gcj02_to_wgs84(*wgs84_to_gcj02(lat, lng))
    assert abs(back_lat - lat) * 111320 < 2
    assert abs(back_lng - lng) * 111320 < 2
