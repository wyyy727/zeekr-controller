//
//  DashboardView.swift
//  ZeekrDash
//
//  车况主页
//

import SwiftUI

/// 车况主页：电量、续航、胎压、门窗、充电状态、快捷车控
struct DashboardView: View {

    @Environment(AppStore.self) private var store
    @Environment(\.colorScheme) private var scheme
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        // 页面标题与底部导航重复，已移除；顶部右上角为数据来源徽标
        // （真实数据时不显示，模拟 / 后端不可达时显示）
        NavigationStack {
            ScreenContainer(modeText: store.modeBadgeText) {
                if let status = store.vehicleStatus {
                    headerCard(status)

                    if status.isCharging == true {
                        chargingCard(status)
                    }

                    metricsGrid(status)
                    tyreCard(status)
                    // 「车身状态」保持 2×2，不随胎压一起改横排
                    statusCard(status)
                    ControlsPanel()
                    footerNote
                } else if store.isLoading {
                    LoadingView(text: "正在获取车辆状态")
                        .padding(.top, 60)
                } else {
                    emptyState
                }

                if let message = store.errorMessage, store.hasData {
                    ErrorBanner(message: message, onRetry: { store.errorMessage = nil })
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .refreshable { await store.refresh() }
        }
        .onAppear { store.startPolling() }
        .onChange(of: scenePhase) { _, phase in
            // 后台停止轮询省电，回前台恢复
            switch phase {
            case .active: store.startPolling()
            case .background: store.stopPolling()
            default: break
            }
        }
    }

    // MARK: - 顶部：电量与续航

    private func headerCard(_ status: VehicleStatus) -> some View {
        HStack(spacing: 20) {
            SOCRing(
                soc: status.soc ?? 0,
                isCharging: status.isCharging == true,
                size: 132,
                lineWidth: 11
            )

            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(status.nickname ?? status.modelName ?? "我的爱车")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary(scheme))
                        .lineLimit(1)

                    if let plate = status.plateNo, !plate.isEmpty {
                        Text(plate)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textTertiary(scheme))
                    }
                }

                Divider().overlay(Theme.separator(scheme))

                miniStat("续航", value: status.rangeKm.map { "\(Int($0)) km" } ?? "--")
                miniStat("总里程", value: status.odometerKm.map { formatDistance($0) } ?? "--")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(Metrics.cardPadding)
        .background(Theme.surface(scheme))
        .clipShape(RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous))
    }

    private func miniStat(_ title: String, value: String) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textTertiary(scheme))
            Spacer()
            Text(value)
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .foregroundStyle(Theme.textPrimary(scheme))
                .monospacedDigit()
        }
    }

    // MARK: - 充电状态

    private func chargingCard(_ status: VehicleStatus) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("充电中", systemImage: "bolt.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(ChineseColor.statusCharging)

            HStack(spacing: 0) {
                chargeItem("功率", value: status.chargePowerKw, unit: "kW", decimals: 1)
                chargeItem("电压", value: status.chargeVoltage, unit: "V", decimals: 0)
                chargeItem("电流", value: status.chargeCurrent, unit: "A", decimals: 0)
            }

            if let minutes = status.minutesToFull, minutes > 0 {
                HStack(spacing: 6) {
                    Image(systemName: "clock")
                        .font(.system(size: 11))
                    Text("预计 \(formatDuration(minutes)) 充满")
                        .font(.system(size: 12))
                }
                .foregroundStyle(Theme.textSecondary(scheme))
            }
        }
        .padding(Metrics.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ChineseColor.piaoSe.opacity(scheme == .dark ? 0.10 : 0.55))
        .clipShape(RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous))
    }

    private func chargeItem(_ title: String, value: Double?, unit: String, decimals: Int) -> some View {
        VStack(spacing: 4) {
            Text(value.map { String(format: "%.\(decimals)f", $0) } ?? "--")
                .font(.system(size: 18, weight: .medium, design: .rounded))
                .foregroundStyle(Theme.textPrimary(scheme))
                .monospacedDigit()
            Text("\(title) \(unit)")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textTertiary(scheme))
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - 指标网格

    private func metricsGrid(_ status: VehicleStatus) -> some View {
        LazyVGrid(
            columns: [GridItem(.flexible(), spacing: Metrics.sectionSpacing),
                      GridItem(.flexible(), spacing: Metrics.sectionSpacing)],
            spacing: Metrics.sectionSpacing
        ) {
            StatCard(title: "车内温度", icon: "thermometer.medium") {
                StatValue(
                    value: status.interiorTemp.map { String(format: "%.1f", $0) } ?? "--",
                    unit: "°C"
                )
            }
            StatCard(title: "车外温度", icon: "thermometer.sun") {
                StatValue(
                    value: status.exteriorTemp.map { String(format: "%.1f", $0) } ?? "--",
                    unit: "°C"
                )
            }
            StatCard(title: "平均能耗", icon: "chart.line.downtrend.xyaxis") {
                StatValue(
                    value: status.avgConsumption.map { String(format: "%.1f", $0) } ?? "--",
                    unit: "kWh/100km"
                )
            }
            StatCard(title: "12V 电瓶", icon: "battery.100") {
                StatValue(
                    value: status.battery12vVoltage.map { String(format: "%.1f", $0) } ?? "--",
                    unit: "V"
                )
            }
        }
    }

    // MARK: - 胎压

    private func tyreCard(_ status: VehicleStatus) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text("胎压")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary(scheme))

                // 单位从每格重复四次提到标题旁
                Text("kPa")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary(scheme))

                Spacer()

                if status.tyreWarning == true {
                    Label("异常", systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(ChineseColor.statusBad)
                }
            }

            // 一行四列：标签在上、数值在下
            LazyVGrid(columns: tyreColumns, spacing: 8) {
                tyreItem("左前", status.tyreFrontLeft)
                tyreItem("右前", status.tyreFrontRight)
                tyreItem("左后", status.tyreRearLeft)
                tyreItem("右后", status.tyreRearRight)
            }
        }
        .padding(Metrics.cardPadding)
        .background(Theme.surface(scheme))
        .clipShape(RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous))
    }

    private var tyreColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 8), count: 4)
    }

    private func tyreItem(_ position: String, _ value: Double?) -> some View {
        // 正常胎压区间（kPa）—— 低于 220 或高于 280 视为异常
        let isAbnormal = value.map { $0 < 220 || $0 > 280 } ?? false

        return VStack(spacing: 3) {
            Text(position)
                .font(.system(size: 10))
                .foregroundStyle(Theme.textTertiary(scheme))

            Text(value.map { String(format: "%.0f", $0) } ?? "--")
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .foregroundStyle(isAbnormal ? ChineseColor.statusBad : Theme.textPrimary(scheme))
                .monospacedDigit()
        }
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity)
        .background(Theme.surfaceAlt(scheme).opacity(0.55))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: - 车身状态

    private func statusCard(_ status: VehicleStatus) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("车身状态")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.textPrimary(scheme))

            LazyVGrid(
                columns: [GridItem(.flexible(), spacing: Metrics.sectionSpacing),
                          GridItem(.flexible(), spacing: Metrics.sectionSpacing)],
                spacing: Metrics.sectionSpacing
            ) {
                StatusChip(
                    title: "车门",
                    isGood: status.isLocked == true,
                    goodText: "已锁",
                    badText: "未锁",
                    icon: status.isLocked == true ? "lock.fill" : "lock.open.fill"
                )
                StatusChip(
                    title: "空调",
                    isGood: status.climateOn == true,
                    goodText: "开启",
                    badText: "关闭",
                    icon: "snowflake",
                    // 空调开启是中性状态，不用告警色
                    neutral: true
                )
                StatusChip(
                    title: "车窗",
                    isGood: !hasOpenWindow(status),
                    goodText: "已关",
                    badText: "未关",
                    icon: "car.window.left"
                )
                StatusChip(
                    title: "后备箱",
                    isGood: status.trunkOpen != true,
                    goodText: "已关",
                    badText: "开启",
                    icon: "car.side.rear.open"
                )
            }
        }
        .padding(Metrics.cardPadding)
        .background(Theme.surface(scheme))
        .clipShape(RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous))
    }

    private func hasOpenWindow(_ status: VehicleStatus) -> Bool {
        (status.windows ?? [:]).values.contains(true)
    }

    // MARK: - 底部说明

    private var footerNote: some View {
        VStack(spacing: 4) {
            if let lastRefresh = store.lastRefresh {
                Text("更新于 \(lastRefresh.formatted(date: .omitted, time: .standard))")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary(scheme))
            }
            Text("数据来自非官方接口，仅供参考")
                .font(.system(size: 10))
                .foregroundStyle(Theme.textTertiary(scheme).opacity(0.8))
        }
        .padding(.top, 4)
    }

    // MARK: - 空态

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "car.side")
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(Theme.textTertiary(scheme))

            Text("尚未获取到车辆数据")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Theme.textSecondary(scheme))

            if let error = store.errorMessage {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundStyle(ChineseColor.statusBad)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }

            Text("请检查服务端是否启动，以及设置中的地址是否正确")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textTertiary(scheme))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            Button("重新加载") {
                Task { await store.refresh() }
            }
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(ChineseColor.xiangYaBai)
            .padding(.horizontal, 22)
            .padding(.vertical, 10)
            .background(Theme.accent(scheme))
            .clipShape(Capsule())
            .padding(.top, 4)
        }
        .padding(.top, 60)
    }

    // MARK: - 格式化

    private func formatDistance(_ km: Double) -> String {
        km >= 10000
            ? String(format: "%.1f 万 km", km / 10000)
            : String(format: "%.0f km", km)
    }

    private func formatDuration(_ minutes: Double) -> String {
        let total = Int(minutes)
        if total < 60 { return "\(total) 分钟" }
        let hours = total / 60
        let mins = total % 60
        return mins == 0 ? "\(hours) 小时" : "\(hours) 小时 \(mins) 分"
    }
}
