//
//  TripsView.swift
//  ZeekrDash
//
//  行程与能耗
//

import Charts
import SwiftUI

/// 行程页：能耗趋势图 + 行程列表
struct TripsView: View {

    @Environment(\.colorScheme) private var scheme
    @Environment(AppStore.self) private var store
    @State private var model = TripsViewModel()

    var body: some View {
        // 页面标题与底部导航重复，已移除；顶部右上角为数据来源徽标
        NavigationStack {
            ScreenContainer(modeText: store.modeBadgeText) {
                rangePicker

                if model.isLoading && model.trend.isEmpty {
                    LoadingView(text: "正在加载行程数据")
                        .padding(.top, 60)
                } else if let error = model.errorMessage, model.trend.isEmpty {
                    errorState(error)
                } else {
                    if !model.trend.isEmpty {
                        consumptionChart
                        distanceChart
                    }
                    summaryCard
                    tripList

                    // 有数据、但期间连接失败过：用横幅提示而不是整页错误态
                    // （与首页 DashboardView 的处理方式保持一致）
                    if let message = model.errorMessage {
                        ErrorBanner(message: message, onRetry: { model.errorMessage = nil })
                    }
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .refreshable { await model.load(days: model.selectedDays) }
        }
        // 用 .task(id:) 而不是 .task + .onChange：
        // id 变化时 SwiftUI 会自动取消上一个 task，天然消除了"快速切换区间时
        // 多个 load 并发、旧响应覆盖新数据"的竞态（原先在 onChange 里裸起
        // Task，不可取消，也无人回收）。
        .task(id: model.selectedDays) {
            await model.load(days: model.selectedDays)
        }
    }

    // MARK: - 时间范围选择

    private var rangePicker: some View {
        Picker("时间范围", selection: $model.selectedDays) {
            Text("7 天").tag(7)
            Text("30 天").tag(30)
            Text("90 天").tag(90)
        }
        .pickerStyle(.segmented)
    }

    // MARK: - 能耗趋势图

    private var consumptionChart: some View {
        ChartCard(title: "百公里能耗", subtitle: "kWh/100km") {
            Chart(model.trend) { point in
                if let consumption = point.consumption {
                    LineMark(
                        x: .value("日期", point.date),
                        y: .value("能耗", consumption)
                    )
                    .foregroundStyle(Theme.accent(scheme))
                    .interpolationMethod(.catmullRom)
                    .lineStyle(StrokeStyle(lineWidth: 2))

                    AreaMark(
                        x: .value("日期", point.date),
                        y: .value("能耗", consumption)
                    )
                    .foregroundStyle(
                        LinearGradient(
                            colors: [
                                Theme.accent(scheme).opacity(0.22),
                                Theme.accent(scheme).opacity(0.02),
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .interpolationMethod(.catmullRom)
                }
            }
            .chartYScale(domain: model.consumptionRange)
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                    AxisGridLine().foregroundStyle(Theme.separator(scheme))
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
        }
    }

    // MARK: - 里程柱状图

    private var distanceChart: some View {
        ChartCard(title: "每日里程", subtitle: "km") {
            Chart(model.trend) { point in
                BarMark(
                    x: .value("日期", point.date),
                    y: .value("里程", point.distanceKm ?? 0)
                )
                .foregroundStyle(Theme.accentSecondary(scheme).opacity(0.72))
                .cornerRadius(2)
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                    AxisGridLine().foregroundStyle(Theme.separator(scheme))
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
        }
    }

    // MARK: - 汇总

    private var summaryCard: some View {
        HStack(spacing: 0) {
            summaryItem("总里程", value: String(format: "%.0f", model.totalDistance), unit: "km")
            Divider()
                .frame(height: 28)
                .overlay(Theme.separator(scheme))
            summaryItem("总能耗", value: String(format: "%.1f", model.totalEnergy), unit: "kWh")
            Divider()
                .frame(height: 28)
                .overlay(Theme.separator(scheme))
            summaryItem(
                "平均能耗",
                value: model.avgConsumption.map { String(format: "%.1f", $0) } ?? "--",
                unit: "kWh/100km"
            )
        }
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

    // MARK: - 行程列表

    private var tripList: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("行程记录")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary(scheme))
                Spacer()
                Text("\(model.trips.count) 条")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textTertiary(scheme))
            }

            if model.trips.isEmpty {
                Text("该时间范围内暂无行程记录")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textTertiary(scheme))
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 32)
            } else {
                ForEach(model.trips) { trip in
                    TripRow(trip: trip)
                    if trip.id != model.trips.last?.id {
                        Divider().overlay(Theme.separator(scheme))
                    }
                }
            }
        }
        .padding(Metrics.cardPadding)
        .background(Theme.surface(scheme))
        .clipShape(RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous))
    }

    // MARK: - 错误态

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(ChineseColor.statusWarn)
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(Theme.textSecondary(scheme))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button("重试") {
                Task { await model.load(days: model.selectedDays) }
            }
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(Theme.accent(scheme))
        }
        .padding(.top, 60)
    }
}

// MARK: - 单条行程

private struct TripRow: View {

    let trip: Trip
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 12) {
            VStack(spacing: 2) {
                Text(timeText)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(Theme.textPrimary(scheme))
                    .monospacedDigit()
                Text(dateText)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textTertiary(scheme))
            }
            .frame(width: 52, alignment: .leading)

            VStack(alignment: .leading, spacing: 3) {
                if let from = trip.startPlace, let to = trip.endPlace {
                    HStack(spacing: 4) {
                        Text(from)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textSecondary(scheme))
                            .lineLimit(1)
                        Image(systemName: "arrow.right")
                            .font(.system(size: 9))
                            .foregroundStyle(Theme.textTertiary(scheme))
                        Text(to)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textSecondary(scheme))
                            .lineLimit(1)
                    }
                }

                HStack(spacing: 8) {
                    label("\(String(format: "%.1f", trip.distanceKm ?? 0)) km", icon: "road.lanes")
                    if let energy = trip.energyKwh {
                        label("\(String(format: "%.1f", energy)) kWh", icon: "bolt")
                    }
                    if let duration = trip.durationMinutes {
                        // 四舍五入，而不是 Int() 的向零截断：1.9 分应显示「2 分」
                        label("\(Int(duration.rounded())) 分", icon: "clock")
                    }
                }
            }

            Spacer(minLength: 0)

            if let consumption = trip.consumption {
                VStack(spacing: 1) {
                    Text(String(format: "%.1f", consumption))
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .foregroundStyle(Theme.accent(scheme))
                        .monospacedDigit()
                    Text("kWh/100")
                        .font(.system(size: 8))
                        .foregroundStyle(Theme.textTertiary(scheme))
                }
            }
        }
        .padding(.vertical, 9)
    }

    private func label(_ text: String, icon: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 9))
            Text(text)
                .font(.system(size: 11))
        }
        .foregroundStyle(Theme.textTertiary(scheme))
    }

    /// 复用的日期格式化器。
    ///
    /// 这两个属性原先每次访问都 `DateFormatter()` 新建一个 —— 列表滚动时
    /// 每行每次重绘都要分配两个，是典型的高频创建反模式。提为 static 常量后
    /// 只创建一次。同时显式固定 en_US_POSIX，避免 locale 影响数字呈现。
    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    private var timeText: String {
        guard let date = trip.startTime else { return "--:--" }
        return Self.timeFormatter.string(from: date)
    }

    private var dateText: String {
        guard let date = trip.startTime else { return "--" }
        return Self.dayFormatter.string(from: date)
    }
}

// MARK: - 图表容器

/// 统一的图表卡片容器，保证视觉一致
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
