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
    /// 天青 —— 主色·清爽天蓝
    static let tianQing = Color(hex: 0x2E8BC0)
    /// 天青（深）—— 主色强调态
    static let tianQingDeep = Color(hex: 0x1C6FA8)
    /// 竹青 —— 安全色系
    static let zhuQing = Color(hex: 0x16B89A)
    /// 青碧 —— 安全 / 正常
    static let qingBi = Color(hex: 0x16B89A)
    /// 缥色 —— 淡天蓝底
    static let piaoSe = Color(hex: 0xE8F2FA)

    // MARK: 蓝色系
    /// 靛蓝 —— 主色（深）
    static let dianLan = Color(hex: 0x3A6EA5)
    /// 靛青 —— 充电 / 强调
    static let dianQing = Color(hex: 0x1E7FC2)
    /// 藏青 —— 深色背景
    static let cangQing = Color(hex: 0x2C3E5C)
    /// 群青 —— 辅助蓝
    static let qunQing = Color(hex: 0x4C8DAE)

    // MARK: 红色系（告警 / 强调）
    /// 朱砂 —— 告警色
    static let zhuSha = Color(hex: 0xE5483B)
    /// 胭脂 —— 深红强调
    static let yanZhi = Color(hex: 0xC0392B)
    /// 妃色 —— 柔和红
    static let feiSe = Color(hex: 0xF6B8B0)
    /// 珊瑚 —— 「开启中」状态色（车控按钮）
    ///
    /// 与朱砂告警红同属红粉系，刻意用明度拉开差距，避免「按钮开着」
    /// 被读成「按钮异常」。这是深色模式用的本源色；浅色模式需加深
    /// （对比度 1.91 撑不住浅玻璃底），故经由 `Theme.coral(_:)` 取值。
    static let shanHu = Color(hex: 0xFA9894)
    /// 珊瑚（浅色模式加深版）—— 对比度 4.25，压得住浅色玻璃底
    static let shanHuDeep = Color(hex: 0xC9483F)

    // MARK: 黄色系（强调 / 充电状态）
    /// 藤黄 —— 强调色
    static let tengHuang = Color(hex: 0xFFB020)
    /// 缃色 —— 柔和黄
    static let xiangSe = Color(hex: 0xF4B400)
    /// 缇色 —— 暖橙
    static let tiSe = Color(hex: 0xF2994A)

    // MARK: 中性色
    /// 月白 —— 背景·冷中性白
    static let yueBai = Color(hex: 0xF3F5F7)
    /// 象牙白 —— 卡片·纯白
    static let xiangYaBai = Color(hex: 0xFFFFFF)
    /// 缟色 —— 冷灰
    static let gaoSe = Color(hex: 0xEDF1F4)
    /// 墨色 —— 主文字
    static let moSe = Color(hex: 0x1B1F24)
    /// 玄青 —— 次级文字
    static let xuanQing = Color(hex: 0x4A4E57)
    /// 黛色 —— 弱化文字
    static let daiSe = Color(hex: 0x5B6472)

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
        scheme == .dark ? Color(hex: 0x14171C) : ChineseColor.yueBai
    }
    static func surface(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: 0x1E2228) : ChineseColor.xiangYaBai
    }
    static func surfaceAlt(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: 0x272C33) : ChineseColor.gaoSe
    }

    // MARK: 文字层级
    static func textPrimary(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: 0xECEFF3) : ChineseColor.moSe
    }
    static func textSecondary(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: 0x9AA3AE) : ChineseColor.xuanQing.opacity(0.62)
    }
    static func textTertiary(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: 0x626B76) : ChineseColor.daiSe.opacity(0.42)
    }

    // MARK: 主色（随明暗微调，保证对比度）
    static func accent(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: 0x4DA3DC) : ChineseColor.tianQingDeep
    }
    static func accentSecondary(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? ChineseColor.qunQing : ChineseColor.dianLan
    }

    // MARK: 状态色（车控按钮的「开启中」）
    /// 珊瑚 —— 车控按钮开启态的状态色，随明暗取两值。
    ///
    /// 浅色模式必须用加深版：本源色 #FA9894 在浅玻璃底上对比度仅 1.91，
    /// 图标线条会发飘；加深到 #C9483F 后为 4.25。深色模式下本源色
    /// 本身就是 6.68，直接用即可。
    static func coral(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? ChineseColor.shanHu : ChineseColor.shanHuDeep
    }

    // MARK: 分隔线 / 描边
    static func separator(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.08) : ChineseColor.moSe.opacity(0.08)
    }

    /// 电量状态色映射
    static func socColor(_ soc: Double) -> Color {
        switch soc {
        case ..<30: return ChineseColor.zhuSha      // 朱砂 #E5483B
        case ..<50: return ChineseColor.tengHuang   // 藤黄 #FFB020
        default:    return ChineseColor.qingBi      // 青碧 #16B89A
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
    /// `ScreenContainer` 需要在滚动内容底部预留的高度（**不含**系统安全区）。
    ///
    /// 胶囊贴住屏幕底边后，自屏幕底边往上各段距离是：
    ///   下留白 14 → 胶囊 64（padding 7×2 + item minHeight 50）→ 胶囊上沿落在 78。
    /// 内容下边缘取「胶囊上沿 + 27」，与预览页的内容留白比例一致 → 105。
    /// 其中系统安全区（约 34）由 `safeAreaBar` 自动叠加、卡片自带的
    /// `.padding(.bottom, 24)` 也已计入，所以这里只写剩下的 47。
    ///
    /// 若不预留，最后一张卡片（快捷车控）会永远停在胶囊后面滚不上来。
    static let tabBarClearance: CGFloat = 47
}
