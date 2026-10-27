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
                sumCell("本月里程", month.distanceKm.map { String(format: "%.0f", $0) }, "km")
                sumCell("总电耗", month.energyKwh.map { String(format: "%.1f", $0) }, "kWh")
            }
            HStack(spacing: V2Metrics.sumColGap) {
                sumCell("动态电耗", month.dynamicEnergyKwh.map { String(format: "%.1f", $0) }, "kWh")
                sumCell("静态电耗", month.staticEnergyKwh.map { String(format: "%.1f", $0) }, "kWh")
            }
            HStack(spacing: V2Metrics.sumColGap) {
                sumCell("平均动态电耗", month.avgDynamicConsumption.map { String(format: "%.1f", $0) }, "kWh/100km")
                sumCell("平均电耗", month.avgConsumption.map { String(format: "%.1f", $0) }, "kWh/100km")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .v2Card()
    }

    /// 一格：标题 11/500、数值 16/600、单位 11/500，数值与单位基线对齐、间距 3。
    /// 数值缺失一律 `--`（不是 0）。
    private func sumCell(_ key: String, _ value: String?, _ unit: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(key)
                .v2Text(.sumKey, color: V2Color.text2)
                .lineLimit(1)
                .minimumScaleFactor(0.85)

            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value ?? "--")
                    .v2Text(.sumValue)
                    .v2Numeric()
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

// MARK: - 月份选择（iOS 原生双滚轮）

/// 左轮选年、右轮选月，都是系统原生 `.wheel`，可上下滑动。
/// 只列出**有数据**的月份，避免选到一个查不到数的月份。
/// 月份选择弹窗（行程页与充电页共用）。
///
/// 用 `MonthOption` 而不是各自的数据模型：两个页面的月份来源不同
/// （行程来自官方接口、充电来自本地库），但"选哪个月"这件事完全一样，
/// 各写一套滚轮只是多一处要同步修改的地方。
struct MonthPickerSheet: View {

    let months: [MonthOption]
    let selection: String
    let onPick: (String) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var year: Int = Calendar.current.component(.year, from: Date())
    @State private var month: Int = Calendar.current.component(.month, from: Date())

    /// 把 `currentMonth` / `2026-09` 统一成 (年, 月)
    private var available: [(year: Int, month: Int)] {
        let calendar = Calendar.current
        let now = Date()
        let thisYear = calendar.component(.year, from: now)
        let thisMonth = calendar.component(.month, from: now)

        return months.map { item in
            if item.yearMonth == "currentMonth" {
                return (thisYear, thisMonth)
            }
            let parts = item.yearMonth.split(separator: "-").compactMap { Int($0) }
            guard parts.count == 2 else { return (thisYear, thisMonth) }
            return (parts[0], parts[1])
        }
    }

    private var years: [Int] {
        let all = Set(available.map { $0.year }).sorted(by: >)
        return all.isEmpty ? [Calendar.current.component(.year, from: Date())] : all
    }

    private var monthsOfYear: [Int] {
        let all = Set(available.filter { $0.year == year }.map { $0.month }).sorted()
        return all.isEmpty ? [Calendar.current.component(.month, from: Date())] : all
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("取消") { dismiss() }
                    .v2Text(.nav15, color: V2Color.text2)
                Spacer()
                Text("选择月份")
                    .v2Text(.stat15)
                Spacer()
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
            if !monthsOfYear.contains(month) {
                month = monthsOfYear.first ?? month
            }
        }
    }

    /// 打开时滚到当前选中的年月
    private func syncFromSelection() {
        if selection == "currentMonth" {
            let calendar = Calendar.current
            let now = Date()
            year = calendar.component(.year, from: now)
            month = calendar.component(.month, from: now)
            return
        }
        let parts = selection.split(separator: "-").compactMap { Int($0) }
        if parts.count == 2 {
            year = parts[0]
            month = parts[1]
        }
    }

    private func confirm() {
        let calendar = Calendar.current
        let now = Date()
        let thisKey = String(
            format: "%04d-%02d",
            calendar.component(.year, from: now),
            calendar.component(.month, from: now)
        )
        let key = String(format: "%04d-%02d", year, month)

        // 没有数据的月份不该被选中（滚轮的月份列表本身已过滤，这里再兜一层）
        guard available.contains(where: { $0.year == year && $0.month == month }) else {
            dismiss()
            return
        }

        let hasCurrent = months.contains { $0.yearMonth == "currentMonth" }
        onPick(key == thisKey && hasCurrent ? "currentMonth" : key)
        dismiss()
    }
}

