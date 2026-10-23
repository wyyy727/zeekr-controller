//
//  TripsView.swift
//  ZeekrDash
//
//  行程与能耗（官方「行程统计」同源）
//

import Charts
import SwiftUI

/// 行程页：月份筛选 + 四项汇总 + 每日里程柱状 / 每日电耗折线
///
/// 数据来自后端的 `GET /api/trips/energy`，它与官方 App「行程统计」页是同一个上游接口，
/// 所以口径和官方一致（总电耗 = 动态 + 静态；平均动态电耗 = 动态 ÷ 里程）。
struct TripsView: View {

    @Environment(\.colorScheme) private var scheme
    @Environment(AppStore.self) private var store
    @State private var model = TripsViewModel()
    @State private var showMonthPicker = false

    /// `.task(id:)` 的键：月份或区间任一变化都重新加载，
    /// 且 id 变化会自动取消上一次任务，天然避免旧响应覆盖新数据。
    private var loadKey: String {
        "\(model.selectedMonth)#\(model.selectedDays)"
    }

    var body: some View {
        NavigationStack {
            ScreenContainer(modeText: store.modeBadgeText) {
                monthRow

                if model.isLoading && model.monthStats == nil {
                    LoadingView(text: "正在加载能耗数据")
                        .padding(.top, 60)
                } else if let month = model.monthStats {
                    summaryGrid(month)
                    rangeRow(month)
                    chartsCard

                    // 有数据但期间失败过：横幅提示，而不是整页错误态
                    if let message = model.errorMessage {
                        /* 重试要**真的重新拉一次**。以前只是把提示清掉 ——
                           提示没了、数据还是旧的，用户以为好了，其实什么都没变。 */
                        ErrorBanner(message: message, onRetry: {
                            Task { await model.load(days: model.selectedDays) }
                        })
                    }
                } else {
                    emptyState
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .refreshable { await model.load(days: model.selectedDays) }
        }
        .task(id: loadKey) {
            await model.load(days: model.selectedDays)
        }
        .sheet(isPresented: $showMonthPicker) {
            MonthPickerSheet(months: model.monthOptions, selection: model.selectedMonth) { picked in
                Task { await model.select(month: picked) }
            }
        }
    }

    // MARK: - 月份

    private var monthRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "calendar")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textTertiary(scheme))
            Text("统计月份")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textTertiary(scheme))

            Spacer(minLength: 0)

            Button {
                showMonthPicker = true
            } label: {
                HStack(spacing: 3) {
                    Text(model.selectedMonthLabel)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.textPrimary(scheme))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.textTertiary(scheme))
                }
                .padding(.horizontal, 12)
                .frame(height: 30)
                .glassEffect(.regular, in: .capsule)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - 四项汇总

    /// 与官方「能量统计」卡一一对应，**不能少「动态电耗」**：
    /// 少了它，用户拿「总电耗 ÷ 里程」去对「平均动态电耗」永远对不上。
    private func summaryGrid(_ month: DailyEnergy) -> some View {
        LazyVGrid(
            columns: [
                GridItem(.flexible(), spacing: 12),
                GridItem(.flexible(), spacing: 12),
            ],
            spacing: 14
        ) {
            summaryItem("累计里程",
                        value: month.distanceKm.map { String(format: "%.0f", $0) } ?? "--",
                        unit: "km")
            summaryItem("总电耗",
                        value: month.energyKwh.map { String(format: "%.1f", $0) } ?? "--",
                        unit: "kWh")
            summaryItem("动态电耗",
                        value: month.dynamicEnergyKwh.map { String(format: "%.1f", $0) } ?? "--",
                        unit: "kWh")
            summaryItem("平均动态电耗",
                        value: month.avgDynamicConsumption.map { String(format: "%.1f", $0) } ?? "--",
                        unit: "kWh/100km")
        }
        .padding(.horizontal, Metrics.cardPadding)
        .padding(.vertical, 14)
        .background(Theme.surface(scheme))
        .clipShape(RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous))
    }

    private func summaryItem(_ title: String, value: String, unit: String) -> some View {
        VStack(spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value)
                    .font(.system(size: 17, weight: .medium, design: .rounded))
                    .foregroundStyle(Theme.textPrimary(scheme))
                    .monospacedDigit()
                Text(unit)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textTertiary(scheme))
            }
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(Theme.textTertiary(scheme))
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - 区间与充电次数

    private func rangeRow(_ month: DailyEnergy) -> some View {
        HStack(spacing: 4) {
            Text("\(model.selectedMonthLabel) \(month.startDate ?? "") — \(month.endDate ?? "")")
            if model.chargeCount > 0 {
                Text("· 充电 \(model.chargeCount) 次")
                Text("· 快充 \(month.fastChargeCount ?? 0) / 慢充 \(month.slowChargeCount ?? 0)")
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 11))
        .foregroundStyle(Theme.textTertiary(scheme))
        .lineLimit(1)
        .minimumScaleFactor(0.8)
    }

    // MARK: - 图表

    private var distributionTitle: String {
        let days = model.windowStats?.days ?? model.series.count
        return model.isCurrentMonth ? "每日分布 · 近 \(days) 天" : "\(model.selectedMonthLabel)共 \(days) 天"
    }

    private var distanceColor: Color { Color(hex: 0x7C5CFC) }
    private var energyColor: Color { Color(hex: 0xF0913C) }

    private var chartsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text(distributionTitle)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary(scheme))
                Spacer(minLength: 0)
                // 历史月份固定整月，不显示区间切换（与网页一致）
                if model.isCurrentMonth {
                    Picker("区间", selection: Binding(
                        get: { model.selectedDays },
                        set: { model.selectedDays = $0 }
                    )) {
                        Text("7 天").tag(7)
                        Text("30 天").tag(30)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 128)
                }
            }

            /* 两张图放在**同一个**横向 ScrollView 里：滑动任意一张，另一张跟着走，
               方便对照同一天的里程与电耗。各自用固定宽度（每点 56pt）而不是压缩间距。 */
            ScrollView(.horizontal, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 14) {
                    chartHeading("每日里程", unit: "km", color: distanceColor)
                    distanceChart
                    chartHeading("每日电耗", unit: "kWh", color: energyColor)
                    energyChart
                }
            }
        }
        .padding(Metrics.cardPadding)
        .background(Theme.surface(scheme))
        .clipShape(RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous))
    }

    private func chartHeading(_ title: String, unit: String, color: Color) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.textPrimary(scheme))
            Text(unit)
                .font(.system(size: 10))
                .foregroundStyle(Theme.textTertiary(scheme))
            Spacer(minLength: 0)
        }
    }

    private var distanceChart: some View {
        Chart(model.series) { point in
            BarMark(
                x: .value("日期", point.shortDate),
                y: .value("里程", point.distanceKm ?? 0)
            )
            .foregroundStyle(distanceColor)
            .cornerRadius(3)
            .annotation(position: .top, spacing: 2) {
                if let value = point.distanceKm {
                    Text(String(format: "%.0f", value))
                        .font(.system(size: 9))
                        .foregroundStyle(distanceColor)
                }
            }
        }
        .chartYScale(domain: model.distanceRange)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: min(12, max(2, model.series.count)))) { _ in
                AxisValueLabel()
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.textTertiary(scheme))
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { _ in
                AxisGridLine().foregroundStyle(Theme.separator(scheme))
                AxisValueLabel()
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.textTertiary(scheme))
            }
        }
        .frame(width: model.chartWidth, height: 140)
    }

    private var energyChart: some View {
        Chart(model.series) { point in
            if let energy = point.energyKwh {
                AreaMark(
                    x: .value("日期", point.shortDate),
                    y: .value("电耗", energy)
                )
                .foregroundStyle(
                    LinearGradient(
                        colors: [energyColor.opacity(0.22), energyColor.opacity(0.02)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .interpolationMethod(.catmullRom)

                LineMark(
                    x: .value("日期", point.shortDate),
                    y: .value("电耗", energy)
                )
                .foregroundStyle(energyColor)
                .interpolationMethod(.catmullRom)
                .lineStyle(StrokeStyle(lineWidth: 2))

                PointMark(
                    x: .value("日期", point.shortDate),
                    y: .value("电耗", energy)
                )
                .foregroundStyle(energyColor)
                .symbolSize(18)
                .annotation(position: .top, spacing: 2) {
                    Text(String(format: "%.1f", energy))
                        .font(.system(size: 9))
                        .foregroundStyle(energyColor)
                }
            }
        }
        .chartYScale(domain: model.energyRange)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: min(12, max(2, model.series.count)))) { _ in
                AxisValueLabel()
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.textTertiary(scheme))
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { _ in
                AxisGridLine().foregroundStyle(Theme.separator(scheme))
                AxisValueLabel()
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.textTertiary(scheme))
            }
        }
        .frame(width: model.chartWidth, height: 140)
    }

    // MARK: - 空态

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "chart.bar.xaxis")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(Theme.textTertiary(scheme))
            Text("暂无能耗数据")
                .font(.system(size: 13))
                .foregroundStyle(Theme.textSecondary(scheme))
            Text("连接后端后显示官方「行程与能耗」统计")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textTertiary(scheme))
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
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
    @Environment(\.colorScheme) private var scheme

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
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.textSecondary(scheme))
                Spacer()
                Text("选择月份")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary(scheme))
                Spacer()
                Button("确定") { confirm() }
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.accent(scheme))
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

// MARK: - 图表容器

/// 统一的图表卡片容器，保证视觉一致（充电页也在用）
struct ChartCard<Content: View>: View {

    let title: String
    var subtitle: String?
    @ViewBuilder let content: () -> Content

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary(scheme))
                if let subtitle {
                    Text("· \(subtitle)")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textTertiary(scheme))
                }
            }

            content()
                .frame(height: 150)
        }
        .padding(Metrics.cardPadding)
        .background(Theme.surface(scheme))
        .clipShape(RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous))
    }
}
