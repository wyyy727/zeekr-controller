//
//  Theme.swift
//  ZeekrDash
//
//  中国传统色设计系统
//  色值来源：zhongguose.com（中科院科技情报编委会名词室《色谱》1957）
//

import SwiftUI

// MARK: - 中国传统色色值定义

extension Color {
    /// 以十六进制值创建颜色，例如 0x7FB3A8
    init(hex: UInt32, alpha: Double = 1.0) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255.0,
            green: Double((hex >> 8) & 0xFF) / 255.0,
            blue: Double(hex & 0xFF) / 255.0,
            opacity: alpha
        )
    }
}

/// 中国传统色色板
///
/// 设计语言：以**天青 / 靛蓝**为主色，**藤黄**作强调，**朱砂**作告警，
/// **月白 / 象牙白**作背景，**墨色**作文字。整体追求东方雅致感。
enum ChineseColor {

    // MARK: 青色系（主色）
    /// 天青 —— 主色
    static let tianQing = Color(hex: 0x7FB3A8)
    /// 天青（深）—— 主色强调态
    static let tianQingDeep = Color(hex: 0x5D8A7E)
    /// 竹青 —— 次色
    static let zhuQing = Color(hex: 0x789262)
    /// 青碧 —— 清新点缀
    static let qingBi = Color(hex: 0x48C0A3)
    /// 缥色 —— 淡青背景
    static let piaoSe = Color(hex: 0xE8F4F1)

    // MARK: 蓝色系
    /// 靛蓝 —— 主色（深）
    static let dianLan = Color(hex: 0x4C6E91)
    /// 靛青 —— 强调蓝
    static let dianQing = Color(hex: 0x177CB0)
    /// 藏青 —— 深色背景
    static let cangQing = Color(hex: 0x3B4A6B)
    /// 群青 —— 辅助蓝
    static let qunQing = Color(hex: 0x4C8DAE)

    // MARK: 红色系（告警 / 强调）
    /// 朱砂 —— 告警色
    static let zhuSha = Color(hex: 0xE23A28)
    /// 胭脂 —— 深红强调
    static let yanZhi = Color(hex: 0x9D2933)
    /// 妃色 —— 柔和红
    static let feiSe = Color(hex: 0xF6B8B0)

    // MARK: 黄色系（强调 / 充电状态）
    /// 藤黄 —— 强调色
    static let tengHuang = Color(hex: 0xFFB61E)
    /// 缃色 —— 柔和黄
    static let xiangSe = Color(hex: 0xF0C239)
    /// 缇色 —— 暖橙
    static let tiSe = Color(hex: 0xF0A35E)

    // MARK: 中性色
    /// 月白 —— 浅色背景
    static let yueBai = Color(hex: 0xEEF7F2)
    /// 象牙白 —— 卡片背景
    static let xiangYaBai = Color(hex: 0xFFFBF0)
    /// 缟色 —— 次级背景
    static let gaoSe = Color(hex: 0xF2ECDE)
    /// 墨色 —— 主文字
    static let moSe = Color(hex: 0x252726)
    /// 玄青 —— 次级文字
    static let xuanQing = Color(hex: 0x3D3B4F)
    /// 黛色 —— 弱化文字
    static let daiSe = Color(hex: 0x4A4266)

    // MARK: 语义色
    /// 电量充足 / 正常
    static let statusGood = qingBi
    /// 电量中等 / 提醒
    static let statusWarn = tengHuang
    /// 电量不足 / 错误
    static let statusBad = zhuSha
    /// 充电中
    static let statusCharging = dianQing
}

// MARK: - 语义化主题

/// 主题：集中管理语义色的明暗适配
enum Theme {

    // MARK: 背景层级
    static func background(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: 0x1A1C1B) : ChineseColor.yueBai
    }
    static func surface(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: 0x242726) : ChineseColor.xiangYaBai
    }
    static func surfaceAlt(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: 0x2E312F) : ChineseColor.gaoSe
    }

    // MARK: 文字层级
    static func textPrimary(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: 0xEDEFEC) : ChineseColor.moSe
    }
    static func textSecondary(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: 0xA5A9A4) : ChineseColor.xuanQing.opacity(0.62)
    }
    static func textTertiary(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: 0x6E726D) : ChineseColor.daiSe.opacity(0.42)
    }

    // MARK: 主色（随明暗微调，保证对比度）
    static func accent(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? ChineseColor.tianQing : ChineseColor.tianQingDeep
    }
    static func accentSecondary(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? ChineseColor.qunQing : ChineseColor.dianLan
    }

    // MARK: 分隔线 / 描边
    static func separator(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.08) : ChineseColor.moSe.opacity(0.08)
    }

    /// 电量状态色映射
    static func socColor(_ soc: Double) -> Color {
        switch soc {
        case ..<20: return ChineseColor.statusBad
        case ..<50: return ChineseColor.statusWarn
        default:    return ChineseColor.statusGood
        }
    }
}

// MARK: - 圆角 / 间距常量（保持视觉一致）

enum Metrics {
    static let cardRadius: CGFloat = 16
    static let cardPadding: CGFloat = 16
    static let sectionSpacing: CGFloat = 12
    static let screenPadding: CGFloat = 16
    /// 触控目标最小边长（iOS HIG）
    static let minTouchTarget: CGFloat = 44
}
