//
//  V2Theme.swift
//  ZeekrDash
//
//  v2 设计系统：颜色 / 字体 / 排版 / 度量
//
//  **真源是 `preview/index-v2.html`**，不是设计稿、不是旧 iOS 现状、不是审美。
//  下面每个数值都能在 HTML 里指到出处，改动前先回到 HTML 核对。
//
//  旧的 `Theme.swift`（中国传统色 + `Metrics`）已在阶段 6 删除，五屏全部迁到本文件；
//  `Color(hex:)` 这个唯一被依赖的初始化器搬到了下面。现在工程里只有这一套 design token。
//

import SwiftUI

/* `Color(hex:)` 原先定义在 v1 的 `Theme.swift` 里。v2 全面接管后那个文件已删除，
   这个初始化器是整个工程唯一的十六进制入口，搬到主题文件里继续用。 */
extension Color {
    /// 以十六进制值创建颜色，例如 0x6742E8
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

// MARK: - 颜色

/// v2 色板。
///
/// 出处：`index-v2.html` 的 `<style id="v2-tokens">`（约 1596 行起）。
enum V2Color {

    // MARK: 文字三档
    // 注释里的数字是 HTML 给的实测对比度（卡底 #F9FAFD）
    static let text1 = Color(hex: 0x1B2233)   // 15.21
    static let text2 = Color(hex: 0x5E6775)   //  5.48
    static let text3 = Color(hex: 0x666F7E)   //  4.86

    // MARK: 主色与语义色
    static let accent = Color(hex: 0x6742E8)
    static let good   = Color(hex: 0x0F7F58)
    static let bad    = Color(hex: 0xC0392B)
    static let info   = Color(hex: 0x08789F)
    static let warn   = Color(hex: 0x8A5A12)
    static let muted  = Color(hex: 0x6B7484)

    // MARK: 提示底色（描边同色 @0.35 1px）
    static let tintWarn   = Color(hex: 0xFEF3E2)
    static let tintBad    = Color(hex: 0xFFF1F4)
    static let tintGood   = Color(hex: 0xEAF7F1)
    static let tintInfo   = Color(hex: 0xE9F6FD)
    static let tintAccent = Color(hex: 0xEEF0FE)
    static let tintMuted  = Color(hex: 0xEEF0F8)

    // MARK: 背景（`.screen` 的 180deg 三停渐变）
    static let bgTop    = Color(hex: 0xF7F8FC)   //   0%
    static let bgMiddle = Color(hex: 0xEEF2FA)   //  50%
    static let bgBottom = Color(hex: 0xE8EEF7)   // 100%

    /// 分隔线（`--separator: rgba(27,31,36,.07)`）
    static let separator = Color(hex: 0x1B1F24).opacity(0.07)

    /// 实色发丝线 `#E7EBF3`（出处：`index-v2.html:2158` `.v2-sheet-list .st` 的 border-bottom）。
    ///
    /// 与 `separator` 的区别：那条是 7% 黑的半透明，铺在玻璃卡上会随背景变色；
    /// 充电站 sheet 的行间线在 HTML 里是**实色**，且 sheet 底是纯白 —— 用半透明会偏浅。
    static let hairline = Color(hex: 0xE7EBF3)

    /// BlobViolet —— 300×300 @(170, -70)，四停 radial
    static let auraViolet = Color(hex: 0xC4B5FD)
    /// BlobCyan —— 260×260 @(-90, 540)，四停 radial
    ///
    /// BlobCoral（200×200 @(250,610)）在 HTML 里**已被移除**：它落在屏幕下三分之一，
    /// 每个页面底部都会糊一片暖色，跟「冷灰蓝底 + 玻璃」的基调打架。别加回来。
    static let auraCyan = Color(hex: 0xA5E8F5)

    // MARK: 玻璃（`.v2-card` / `.card` 的五个值）
    static let glassFill       = Color.white.opacity(0.55)
    static let glassEdge       = Color.white.opacity(0.90)
    static let glassEdgeStrong = Color.white.opacity(0.95)
    static let glassHighlight  = Color.white.opacity(0.60)
    static let glassShadow     = Color(hex: 0x4A5778).opacity(0.12)

    // MARK: 图表（出处：`index-v2.html` 1893–1928、1857–1865）
    /// 里程柱：`linear-gradient(180deg,#7EDCEE,#B9A5FF)`
    static let barMileageTop    = Color(hex: 0x7EDCEE)
    static let barMileageBottom = Color(hex: 0xB9A5FF)
    /// 电耗柱 · 动态段在下：`#FFD49A → #F99FB8`
    static let barDynTop    = Color(hex: 0xFFD49A)
    static let barDynBottom = Color(hex: 0xF99FB8)
    /// 电耗柱 · 静态段在上：`#B9A5FF → #8E7BFF`
    static let barStatTop    = Color(hex: 0xB9A5FF)
    static let barStatBottom = Color(hex: 0x8E7BFF)
    /// 缺数据虚线槽：`rgba(27,34,51,.035)` 底 + `rgba(27,34,51,.2)` 虚线边
    static let placeholderFill   = Color(hex: 0x1B2233).opacity(0.035)
    static let placeholderStroke = Color(hex: 0x1B2233).opacity(0.20)
    /// 点柱气泡底：`rgba(23,28,44,.90)`
    static let tipBackground = Color(hex: 0x171C2C).opacity(0.90)
    /// Skeleton 条：`rgba(255,255,255,.55)`
    static let skeletonFill = Color.white.opacity(0.55)

    // ── OCR 核对框（出处：index-v2.html 1143–1220）──────────────
    /// 「需核对 / 请重新选」文字 `#A8791A`
    static let ocrWarnText = Color(hex: 0xA8791A)
    /// 同上底 `rgba(242,153,74,.16)`
    static let ocrWarnFill = Color(hex: 0xF2994A).opacity(0.16)
    /// 置信度胶囊 `#08789F` on `#E9F6FD`
    static let confText = Color(hex: 0x08789F)
    static let confFill = Color(hex: 0xE9F6FD)
    /// 输入框底 `rgba(27,34,51,.04)`
    static let inputFill = Color(hex: 0x1B2233).opacity(0.04)
    /// 淡紫胶囊按钮底 `#EEF0FE`
    static let chipFill = Color(hex: 0xEEF0FE)
    /// `--glass-inner-2`（v2 覆盖值）= 白 45%，用于 `.ocr-row` 与「取消」按钮
    static let softFill = Color.white.opacity(0.45)
}

// MARK: - 字体

/// Inter 的四个静态字重 —— 全部按 **PostScript 名**引用。
///
/// 为什么不用 `Font.custom("Inter", size:)` + `.weight(...)`：
/// 后者让 CoreText 按 OS/2 `usWeightClass` 猜最相近的 face。猜错是**静默**的——
/// 界面看起来「好像也对」，但字宽和 HTML 版对不上，而我在没有真机的环境下
/// 根本发现不了。PS 名是确定性的，猜不了。
///
/// 为什么是静态实例而不是可变字体：iOS 的 SwiftUI 没有可变字体的字重轴入口。
/// 四个文件（400/500/600/700）由 `preview/fonts/Inter-Variable.woff2` 实例化而来，
/// v2 CSS 里出现过一次的 `font-weight: 650` 归到 600（HTML 注释明确写了）。
enum V2Font {
    static let regular  = "Inter-Regular"
    static let medium   = "Inter-Medium"
    static let semiBold = "Inter-SemiBold"
    static let bold     = "Inter-Bold"
}

// MARK: - 排版

/// 一条排版规格：字号 + 字重（PS 名）+ 行高 + 字距。
///
/// 四者**必须绑在一起**给：只换字体不换行高字距，就会出现「字对了但行高散了」——
/// 这是本次替换最大的隐性风险，所以把它们封在同一处，调用方不许自己拼。
struct V2Type {
    let size: CGFloat
    let name: String
    let lineHeight: CGFloat
    let tracking: CGFloat

    private init(_ size: CGFloat, _ name: String, _ lineHeight: CGFloat, _ tracking: CGFloat) {
        self.size = size
        self.name = name
        self.lineHeight = lineHeight
        self.tracking = tracking
    }

    var font: Font { Font.custom(name, size: size) }

    /// 按字号等比缩放 —— 给「字号随容器尺寸变化」的场合（如 SOC 环内数字）。
    /// 行高与字距一起缩放，比例才不会散。
    func scaled(_ factor: CGFloat) -> V2Type {
        V2Type(size * factor, name, lineHeight * factor, tracking * factor)
    }
    /// 整体微调：字号与行高同时 +delta（默认 1pt），字距不动。
    ///
    /// 为什么不用 scaled()：那张表是照 HTML 真源 1:1 抄的，比例缩放会让
    /// 11pt 的小字几乎不动、34pt 的大数却涨 3pt，页内层级关系就歪了。
    /// 加法式微调只把整体观感抬一档，「谁比谁大多少」保持不变。
    func bumped(_ delta: CGFloat = 1) -> V2Type {
        V2Type(size + delta, name, lineHeight + delta, tracking)
    }

    /// 补到 CSS `line-height` 还差多少。
    ///
    /// SwiftUI 没有 CSS 那种「行高」概念：`.lineSpacing()` 是在**字形自然行高之上**
    /// 再加一段。Inter 的自然行高约 1.2em，所以差值 = 目标行高 − 1.2 × 字号。
    /// 目标比自然行高还矮时（如 26/31）只能取 0 —— 强行压会切掉字形。
    ///
    /// ⚠️ 这是**近似**，精确值要真机校准。已记录在 `docs/C档实施报告.md` 的已知差异里。
    var lineSpacing: CGFloat { max(0, lineHeight - size * 1.2) }
}

extension V2Type {
    // ── 车况屏（出处：index-v2.html 1725–1794）──────────────────
    /// SOC 环内大数字：26 / 700 / 31 / −0.4（`.v2-ring-txt b`）
    static let hero26  = V2Type(26, V2Font.bold, 31, -0.4)
    /// 卡片标题 14 / 600 / 20（`.v2-tyre-head .t`、`.v2-status-head`、`.v2-loc-head .t`）
    static let title14 = V2Type(14, V2Font.semiBold, 20, 0)
    /// 主数值 15 / 600 / 22（`.v2-kv`）
    static let body15  = V2Type(15, V2Font.semiBold, 22, 0)
    /// 副数值 14 / 400 / 20（`.v2-kv.sub`）
    static let body14  = V2Type(14, V2Font.regular, 20, 0)
    /// 格子数值 16 / 600 / 22（`.v2-metric .v`、`.v2-tyre-col .v`、`.v2-charge-col b`）
    static let num16   = V2Type(16, V2Font.semiBold, 22, 0)
    /// 正文 13 / 400 / 19（`.v2-loc-addr`）
    static let text13  = V2Type(13, V2Font.regular, 19, 0)
    /// 说明行 12 / 500 / 16（`.v2-eta`）
    static let text12  = V2Type(12, V2Font.medium, 16, 0)
    /// 状态项 12 / 500 / 15（`.v2-status-item`）
    static let item12  = V2Type(12, V2Font.medium, 15, 0)
    /// 小标签 11 / 500 / 14（`.v2-metric .k`、`.v2-loc-head .time`）
    static let label11 = V2Type(11, V2Font.medium, 14, 0)
    /// 胶囊文字 11 / 600 / 14（`.v2-plate`）
    static let chip11  = V2Type(11, V2Font.semiBold, 14, 0)
    /// 页脚 / 更新时间 11 / 500 / 16（`.v2-updated`）
    static let note11  = V2Type(11, V2Font.medium, 16, 0)

    // ── 通用（出处：`.v2-title`、`.v2-month-chip`）──────────────
    /// 大标题 28 / 700 / 34 / −0.4
    static let title28 = V2Type(28, V2Font.bold, 34, -0.4)
    /// 月份胶囊 13 / 600 / 16
    static let month13 = V2Type(13, V2Font.semiBold, 16, 0)

    // ── 行程屏（出处：index-v2.html 1820–1928）──────────────────
    /// 汇总格标题 11 / 500 / 14（`.v2-sum-cell .k`、`.u`）
    static let sumKey  = V2Type(11, V2Font.medium, 14, 0)
    /// 汇总格数值 16 / 600 / 22（`.v2-sum-cell .v`，与 `num16` 同规格）
    static let sumValue = V2Type(16, V2Font.semiBold, 22, 0)
    /// 分段控件文字 12 / 500（`.v2-seg button`，无 line-height 声明，按 1.5 取值）
    static let segLabel = V2Type(12, V2Font.medium, 18, 0)
    /// 分段控件选中 12 / 600（`.v2-seg button.on`）
    static let segLabelOn = V2Type(12, V2Font.semiBold, 18, 0)
    /// 图表图例 10 / 500 / 14（`.v2-leg`）
    static let legLabel = V2Type(10, V2Font.medium, 14, 0)
    /// 坐标轴刻度 10 / 500 / 13（`.v2-yaxis span`、`.v2-bar .vt`）
    static let axis10 = V2Type(10, V2Font.medium, 13, 0)
    /// X 轴标签 11 / 500 / 16（`.v2-xaxis span`）
    static let xAxis11 = V2Type(11, V2Font.medium, 16, 0)
    /// 气泡文字 11 / 500 / 15（`.v2-chart-tip`）
    static let tip11 = V2Type(11, V2Font.medium, 15, 0)
    /// 空态标题 16 / 600 / 22（`.v2-empty .t`）
    static let emptyTitle = V2Type(16, V2Font.semiBold, 22, 0)
    /// 空态说明 12 / 400 / 18（`.v2-empty .d`，注意是 400 不是 500）
    static let emptyDesc = V2Type(12, V2Font.regular, 18, 0)
    /// 登录墙说明 12.5 / 400 / 18（`.v2-wall-d`）
    static let wallDesc = V2Type(12.5, V2Font.regular, 18, 0)
    /// 主按钮文字 14 / 600（`.v2-wall-btn`、`.v2-empty .btn`）
    static let button14 = V2Type(14, V2Font.semiBold, 20, 0)

    // ── 充电屏（出处：index-v2.html 1948–1990）──────────────────
    /// 大数字 34 / 700 / 38（`.v2-cc-hero`）
    static let hero34 = V2Type(34, V2Font.bold, 38, 0)
    /// 金额 19 / 600 / 26（`.v2-cc-amt`）
    static let amt19 = V2Type(19, V2Font.semiBold, 26, 0)
    /// 辅助数字 14 / 500 / 20（`.v2-cc-total`、`.v2-cc-hero .v2-u`）
    static let body14m = V2Type(14, V2Font.medium, 20, 0)
    /// 统计行 15 / 500 / 22（`.v2-cc-stats`）
    static let stat15 = V2Type(15, V2Font.medium, 22, 0)
    /// 补录说明 11 / 500 / 17（`.v2-cost-note`）
    static let note11b = V2Type(11, V2Font.medium, 17, 0)
    // ── 设置页（出处：index-v2.html 1517–1525）──────────────
    /// 车名 16 / 600 / 21（`.v2-set-nm`，line-height 1.3）
    static let setName16 = V2Type(16, V2Font.semiBold, 21, 0)
    /// 车牌 13 / 500 / 17（`.v2-set-pl`）
    static let setSub13 = V2Type(13, V2Font.medium, 17, 0)
    /// 行副标题 12 / 500 / 16（`.v2-set-t2`）
    static let setRowT2 = V2Type(12, V2Font.medium, 16, 0)
    /// 行标签 / 行值 13 / 500 / 19（设置页表单行，HTML 的 `.v2-set-k` 同字号但行高 17）
    static let text13m = V2Type(13, V2Font.medium, 19, 0)
    /// 权限 chip 12.5 / 500 / 17（`.v2-set-grants .v2-set-chip`）
    static let grantChip = V2Type(12.5, V2Font.medium, 17, 0)
    // ── OCR 核对弹层（出处：index-v2.html 1186–1215）──────────
    /// 候选行 12.5 / 500 / 18（`.ocr-cand`）
    static let ocrCand = V2Type(12.5, V2Font.regular, 18, 0)
    /// 候选行选中 12.5 / 600 / 18（`.ocr-cand.on`）
    static let ocrCandOn = V2Type(12.5, V2Font.semiBold, 18, 0)
    /// 候选行右侧 11.5 / 500 / 16（`.ocr-cand .c-side`）
    static let ocrSide = V2Type(11.5, V2Font.medium, 16, 0)
    /// 「已补录」胶囊 10.5 / 500 / 14（`.ocr-cand .c-dup`）
    static let dupBadge = V2Type(10.5, V2Font.medium, 14, 0)
    /// 主标题 16 / 600 / 22（`.ocr-title`）
    static let ocrTitle16 = V2Type(16, V2Font.semiBold, 22, 0)
    /// 副标题 / 说明 12 / 400 / 18（`.ocr-sub`、`.ocr-nocand .d`）
    static let ocrSub12 = V2Type(12, V2Font.regular, 18, 0)
    /// 行头左侧 12 / 400（`.ocr-row-top`）
    static let ocrRowTop12 = V2Type(12, V2Font.regular, 17, 0)
    /// 行头站名 13 / 600（`.ocr-row-top b`）
    static let ocrStation13 = V2Type(13, V2Font.semiBold, 18, 0)
    /// 置信度 11 / 500 / 14（`.ocr-conf`）
    static let ocrConf11 = V2Type(11, V2Font.medium, 14, 0)
    /// 黄条 11.5 / 400 / 17（`.ocr-warn`，行高 1.45）
    static let ocrWarn115 = V2Type(11.5, V2Font.regular, 17, 0)
    /// 字段标签 10.5 / 400 / 15（`.ocr-field label`）
    static let ocrLabel105 = V2Type(10.5, V2Font.regular, 15, 0)
    /// 输入框文字 14 / 400 / 20（`.ocr-input`）
    static let ocrInput14 = V2Type(14, V2Font.regular, 20, 0)
    /// 输入框单位 12 / 400 / 18（`.ocr-unit`）
    static let ocrUnit12 = V2Type(12, V2Font.regular, 18, 0)
    /// 无候选标题 14 / 600 / 20（`.ocr-nocand .t`）
    static let nocandT14 = V2Type(14, V2Font.semiBold, 20, 0)
    /// 底部主按钮 15 / 600 / 20（`.ocr-primary`、`.sheet-cancel`）
    static let ocrPrimary15 = V2Type(15, V2Font.semiBold, 20, 0)
    /// 胶囊小按钮 14 / 600 / 20（`.ocr-act`）
    static let ocrAct14 = V2Type(14, V2Font.semiBold, 20, 0)
    /// 主按钮 15 / 600 / 20（`.v2-set-out`、`.ocr-primary`）
    static let btn15 = V2Type(15, V2Font.semiBold, 20, 0)
    /// 低电量角标 10 / 600 / 14（SOC 环下的「电量偏低」）
    static let alert10 = V2Type(10, V2Font.semiBold, 14, 0)
    /// 原生 sheet 的导航按钮 15 / 400 / 20（月份选择器的「取消 / 确定」）
    static let nav15 = V2Type(15, V2Font.regular, 20, 0)
    /// Toast 12.5 / 400 / 18（`.toast`，HTML 只给了 font-size，未声明字重即 400）
    static let toast12 = V2Type(12.5, V2Font.regular, 18, 0)
    /// 状态胶囊 13 / 600 / 18（`.v2-badge-ok` / `.v2-badge-off`）
    static let badge13 = V2Type(13, V2Font.semiBold, 18, 0)
    /// 页脚 11 / 400 / 16（`.v2-foot`，注意是 400 不是 500）
    static let foot11 = V2Type(11, V2Font.regular, 16, 0)
    /// 站点名 13 / 600 / 19（`.v2-st-h .n`）
    static let recName13 = V2Type(13, V2Font.semiBold, 19, 0)
    /// 行内标签/正文 12 / 500 / 18（`.v2-cc-line .v2-k`、`.v2-rec-top .t`、`.v2-rec-bot .s`）
    static let label12 = V2Type(12, V2Font.medium, 18, 0)

    // ── 确认弹框（出处：index-v2.html 2118–2125 的 `.v2-alert`）──────────
    /// 标题 16 / 600 / 22（行高 1.35×16 = 21.6）
    static let alertTitle16 = V2Type(16, V2Font.semiBold, 22, 0)
    /// 说明 12.5 / 400 / 19（行高 1.5×12.5 = 18.75）
    static let alertMsg = V2Type(12.5, V2Font.regular, 19, 0)
    /// 按钮文字 13 / 600 / 18（`.v2-alert .acts .v2-btn` 覆盖了 `.v2-btn` 的 12 号）
    static let alertBtn = V2Type(13, V2Font.semiBold, 18, 0)

    // ── 充电站 sheet 列表（出处：index-v2.html 2157–2181 的 `.v2-sheet-list` 覆盖块）──
    //
    // ⚠️ 这一组是**覆盖值**，不是 :649-720 那套旧的 `.st` 基础样式。
    // 旧的 .st-name 是 15 号、价格 15 号；v2 在文件末尾用同样的选择器整体压小到 13/11，
    // 因为 sheet 是半屏浮层、信息密度要高于整页卡片。照旧样式写就会「整体大一号」。
    /// 站名 / 价格 13 / 600 / 17.5（`.st-name`、`.st-price`，line-height 1.35）
    static let stName13  = V2Type(13, V2Font.semiBold, 17.5, 0)
    /// 价格单位 11 / 500 / 15（`.st-price .u`）
    static let stUnit11  = V2Type(11, V2Font.medium, 15, 0)
    /// 元信息行 11 / 500 / 16.5（`.st-meta`，line-height 1.5）
    static let stMeta11  = V2Type(11, V2Font.medium, 16.5, 0)
    /// 自营徽章 10 / 500 / 13.5（`.st-tag`，1px 6px 内边距 + 999 圆角）
    static let stTag10   = V2Type(10, V2Font.medium, 13.5, 0)
    /// 分时电价行 11 / 500 / 16（`.st-period`，高 22）
    static let stPeriod11 = V2Type(11, V2Font.medium, 16, 0)
    /// 分时电价·当前段 11 / 600 / 16（`.st-period.now`，高 24、底色 #E9F6FD）
    static let stPeriodNow11 = V2Type(11, V2Font.semiBold, 16, 0)
    /// 详情信息行 11 / 500 / 16（`.st-info-l`，line-height 1.45）
    static let stInfo11  = V2Type(11, V2Font.medium, 16, 0)
    /// 备注行 11 / 500 / 16.5（`.st-note`，line-height 1.5、色 #6B7484）
    static let stNote11  = V2Type(11, V2Font.medium, 16.5, 0)
    /// 「导航到这里」13 / 600 / 18（`.st-btn`，44 高、12 圆角、全宽）
    static let stBtn13   = V2Type(13, V2Font.semiBold, 18, 0)
    /// 收起态推荐标签 10 / 600 / 14（`.v2-st-pick`：1px 6px、999 圆角、accent 字 on chipFill）
    static let pickTag10 = V2Type(10, V2Font.semiBold, 14, 0)
    /// 收起态小按钮 11 / 600 / 16（`.v2-btn.sm` 覆盖 `.v2-btn` 的 12/18：4px 10px 内边距）
    static let navSm11   = V2Type(11, V2Font.semiBold, 16, 0)
}

extension View {
    /// 套用一条 v2 排版规格（字号 + 字重 + 行高 + 字距 + 颜色一起给）。
    func v2Text(_ style: V2Type, color: Color = V2Color.text1) -> some View {
        self.font(style.font)
            .tracking(style.tracking)
            .lineSpacing(style.lineSpacing)
            .foregroundStyle(color)
    }

    /// 数字等宽：轮询刷新时数位变化不该让整行左右抖。
    ///
    /// Inter 的 `tnum` 特性在四个子集里都保留了（实测 GSUB 含 `tnum`），
    /// `.monospacedDigit()` 取的就是它 —— 不需要自己摆空格。
    func v2Numeric() -> some View { self.monospacedDigit() }
}

// MARK: - 度量

enum V2Metrics {
    /// 卡片圆角（`.v2-card`）
    static let cardRadius: CGFloat = 20
    /// 卡片内边距（`.v2-card`）
    static let cardPadding: CGFloat = 16
    /// 屏幕左右边距（`.wrap`）
    static let screenPadding: CGFloat = 16
    /// 屏幕纵向卡片间距（`.v2-screen` gap）
    static let screenGap: CGFloat = 16
    /// 车况屏例外：唯一 gap 12 的屏（`.v2-screen.v2-dash`）
    static let dashGap: CGFloat = 12

    /// 卡片外阴影的 SwiftUI `radius`。
    ///
    /// CSS 写的是 `0 8px 24px`，但 SwiftUI 的 `radius` 不等于 CSS 的 blur：
    /// CSS 的模糊向外扩展约 blur/2，SwiftUI 的 `radius` 就是扩展量本身。
    /// 所以这里取 12 而不是照抄 24。**这是一个待真机校准的值** ——
    /// 若真机上阴影显得过重/过轻，只改这一个常量即可（已在实施报告里登记）。
    static let cardShadowRadius: CGFloat = 12

    /// 底部胶囊：348×62 r36，5 项各 62×54，图标 24，文字 11/500
    ///
    /// 选中与未选中**只有颜色不同**，字重都是 Medium —— 早期版本用 SemiBold，已改回。
    static let tabBarHeight: CGFloat = 62
    static let tabBarRadius: CGFloat = 36
    static let tabItemWidth: CGFloat = 62
    static let tabItemHeight: CGFloat = 54
    static let tabIconSize: CGFloat = 24
    static let tabItemGap: CGFloat = 4.5
    /// 底栏胶囊两侧留白。**实测 21**（`.tabbar{padding:12px 21px 14px}`，
    /// 390 − 21×2 = 348 正好等于胶囊宽度）；任务书 3.1 写的 14 是 v1 预览页的值。
    static let tabBarSideInset: CGFloat = 21
    /// 内容末端与胶囊上沿之间的间隙。
    ///
    /// 29 = 网页 `.wrap{padding-bottom:105}` − 胶囊总高 76，静止位置与网页一致。
    static let tabBarContentGap: CGFloat = 29
    /// 胶囊下沿距**屏幕物理底边**的留白，= 网页 `.tabbar{padding: 12px 21px 14px}` 的 14。
    ///
    /// 早先这里取 22（照系统电话 app 量出来的 21.7），但它是靠
    /// `safeAreaBar(edge: .bottom)` 承载的 —— 那个 API 把 bar 摆在**安全区上沿**，
    /// 于是实际下沿 = 22 + 34（底部安全区）= 56pt，真机上看着「离屏幕底很远」。
    /// 现在改由 `RootView` 的 `.overlay(alignment: .bottom)` 直接锚在物理底边，
    /// 数值也就回到网页真源：14。Home Indicator 白条约占距底 8–13pt，14 仍在其上方。
    static let tabBarBottomGap: CGFloat = 14
    /// 页面内容滚到底时，底部需要留出的总高度 = 下留白 + 胶囊高 + 胶囊与内容的间隙。
    /// 105 = 14 + 62 + 29，与网页 `.wrap{padding-bottom:105px}` 逐像素一致。
    /// 由 `ScreenContainer` 用 `.contentMargins(.bottom,for:.scrollContent)` 消费。
    static var tabBarClearance: CGFloat { tabBarBottomGap + tabBarHeight + tabBarContentGap }

    /// 顶栏固定高度。
    ///
    /// 之前这里随内容变（数据来源胶囊 22 → 38，月份胶囊 32 → 48），
    /// 导致**车况/车控/设置的首卡比行程/充电高 10pt**。HTML 的 `.v2-head`
    /// 是绝对定位不占流，四屏首卡都从 64 起；iOS 有状态栏（59）无法照搬 64，
    /// 但至少可以把这一行做成定高，四屏一致。
    static let topBarHeight: CGFloat = 36
    /// 月份胶囊：min-width 100 / height 32 / r14 / padding 0 14
    static let monthChipHeight: CGFloat = 32
    static let monthChipRadius: CGFloat = 14
    static let monthChipMinWidth: CGFloat = 100

    // MARK: 行程屏图表（出处：index-v2.html 1839–1928）

    /// 柱圆角 4（`.v2-bar .b{border-radius:4px}`）
    static let barRadius: CGFloat = 4
    /// 分段控件 108×30、内距 3、圆角 15（`.v2-seg`）
    static let segWidth: CGFloat = 108
    static let segHeight: CGFloat = 30
    static let segInset: CGFloat = 3
    static let segRadius: CGFloat = 15
    static let segThumbRadius: CGFloat = 12
    /// 汇总卡行距 14 / 列距 12（`.v2-sum-grid{gap:14}` / `.v2-sum-row{gap:12}`）
    static let sumRowGap: CGFloat = 14
    static let sumColGap: CGFloat = 12
}
