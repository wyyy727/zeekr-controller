//
//  V2BarChart.swift
//  ZeekrDash
//
//  自绘柱状图（行程屏两张图共用）
//
//  为什么不用 Swift Charts：HTML 的 v2Chart()（`index-v2.html:4138-4301`）是 pt 级规格 ——
//  柱宽/节距、横向滚动、点柱气泡、双图联动、滚动跟随选中、缺数据虚线占位、逐根错峰入场，
//  这七项全在 Charts 的数据模型之外。硬套只会变成「Charts 画底 + 自绘覆盖层」，
//  两套坐标系对不齐，反而更容易错。这里把 HTML 的数值直接搬过来自己画。
//
//  规格出处逐条标在常量旁边，改动前回 HTML 核对。
//

import SwiftUI
import UIKit

// MARK: - 数据点

/// 一根柱需要的全部信息。
///
/// `dynamic` / `staticPart` 只有电耗图给：HTML 把电耗柱拆成「动态在下、静态在上」两段
/// （`v2BarBody()`，4162–4177），里程图没有拆分，两者都为 nil 时退回单色柱。
struct V2ChartPoint: Identifiable, Equatable {
    var id: Int
    var value: Double?
    var dynamic: Double?
    var staticPart: Double?
    /// X 轴标签：7 天是「9」，30 天是「10/9」
    var label: String
    /// 气泡里的完整日期「10/9」
    var full: String
}

// MARK: - 柱状图

/// 一张图表卡（`.v2-chart-card`，1852 行）。
///
/// 两张图共用同一个 `offset` 与 `selection`：横向滑动任一张，另一张跟着走；
/// 点任一根柱，两张图同一天的柱子一起高亮 —— 否则对照「这天跑了多少、耗了多少」
/// 得来回点两次。
struct V2BarChart: View {

    enum Kind {
        case mileage
        case energy
    }

    let title: String
    let points: [V2ChartPoint]
    /// 7 或 30（历史月份固定 30）
    let days: Int
    let decimals: Int
    let unit: String
    let kind: Kind
    let animate: Bool
    /// 第二张图的整卡入场延后（HTML `--base: 120ms`）
    var baseDelay: Double = 0

    @Binding var selection: Int
    @Binding var offset: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var grown = false
    @State private var cardWidth: CGFloat = 0
    /// 首次拿到卡片宽度后把偏移推到最右（HTML 6724 行：默认停在最右，先看最新几天）
    @State private var didInitOffset = false

    // MARK: 规格常量（全部来自 index-v2.html）

    private var isD30: Bool { days != 7 }

    /// 柱宽：7 天 26 / 30 天 20（`.v2-bar{width:26}` / `.v2-bars.d30 .v2-bar{width:20}`）
    private var barW: CGFloat { isD30 ? 20 : 26 }
    /// 节距：7 天 56（26+30）/ 30 天 32（20+12）
    private var pitch: CGFloat { isD30 ? 32 : 56 }
    /// 绘图区高：`.v2-bars{height:132}` / `.v2-bars.d30{height:120}`
    private var barsH: CGFloat { isD30 ? 132 - 12 : 132 }
    /// 柱体可用高：132 − 数值行 13 − gap 4 − 余量 3 = 112；30 天无数值行 = 120
    private var avail: CGFloat { isD30 ? 120 : 112 }
    /// 柱顶数值行高（`.v2-bar .vt{height:13px}`）
    private var vtH: CGFloat { 13 }
    /// 柱与柱之间的缝
    private var gap: CGFloat { pitch - barW }
    /// 数值行与柱之间的 gap（`.v2-bar{gap:4}`）
    private let barInnerGap: CGFloat = 4

    /// 内容宽 = n×柱宽 + (n−1)×缝（4169 行 `width`）
    private var contentWidth: CGFloat {
        max(barW, CGFloat(points.count) * pitch - gap)
    }

    /// 绘图区可视宽 = 卡片内宽 − 左右内距 − Y 轴 30 − 行 gap 8
    private var viewportW: CGFloat {
        max(0, cardWidth - V2Metrics.cardPadding * 2 - yAxisW - rowGap)
    }
    private let yAxisW: CGFloat = 30
    private let rowGap: CGFloat = 8

    private var maxOffset: CGFloat { max(0, contentWidth - viewportW) }

    // MARK: 刻度

    /// 刻度四档：max / ⅔max / ⅓max / 0（4110 行 `v2NiceMax`）
    private var niceMax: Double {
        let values = points.compactMap(\.value)
        return Self.niceMax(values.max() ?? 0)
    }

    private var ticks: [String] {
        let m = niceMax
        return [m, m * 2 / 3, m / 3, 0].map { Self.tickText($0, max: m) }
    }

    static func niceMax(_ v: Double) -> Double {
        guard v > 0, v.isFinite else { return 1 }
        let mag = pow(10, floor(log10(v)))
        for m in [1.0, 1.5, 2.0, 2.5, 3.0, 4.0, 5.0, 6.0, 8.0, 10.0] {
            if m * mag >= v { return (m * mag * 100).rounded() / 100 }
        }
        return 10 * mag
    }

    /// `Number.isInteger(r) || max >= 10 ? String(Math.round(r)) : r.toFixed(1)`
    static func tickText(_ t: Double, max m: Double) -> String {
        let r = (t * 10).rounded() / 10
        if r == r.rounded() || m >= 10 { return String(Int(r.rounded())) }
        return String(format: "%.1f", r)
    }

    /// 柱高：`max(2, round(v / max * avail))`；缺数据 = 0（改画虚线占位）
    private func barHeight(_ v: Double?) -> CGFloat {
        guard let v, v.isFinite else { return 0 }
        return max(2, (v / niceMax * Double(avail)).rounded())
    }

    // MARK: - 视图

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            head
            HStack(alignment: .top, spacing: rowGap) {
                yAxis
                plot
            }
        }
        .padding(V2Metrics.cardPadding)
        .background(
            RoundedRectangle(cornerRadius: V2Metrics.cardRadius, style: .continuous)
                .fill(V2Color.glassFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: V2Metrics.cardRadius, style: .continuous)
                .strokeBorder(V2Color.glassEdge, lineWidth: 1)
        )
        .overlay(highlight)
        .background(widthReader)
        .shadow(
            color: V2Color.glassShadow,
            radius: V2Metrics.cardShadowRadius,
            x: 0,
            y: 8
        )
        .overlay(alignment: .topLeading) { tipLayer }
        .onAppear(perform: startAnimation)
        // 横滑时选中跟到视口中心那根柱（HTML `onChartScroll`，且只在已选中时跟）
        .onChange(of: offset) { _, _ in followSelection() }
        // 数据换了（切月份）：HTML 每次 render 都把横向滚动推到最右，
        // 但**不重播**入场动画（那由父视图的 `.id` 控制），所以这里只挪位置
        .onChange(of: points) { _, _ in
            guard cardWidth > 0 else { return }
            offset = maxOffset
        }
    }

    /// 卡片标题行：标题 + 图例（有拆分数据才显示）
    private var head: some View {
        HStack(spacing: 8) {
            Text(title)
                .v2Text(.title14)
            Spacer(minLength: 0)
            if points.contains(where: { $0.dynamic != nil }) {
                HStack(spacing: 5) {
                    Text("动态")
                    legendChip(top: V2Color.barDynTop, bottom: V2Color.barDynBottom)
                        .padding(.leading, 6)
                    Text("静态")
                    legendChip(top: V2Color.barStatTop, bottom: V2Color.barStatBottom)
                }
                .v2Text(.legLabel, color: V2Color.text3)
            }
        }
        .frame(height: 20)
    }

    private func legendChip(top: Color, bottom: Color) -> some View {
        RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(LinearGradient(colors: [top, bottom], startPoint: .top, endPoint: .bottom))
            .frame(width: 8, height: 8)
    }

    /// Y 轴四档。
    ///
    /// HTML 的 `.v2-yaxis` 没有高度，被 flex 拉伸到「柱区 + X 轴」的总高（148pt），
    /// 于是「0」的**中线落在柱底下方 9.5pt**；而 30 天视图作者显式写了
    /// `.v2-yaxis.d30{height:120px}`，此时「0」中线在柱底**上方** 6.5pt（正常轴标签观感）。
    /// 也就是说 7 天那个偏移是漏写，不是设计。这里两种视图都按 30 天的口径对齐柱底。
    /// 实测数据见 `docs/C档实施报告.md` 的已知差异 #5。
    private var yAxis: some View {
        VStack(alignment: .trailing, spacing: 0) {
            ForEach(Array(ticks.enumerated()), id: \.offset) { index, text in
                Text(text)
                    .v2Text(.axis10, color: V2Color.text3)
                    .v2Numeric()
                if index < ticks.count - 1 { Spacer(minLength: 0) }
            }
        }
        .frame(width: yAxisW, height: barsH)
    }

    private var plot: some View {
        /* 柱区与 X 轴之间**没有间距**。
           CSS 里 `.v2-plot{gap:4px}` 只作用于它的直接子元素，而它只有一个子元素
           （`.v2-chart-scroll` 包住了柱区和 X 轴），所以那 4px 实际不生效。
           实测：柱区 bottom 与 X 轴 top 同为 177（无头 Edge 量的），照 4 写会高 4pt。 */
        VStack(alignment: .leading, spacing: 0) {
            barsRow
            xAxis
        }
        .frame(width: viewportW, alignment: .leading)
        .clipped()
        // 真正的 UIScrollView 只在最上层接手势：原生惯性 + 与另一张图逐像素同步
        .overlay {
            HScrollDriver(
                offset: $offset,
                contentWidth: contentWidth,
                onTap: handleTap
            )
        }
    }

    private var barsRow: some View {
        HStack(alignment: .bottom, spacing: gap) {
            ForEach(points) { point in
                barView(point)
            }
        }
        .frame(width: contentWidth, height: barsH, alignment: .leading)
        .offset(x: -offset)
    }

    private var xAxis: some View {
        HStack(alignment: .top, spacing: gap) {
            ForEach(points) { point in
                Text(axisLabel(point))
                    .v2Text(.xAxis11, color: V2Color.text3)
                    // 30 天格位只有 20pt 宽而「10/9」约 24pt：HTML 是 `white-space:nowrap`
                    // 溢出显示，SwiftUI 侧用 fixedSize 保留自然宽度，靠 frame 居中
                    .fixedSize()
                    .frame(width: barW, alignment: .center)
            }
        }
        .frame(width: contentWidth, height: 16, alignment: .leading)
        .offset(x: -offset)
    }

    /// 30 天每 3 格标一个（`step = round(n/10)`，4180 行）
    private func axisLabel(_ point: V2ChartPoint) -> String {
        guard isD30 else { return point.label }
        let n = points.count
        let step = max(1, Int((Double(n) / 10).rounded()))
        let k = point.id
        return (k % step == 0 && Double(k) < Double(n) - Double(step) / 2) ? point.label : ""
    }

    // MARK: 单根柱

    private func barView(_ point: V2ChartPoint) -> some View {
        let h = barHeight(point.value)
        // 缺数据画 8pt 虚线空槽（`.v2-bar .b.ph{height:8px}`），不是 0
        let targetH: CGFloat = point.value == nil ? 8 : h
        let selected = selection == point.id && point.value != nil
        let delay = stagger(point.id) + baseDelay

        return VStack(spacing: barInnerGap) {
            if !isD30 {
                // 柱顶数值：7 天直接画在柱上（30 天靠点柱气泡）
                Text(valueLabel(point.value))
                    .v2Text(.axis10, color: V2Color.text3)
                    .v2Numeric()
                    .frame(height: vtH)
                    .opacity(grown ? 1 : 0)
                    .animation(labelAnimation(delay), value: grown)
            }

            barBody(point, height: h)
                .frame(width: barW, height: grown ? targetH : 0, alignment: .bottom)
                .animation(barAnimation(delay), value: grown)
                .overlay(alignment: .center) {
                    if selected {
                        RoundedRectangle(cornerRadius: V2Metrics.barRadius + 2, style: .continuous)
                            .strokeBorder(V2Color.accent.opacity(0.50), lineWidth: 2)
                            .padding(-2)
                    }
                }
        }
        .frame(width: barW, height: barsH, alignment: .bottom)
        .accessibilityElement()
        .accessibilityLabel("\(point.full) \(point.value.map { "\(valueLabel($0)) \(unit)" } ?? "无数据")")
    }

    /// 柱体：缺数据 → 虚线空槽；有动态/静态拆分 → 上下两段；否则单色柱。
    @ViewBuilder
    private func barBody(_ point: V2ChartPoint, height h: CGFloat) -> some View {
        if point.value == nil {
            // `.v2-bar .b.ph`：高 8、虚线框 —— 不画会让图表「跳日」
            RoundedRectangle(cornerRadius: V2Metrics.barRadius, style: .continuous)
                .fill(V2Color.placeholderFill)
                .overlay(
                    RoundedRectangle(cornerRadius: V2Metrics.barRadius, style: .continuous)
                        .strokeBorder(
                            V2Color.placeholderStroke,
                            style: StrokeStyle(lineWidth: 1, dash: [3, 3])
                        )
                )
                .frame(height: 8)
        } else if let d = point.dynamic, let s = point.staticPart, d + s > 0 {
            splitBody(d: d, s: s, height: h)
                .frame(height: h)
                .clipShape(RoundedRectangle(cornerRadius: V2Metrics.barRadius, style: .continuous))
        } else {
            RoundedRectangle(cornerRadius: V2Metrics.barRadius, style: .continuous)
                .fill(singleGradient)
                .frame(height: h)
        }
    }

    /// 静态在上、动态在下；静态段最少 2pt，否则 0.2 kWh 在 112pt 绘图区里看不见
    private func splitBody(d: Double, s: Double, height h: CGFloat) -> some View {
        let total = d + s
        var hs: CGFloat = s > 0 ? (s / total * Double(h)).rounded() : 0
        hs = s > 0 ? max(2, min(h - 1, hs)) : 0
        let hd = h - hs

        return VStack(spacing: 0) {
            if hs > 0 {
                Rectangle()
                    .fill(LinearGradient(
                        colors: [V2Color.barStatTop, V2Color.barStatBottom],
                        startPoint: .top, endPoint: .bottom
                    ))
                    .frame(height: hs)
            }
            if hd > 0 {
                Rectangle()
                    .fill(LinearGradient(
                        colors: [V2Color.barDynTop, V2Color.barDynBottom],
                        startPoint: .top, endPoint: .bottom
                    ))
                    .frame(height: hd)
            }
        }
    }

    private var singleGradient: LinearGradient {
        switch kind {
        case .mileage:
            return LinearGradient(
                colors: [V2Color.barMileageTop, V2Color.barMileageBottom],
                startPoint: .top, endPoint: .bottom
            )
        case .energy:
            return LinearGradient(
                colors: [V2Color.barDynTop, V2Color.barDynBottom],
                startPoint: .top, endPoint: .bottom
            )
        }
    }

    private func valueLabel(_ v: Double?) -> String {
        guard let v else { return "--" }
        return decimals > 0
            ? String(format: "%.\(decimals)f", v)
            : String(Int(v.rounded()))
    }

    // MARK: 入场动画

    /// 7 天每根错峰 44ms 且封顶 300ms；30 天不错峰（`stag = d30 ? 0 : 44`，4153 行）
    private func stagger(_ i: Int) -> Double {
        guard animate, !isD30, !reduceMotion else { return 0 }
        return min(Double(i) * 0.044, 0.300)
    }

    private func barAnimation(_ delay: Double) -> Animation? {
        guard animate, !reduceMotion else { return nil }
        return .timingCurve(0.22, 0.61, 0.36, 1, duration: 0.52).delay(delay)
    }

    private func labelAnimation(_ delay: Double) -> Animation? {
        guard animate, !reduceMotion else { return nil }
        return .easeOut(duration: 0.36).delay(delay + 0.12)
    }

    private func startAnimation() {
        guard animate, !reduceMotion else {
            grown = true
            return
        }
        grown = false
        // 下一帧再置 true，否则首帧的 false 与 true 会被合并，动画不触发
        DispatchQueue.main.async { grown = true }
    }

    // MARK: 交互

    /// 点柱：把内容坐标换算成第几根柱（柱宽之外算缝隙，不响应）
    private func handleTap(_ contentX: CGFloat) {
        guard pitch > 0 else { return }
        let index = Int(floor(contentX / pitch))
        guard index >= 0, index < points.count else { return }
        let local = contentX - CGFloat(index) * pitch
        guard local <= barW, points[index].value != nil else { return }
        selection = (selection == index) ? -1 : index
    }

    /// 带选中时横滑，选中跟到视口中心那根柱（HTML `onChartScroll`，4276–4302）。
    /// 没有选中（-1）时不动 —— HTML 也是这个条件。
    private func followSelection() {
        guard selection >= 0, maxOffset > 0, pitch > 0, !points.isEmpty else { return }
        let center = offset + viewportW / 2
        let raw = (center - barW / 2) / pitch
        let index = min(max(0, Int(raw.rounded())), points.count - 1)
        if index != selection { selection = index }
    }

    // MARK: 气泡

    private var tipText: String? {
        guard selection >= 0, selection < points.count else { return nil }
        let p = points[selection]
        var parts: [String] = []
        if !p.full.isEmpty { parts.append(p.full) }
        if let v = p.value {
            parts.append("\(rawNumber(v)) \(unit)".trimmingCharacters(in: .whitespaces))
        } else {
            parts.append("无数据")
        }
        if let d = p.dynamic, let s = p.staticPart {
            parts.append("动态 \(String(format: "%.1f", d)) · 静态 \(String(format: "%.1f", s))")
        }
        return parts.joined(separator: " · ")
    }

    /// JS 的 `String(Number)`：整数不带小数，其余最多两位（后端已 round 到 2 位）
    private func rawNumber(_ v: Double) -> String {
        if v == v.rounded() { return String(Int(v)) }
        var s = String(format: "%.2f", v)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }

    private var tipLayer: some View {
        GeometryReader { proxy in
            if let text = tipText {
                let tw = Self.tipWidth(text)
                let th = Self.tipH
                let index = selection
                // 缺数据的柱子是 8pt 虚线槽，气泡要贴着它而不是贴着 0 高
                let h = points[index].value == nil ? 8 : barHeight(points[index].value)
                // 卡片坐标：内距 + 标题 20 + 间距 8
                let rowTop = V2Metrics.cardPadding + 20 + 8
                let bodyTop = rowTop + (barsH - h)
                let minTop = V2Metrics.cardPadding + 20 + 6
                let rawTop = bodyTop - th - 8
                let clamped = rawTop < minTop
                let top = clamped ? minTop : rawTop

                let plotOriginX = V2Metrics.cardPadding + yAxisW + rowGap
                let barCenter = plotOriginX + CGFloat(index) * pitch + barW / 2 - offset
                let rawLeft = barCenter - tw / 2
                let left = min(max(8, rawLeft), max(8, proxy.size.width - tw - 8))

                tipBubble(text, clamped: clamped)
                    .offset(x: left, y: top)
            }
        }
        .allowsHitTesting(false)
    }

    private func tipBubble(_ text: String, clamped: Bool) -> some View {
        Text(text)
            .v2Text(.tip11, color: .white)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(V2Color.tipBackground)
            )
            .overlay(alignment: .bottom) {
                if !clamped {
                    // 7×7 旋转 45°，压在底边中点（`.v2-chart-tip::after`）
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(V2Color.tipBackground)
                        .frame(width: 7, height: 7)
                        .rotationEffect(.degrees(45))
                        .offset(y: 3.5)
                }
            }
            .shadow(color: Color(hex: 0x0F1729).opacity(0.20), radius: 8, x: 0, y: 6)
            .fixedSize()
    }

    static let tipH: CGFloat = 25

    static func tipWidth(_ text: String) -> CGFloat {
        let font = UIFont(name: V2Font.medium, size: 11)
            ?? UIFont.systemFont(ofSize: 11, weight: .medium)
        let w = (text as NSString).size(withAttributes: [.font: font]).width
        return ceil(w) + 18
    }

    // MARK: 卡片宽度

    private var widthReader: some View {
        GeometryReader { proxy in
            Color.clear
                .onAppear {
                    cardWidth = proxy.size.width
                    initOffsetIfNeeded()
                }
                .onChange(of: proxy.size.width) { _, new in
                    cardWidth = new
                    initOffsetIfNeeded()
                }
        }
    }

    /// 首次拿到宽度后跳到最右端。放在这里而不是 `onAppear`：
    /// `onAppear` 时背景 GeometryReader 往往还没量出宽度，`maxOffset` 会算成整条内容宽。
    /// 视图被 `.id()` 重建时 `didInitOffset` 自动复位，于是切 7/30 天也会重新贴到最右。
    private func initOffsetIfNeeded() {
        guard !didInitOffset, cardWidth > 0 else { return }
        didInitOffset = true
        offset = maxOffset
    }
}

// MARK: - 卡片内高光

private extension V2BarChart {
    /// `inset 0 1px 2px rgba(255,255,255,.60)` 的近似（与 `CardSurface` 同一手法）
    var highlight: some View {
        RoundedRectangle(cornerRadius: V2Metrics.cardRadius, style: .continuous)
            .stroke(V2Color.glassHighlight, lineWidth: 2)
            .offset(y: 1)
            .clipShape(RoundedRectangle(cornerRadius: V2Metrics.cardRadius, style: .continuous))
    }
}
