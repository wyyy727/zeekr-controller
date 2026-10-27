//
//  TripsView.swift
//  ZeekrDash
//
//  行程屏（v2）
//
//  真源：`preview/index-v2.html` 的 `renderTrips()`（4561–4660）
//  与行程图表样式块（1796–1928）。每个数值都能在那两处指到出处。
//

import Foundation
import SwiftUI

/// 行程页：月份胶囊 + 六格汇总 + 7/30 段控件 + 两张自绘柱图
///
/// 数据来自后端的 `GET /api/trips/energy`，与官方 App「行程统计」同一个上游接口，
/// 所以口径一致（总电耗 = 动态 + 静态；平均动态电耗 = 动态 ÷ 里程）。
struct TripsView: View {

    @Environment(AppStore.self) private var store
    @State private var model = TripsViewModel()
    @State private var showMonthPicker = false

    /// 点柱气泡选中的索引，两张图共享（-1 = 没选）
    @State private var selection = -1
    /// 两张图共享的横向偏移（自绘，不用 ScrollView，见 `V2BarChart.horizontalDrag`）
    @State private var offset: CGFloat = 0

    /// `.task(id:)` 的键：月份或**实际区间**任一变化都重新加载。
    /// 用 `effectiveDays` 而不是 `selectedDays`：历史月份固定 30 天，
    /// 否则「本月 7 天 → 切历史月」会因为 id 不变而不重新取数。
    private var loadKey: String {
        "\(model.selectedMonth)#\(model.effectiveDays)"
    }

    var body: some View {
        NavigationStack {
            ScreenContainer(
                modePill: store.modePill,
                trailingAccessory: {
                    // 未登录时 HTML 直接渲染登录墙，页头（含月份胶囊）整行不出现
                    if !store.needsLogin { monthChip }
                }
            ) {
                content
            }
            .toolbar(.hidden, for: .navigationBar)
            .refreshable { await model.load() }
        }
        .task(id: loadKey) {
            await model.load()
        }
        // 每次进页面重播图表入场动画（HTML `goTab()` 里把 tripsChartAnim 清零）
        .onAppear { model.replayChartAnimation() }
        // 数据换了就把气泡和横向位置复位：render 会重建 DOM，HTML 同样每次复位
        .onChange(of: loadKey) { _, _ in
            selection = -1
        }
        .sheet(isPresented: $showMonthPicker) {
            MonthPickerSheet(months: model.monthOptions, selection: model.selectedMonth) { picked in
                Task { await model.select(month: picked) }
            }
        }
    }

    // MARK: - 内容分派（S1–S4 四态）

    @ViewBuilder
    private var content: some View {
        if store.needsLogin {
            V2LoginWall { store.selectedTab = .settings }
        } else {
            // 页脚在四态里都要出现（HTML 的 `shell()` 无条件拼 `v2Foot()`）
            VStack(spacing: V2Metrics.screenGap) {
                stateContent
                footNote
            }
        }
    }

    @ViewBuilder
    private var stateContent: some View {
        if let month = model.monthStats, model.windowStats != nil {
            loaded(month: month)
        } else if model.isLoading {
            skeleton
        } else if model.errorMessage != nil {
            errorCard
        } else {
            emptyCard
        }
    }

    // MARK: - 月份胶囊（`.v2-month-chip`）

    private var monthChip: some View {
        Button {
            showMonthPicker = true
        } label: {
            Text(model.selectedMonthLabel)
                .v2Text(.month13, color: V2Color.accent)
                .padding(.horizontal, 14)
                .frame(minWidth: V2Metrics.monthChipMinWidth, minHeight: V2Metrics.monthChipHeight)
                .glassSurface(cornerRadius: V2Metrics.monthChipRadius)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("统计月份 \(model.selectedMonthLabel)")
    }

    // MARK: - 已加载

    private func loaded(month: DailyEnergy) -> some View {
        VStack(spacing: V2Metrics.screenGap) {
            summaryCard(month)

            // 有旧数据但本轮失败：保留数据，明确告知不是刚拿的
            if let message = model.errorMessage {
                V2StaleBanner(
                    text: "这一轮没读到最新能耗，下面是上次读到的数据",
                    detail: message
                ) { Task { await model.load() } }
            }

            distributionRow

            if !model.distancePoints.isEmpty {
                V2BarChart(
                    title: "每日里程 (km)",
                    points: model.distancePoints,
                    days: model.effectiveDays,
                    decimals: 0,
                    unit: "km",
                    kind: .mileage,
                    animate: true,
                    baseDelay: 0,
                    selection: $selection,
                    offset: $offset
                )
                .id("mileage-\(model.chartAnimToken)")

                V2BarChart(
                    title: "每日电耗 (kWh)",
                    points: model.energyPoints,
                    days: model.effectiveDays,
                    decimals: 1,
                    unit: "kWh",
                    kind: .energy,
                    animate: true,
                    baseDelay: 0.12,   // HTML `--base: 120ms`
                    selection: $selection,
                    offset: $offset
                )
                .id("energy-\(model.chartAnimToken)")
            } else {
                emptyCard
            }
        }
    }

    // MARK: - 六格汇总（`.v2-sum-grid`）

    private func summaryCard(_ month: DailyEnergy) -> some View {
        VStack(spacing: V2Metrics.sumRowGap) {
            HStack(spacing: V2Metrics.sumColGap) {
                sumCell("本月里程", month.distanceKm, "km", decimals: 0, delay: 0)
                sumCell("总电耗", month.energyKwh, "kWh", decimals: 1, delay: 0.06)
            }
            HStack(spacing: V2Metrics.sumColGap) {
                sumCell("动态电耗", month.dynamicEnergyKwh, "kWh", decimals: 1, delay: 0.12)
                sumCell("静态电耗", month.staticEnergyKwh, "kWh", decimals: 1, delay: 0.18)
            }
            HStack(spacing: V2Metrics.sumColGap) {
                sumCell("平均动态电耗", month.avgDynamicConsumption, "kWh/100km", decimals: 1, delay: 0.24)
                sumCell("平均电耗", month.avgConsumption, "kWh/100km", decimals: 1, delay: 0.30)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .v2Card()
    }

    /// 一格：标题 11/500、数值 16/600、单位 11/500，数值与单位基线对齐、间距 3。
    /// 数值缺失一律 `--`（不是 0）。
    ///
    /// 数值走 `V2CountUp` 递增入场，`delay` 让六格按行错开；`reserveWidth` 用最终宽度
    /// 占位，否则数字从 1 位数涨到 3 位数时，右边的单位会一路被推开。
    private func sumCell(
        _ key: String,
        _ value: Double?,
        _ unit: String,
        decimals: Int,
        delay: Double
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(key)
                .v2Text(.sumKey, color: V2Color.text2)
                .lineLimit(1)
                .minimumScaleFactor(0.85)

            HStack(alignment: .firstTextBaseline, spacing: 3) {
                if let value {
                    V2CountUp(target: value, delay: delay, reserveWidth: true) {
                        String(format: "%.\(decimals)f", $0)
                    }
                    .v2Text(.sumValue)
                } else {
                    Text("--")
                        .v2Text(.sumValue)
                        .v2Numeric()
                }
                Text(unit)
                    .v2Text(.sumKey, color: V2Color.text2)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 每日分布 + 7/30 段控件（`.v2-dist` / `.v2-seg`）

    private var distributionRow: some View {
        HStack(spacing: 8) {
            Text("每日分布")
                .v2Text(.text12, color: V2Color.text3)

            Spacer(minLength: 0)

            // 历史月份固定整月，不渲染段控件（HTML 4628）
            if model.isCurrentMonth {
                daySegmented
            }
        }
        .frame(height: 30)
    }

    private var daySegmented: some View {
        HStack(spacing: 0) {
            ForEach([7, 30], id: \.self) { days in
                let on = model.effectiveDays == days
                Button {
                    model.setDays(days)
                } label: {
                    Text(days == 7 ? "7天" : "30天")
                        .v2Text(on ? .segLabelOn : .segLabel,
                                color: on ? V2Color.text1 : V2Color.text3)
                        .frame(maxWidth: .infinity)
                        .frame(height: 24)
                        .background {
                            if on {
                                RoundedRectangle(cornerRadius: V2Metrics.segThumbRadius, style: .continuous)
                                    .fill(Color.white.opacity(0.95))
                                    .shadow(
                                        color: Color(hex: 0x4A5778).opacity(0.16),
                                        radius: 3, x: 0, y: 2
                                    )
                            }
                        }
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? AccessibilityTraits.isSelected : [])
            }
        }
        .padding(V2Metrics.segInset)
        .frame(width: V2Metrics.segWidth, height: V2Metrics.segHeight)
        .glassSurface(cornerRadius: V2Metrics.segRadius)
    }

    // MARK: - 旧数据横幅


    // MARK: - 加载骨架（S2）

    private var skeleton: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("本月里程")
                    .v2Text(.title14)
                Spacer(minLength: 0)
                Text("加载中")
                    .v2Text(.sumKey, color: V2Color.text2)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(V2Color.tintMuted)
                    .clipShape(Capsule())
            }

            // 三条 14pt 高、宽 70% / 35% / 55% 的骨架条，1.6s 呼吸
            GeometryReader { proxy in
                VStack(alignment: .leading, spacing: 12) {
                    skeletonLine(proxy.size.width * 0.70)
                    skeletonLine(proxy.size.width * 0.35)
                    skeletonLine(proxy.size.width * 0.55)
                }
                .padding(.top, 8)
            }
            .frame(height: 66 + 8)
        }
        .v2Card()
        .accessibilityLabel("正在加载能耗数据")
    }

    private func skeletonLine(_ width: CGFloat) -> some View {
        SkeletonBar(width: width)
    }

    // MARK: - 读失败（S3）

    private var errorCard: some View {
        VStack(spacing: 0) {
            // 与空态统一用柱状版（用户确认：两处都用 `ic-chart-bar`）
            Image("ic-chart-bar")
                .renderingMode(.template)
                .resizable()
                .frame(width: 28, height: 28)
                .foregroundStyle(V2Color.text3)

            Text("能耗数据没有读到")
                .v2Text(.emptyTitle)
                .padding(.top, 12)

            Text("后端可能正在重启，或登录状态已失效")
                .v2Text(.emptyDesc, color: V2Color.text3)
                .multilineTextAlignment(.center)
                .padding(.top, 6)

            Button {
                Task { await model.load() }
            } label: {
                Text("重试")
                    .v2Text(.button14, color: V2Color.accent)
                    .frame(height: 32)
                    .padding(.horizontal, 20)
                    .background(V2Color.tintAccent)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .padding(.top, 16)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 22)
        .frame(maxWidth: .infinity)
        .v2Card()
    }

    // MARK: - 真空态（S4）

    private var emptyCard: some View {
        VStack(spacing: 0) {
            /* HTML 用的是 `SVG.chart`，而那个键在 HTML 里被定义了两次，
               运行时生效的是折线版。用户已确认这里用柱状版（`ic-chart-bar`）更贴语义 ——
               这是经确认的偏离，不是取错资产。 */
            Image("ic-chart-bar")
                .renderingMode(.template)
                .resizable()
                .frame(width: 28, height: 28)
                .foregroundStyle(V2Color.text3)

            Text("这个时间段没有行程")
                .v2Text(.emptyTitle)
                .padding(.top, 12)

            Text("换个月份或切到 30 天看看")
                .v2Text(.emptyDesc, color: V2Color.text3)
                .padding(.top, 6)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 22)
        .frame(maxWidth: .infinity)
        .v2Card()
    }

    // MARK: - 页脚（`.v2-foot`）

    private var footNote: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let last = store.lastRefresh {
                Text("更新于 \(last.formatted(date: .omitted, time: .shortened))")
            }
            Text("数据来自非官方接口，仅供参考")
        }
        .v2Text(.foot11, color: V2Color.text3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 8)
    }
}

// MARK: - 月份选择（系统双滚轮）

/// 月份选择弹窗（行程页与充电页共用）：左轮选年、右轮选月，都是 iOS 原生 wheel。
///
/// 2026-10-27 按用户要求从「自绘 HTML 年份竖列 + 月份网格」回退到系统滚轮：
/// HTML 那套要自己维护两百行布局，而用户要的只是能选到想要的月份，
/// 滚轮天然满足，还顺手拿到系统的滚动手感与无障碍。
///
/// 两个轮子的选项都来自数据（months）。所以「年份轮里只有 2026」不是筛选
/// 逻辑的 bug —— 服务端库里最早的充电流水是 2026-01、最早的行程是 2026-09，
/// 2025 及更早根本没有可查的月份，HTML 版读同一份数据也只会列出 2026。
/// 一旦库里出现更早的年份，这里会自动多出一项，不用改代码。
struct MonthPickerSheet: View {

    let months: [MonthOption]
    let selection: String
    let onPick: (String) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var year: Int = Calendar.current.component(.year, from: Date())
    @State private var month: Int = Calendar.current.component(.month, from: Date())

    // MARK: - 数据

    /// 把 currentMonth / YYYY-MM 统一折成 (年, 月)。
    ///
    /// 必须折成绝对值：currentMonth 是相对 token（今天看是 2026-10），
    /// 只有页面自己知道它代表哪个月，而滚轮要的是具体数字。
    private var available: [(year: Int, month: Int)] {
        let now = Calendar.current.dateComponents([.year, .month], from: Date())
        let thisYear = now.year ?? year
        let thisMonth = now.month ?? month

        var out: [(year: Int, month: Int)] = []
        for option in months {
            if option.yearMonth == "currentMonth" {
                out.append((thisYear, thisMonth))
                continue
            }
            let parts = option.yearMonth.split(separator: "-")
            guard parts.count == 2, let y = Int(parts[0]), let m = Int(parts[1]) else { continue }
            out.append((y, m))
        }
        return out
    }

    /// 年份轮：数据里出现过的年份加今年，降序。
    ///
    /// 为什么补今年：今年还没产生流水时（比如年初），数据里没有今年的月份，
    /// 若只列数据年份就翻不到「本月」。补一项只多一行，少了就是死路。
    private var years: [Int] {
        var set = Set(available.map { $0.year })
        set.insert(Calendar.current.component(.year, from: Date()))
        return set.sorted(by: >)
    }

    /// 月份轮：该年有数据的月份升序；该年整体没数据时用本月兜底，
    /// 免得滚轮空着（空 Picker 会让选中值指向不存在的 tag）。
    private var monthsOfYear: [Int] {
        let list = Set(available.filter { $0.year == year }.map { $0.month }).sorted()
        if list.isEmpty {
            return [Calendar.current.component(.month, from: Date())]
        }
        return list
    }

    /// 本月对应的绝对 key（2026-10），用来判断选中的就是本月。
    private var thisKey: String {
        let now = Calendar.current.dateComponents([.year, .month], from: Date())
        return Self.key(now.year ?? year, now.month ?? month)
    }

    private static func key(_ y: Int, _ m: Int) -> String {
        String(format: "%04d-%02d", y, m)
    }

    // MARK: - 视图

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("取消") { dismiss() }
                    .v2Text(.nav15, color: V2Color.text2)

                Spacer(minLength: 0)

                Text("选择月份")
                    .v2Text(.stat15)

                Spacer(minLength: 0)

                Button("确定") { confirm() }
                    .v2Text(.stat15, color: V2Color.accent)
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)

            HStack(spacing: 0) {
                Picker("年", selection: $year) {
                    ForEach(years, id: \.self) { value in
                        Text("\(value) 年").tag(value)
                    }
                }
                .pickerStyle(.wheel)
                .frame(maxWidth: .infinity)

                Picker("月", selection: $month) {
                    ForEach(monthsOfYear, id: \.self) { value in
                        Text("\(value) 月").tag(value)
                    }
                }
                .pickerStyle(.wheel)
                .frame(maxWidth: .infinity)
            }
            .frame(height: 190)

            Spacer(minLength: 0)
        }
        .presentationDetents([.height(300)])
        .presentationDragIndicator(.visible)
        .onAppear(perform: syncFromSelection)
        .onChange(of: year) { _, _ in
            // 切年时右轮要落到该年真实存在的月份上，否则会停在一个没有数据的月，
            // 用户点确定后拿到的是空图。
            if !monthsOfYear.contains(month) {
                month = monthsOfYear.first ?? month
            }
        }
    }

    // MARK: - 行为

    /// 打开时把当前选择摆到轮子上（selection 可能是 currentMonth）。
    private func syncFromSelection() {
        if selection == "currentMonth" || selection.isEmpty {
            let now = Calendar.current.dateComponents([.year, .month], from: Date())
            year = now.year ?? year
            month = now.month ?? month
        } else {
            let parts = selection.split(separator: "-")
            if parts.count == 2, let y = Int(parts[0]), let m = Int(parts[1]) {
                year = y
                month = m
            }
        }

        if !years.contains(year) { year = years.first ?? year }
        if !monthsOfYear.contains(month) { month = monthsOfYear.first ?? month }
    }

    /// 提交：拼出绝对 key，再按需折回 currentMonth。
    ///
    /// 折回这一步是给服务端的：本月数据会随时间滚动，只有传相对 token
    /// 才能让「本月」永远指向打开页面那一刻的月份。
    private func confirm() {
        guard available.contains(where: { $0.year == year && $0.month == month }) else {
            dismiss()
            return
        }

        let picked = Self.key(year, month)
        let isThisMonth = picked == thisKey && months.contains { $0.yearMonth == "currentMonth" }
        onPick(isThisMonth ? "currentMonth" : picked)
        dismiss()
    }
}
