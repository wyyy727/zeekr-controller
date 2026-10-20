//
//  DashboardView.swift
//  ZeekrDash
//
//  车况主页
//

import SwiftUI
import UIKit

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
                if store.needsLogin {
                    // 已连上服务端但还没登录 —— 停在登录引导，不碰任何数据接口
                    loginWall
                } else if let status = store.vehicleStatus {
                    headerCard(status)

                    if status.isCharging == true {
                        chargingCard(status)
                    }

                    metricsGrid(status)
                    tyreCard(status)
                    // 「车身状态」保持 2×2，不随胎压一起改横排
                    statusCard(status)
                    locationCard(store.vehicleLocation)
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

            // 一行四列：标签在上、数值在下，胎温作为副行（与 index.html 一致）
            LazyVGrid(columns: tyreColumns, spacing: 8) {
                tyreItem("左前", status.tyreFrontLeft, status.tyreTempFrontLeft)
                tyreItem("右前", status.tyreFrontRight, status.tyreTempFrontRight)
                tyreItem("左后", status.tyreRearLeft, status.tyreTempRearLeft)
                tyreItem("右后", status.tyreRearRight, status.tyreTempRearRight)
            }
        }
        .padding(Metrics.cardPadding)
        .background(Theme.surface(scheme))
        .clipShape(RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous))
    }

    private var tyreColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 8), count: 4)
    }

    private func tyreItem(_ position: String, _ value: Double?, _ temp: Double? = nil) -> some View {
        /* 正常胎压区间（kPa）。
           门限按**本车实测**放宽到 240–320：本车四轮约 299–305 kPa（2.99–3.05 bar），
           旧的 220–280 会把四个正常值全判成异常 —— 全是红的反而看不出真问题。 */
        let isAbnormal = value.map { $0 < 240 || $0 > 320 } ?? false

        return VStack(spacing: 3) {
            Text(position)
                .font(.system(size: 10))
                .foregroundStyle(Theme.textTertiary(scheme))

            Text(value.map { String(format: "%.0f", $0) } ?? "--")
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                // 正常值用靛蓝（读数感、不刺眼）；越界用藤黄表示"该看一眼"，
                // 朱砂红留给车门未关这类必须立刻处理的状态
                .foregroundStyle(isAbnormal ? ChineseColor.tengHuang : ChineseColor.dianLan)
                .monospacedDigit()

            // 胎温副行：拿不到时不占位显示，避免出现无意义的 "----"
            if let temp {
                Text(String(format: "%.0f°", temp))
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textTertiary(scheme))
                    .monospacedDigit()
            }
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
                // 「锁车」与「车门」是两件事，此前 iOS 把锁车状态挂在「车门」标题下，
                // 会让人以为"车门已关好"。网页一直是两个独立 chip，这里对齐。
                StatusChip(
                    title: "锁车",
                    isGood: status.isLocked == true,
                    goodText: "已锁",
                    badText: status.isLocked == nil ? "未知" : "未锁",
                    icon: status.isLocked == true ? "lock.fill" : "lock.open.fill",
                    neutral: status.isLocked == nil
                )
                // 四门聚合口径（与网页 `doorOpen3` 一致）：任一扇开即「有门未关」。
                // doors 为 nil 表示网关未提供 —— 显示「未知」，绝不默认成「全部关闭」。
                StatusChip(
                    title: "车门",
                    isGood: status.doors == nil || !hasOpenDoor(status),
                    goodText: status.doors == nil ? "未知" : "全部关闭",
                    badText: "有门未关",
                    icon: "car.side",
                    neutral: status.doors == nil
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
                // 车窗状态在 live 模式下拿不到（网关字段名尚未确认）。
                // 没有数据时显式显示「未知」并走中性配色，而不是默认成「已关」——
                // 后者等于把"不知道"说成"没问题"，是把无数据伪装成好消息。
                StatusChip(
                    title: "车窗",
                    isGood: status.windows == nil || !hasOpenWindow(status),
                    goodText: status.windows == nil ? "未知" : "已关",
                    badText: "未关",
                    icon: "car.window.left",
                    neutral: status.windows == nil
                )
                StatusChip(
                    title: "后备箱",
                    isGood: status.trunkOpen != true,
                    goodText: status.trunkOpen == nil ? "未知" : "已关",
                    badText: "开启",
                    icon: "car.side.rear.open",
                    neutral: status.trunkOpen == nil
                )
                // 前备箱：真车字段名是 engineHoodOpenStatus（不是 frunkOpenStatus），
                // 后端已映射到 frunkOpen；网页早有这个 chip，iOS 这边此前漏了。
                StatusChip(
                    title: "前备箱",
                    isGood: status.frunkOpen != true,
                    goodText: status.frunkOpen == nil ? "未知" : "已关",
                    badText: "开启",
                    icon: "car.side.front.open",
                    neutral: status.frunkOpen == nil
                )
            }
        }
        .padding(Metrics.cardPadding)
        .background(Theme.surface(scheme))
        .clipShape(RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous))
    }

    private func hasOpenDoor(_ status: VehicleStatus) -> Bool {
        // 与 hasOpenWindow 同一写法：元素是 Bool?，nil（网关未给单个门）
        // 不能算作"开着"，但整体 nil 已在调用处单独判为「未知」。
        (status.doors ?? [:]).values.contains { $0 == true }
    }

    private func hasOpenWindow(_ status: VehicleStatus) -> Bool {
        // 值本身是 Bool?（服务端可能返回 null 表示"未知"），
        // 用闭包判断而不是 contains(true)，避免依赖可选值提升。
        (status.windows ?? [:]).values.contains { $0 == true }
    }

    // MARK: - 车辆位置

    /// 车辆位置卡。
    ///
    /// 三条底线（与网页 `vehicleLocationCard()` 一致）：
    /// 1. **位置不是实时的** —— 标题右侧必须写「最后上报 X」，否则会被当成"车现在就在这"；
    ///    车静止时网关不更新坐标（实测 15 条快照只有 3 个位置点）。
    /// 2. **没配地图 key ≠ 没有位置** —— 照常显示坐标，只是没有地址与地图。
    /// 3. 地图取不到就只不显示图，地址与坐标照常可读。
    private func locationCard(_ location: VehicleLocation?) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline) {
                Text("车辆位置")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary(scheme))

                Spacer(minLength: 8)

                if let raw = location?.reportedAt, !raw.isEmpty {
                    Text("最后上报 \(formatReportedAt(raw))")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textTertiary(scheme))
                }
            }

            if let location, location.hasCoordinate {
                if let data = store.locationMapData,
                   let image = UIImage(data: data) {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(maxWidth: .infinity)
                        .frame(height: 148)
                        .clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }

                Text(location.displayAddress ?? mapUnavailableText(location))
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(location.displayAddress == nil
                                     ? Theme.textSecondary(scheme)
                                     : Theme.textPrimary(scheme))
                    .fixedSize(horizontal: false, vertical: true)

                if let coordinate = location.coordinateText {
                    Text(coordinate)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.textTertiary(scheme))
                }

                if let secondary = location.secondaryAddress {
                    Text(secondary)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textTertiary(scheme))
                        .fixedSize(horizontal: false, vertical: true)
                }

                if location.displayAddress == nil {
                    Text(mapUnavailableHint(location))
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textTertiary(scheme))
                        .fixedSize(horizontal: false, vertical: true)
                }

                Text("位置取自车辆最后一次上报，车辆移动后可能不会立即更新。")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary(scheme).opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
            } else if let location, location.available == false {
                // 明确说"车没上报位置"，而不是显示两个 0
                Text(location.reason ?? "车辆尚未上报位置")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary(scheme))
            } else if let error = store.locationError {
                // 与"还没加载"区分开：请求一直失败时不能永远显示「正在获取位置…」
                Text(error)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary(scheme))
            } else {
                Text("正在获取位置…")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textTertiary(scheme))
            }
        }
        .padding(Metrics.cardPadding)
        .background(Theme.surface(scheme))
        .clipShape(RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous))
    }

    /// 没有地址时的标题文案。
    ///
    /// 必须区分两种情况 —— 它们的处理方式完全不同：
    /// · 没配 key：去 `.env` 填 `TENCENT_MAP_KEY`
    /// · 配了但取不到：多半是第三方额度用完 / 网络问题，改配置没用
    /// 统一显示「未配置地图服务」会把人引到错误的方向上。
    private func mapUnavailableText(_ location: VehicleLocation) -> String {
        location.mapAvailable == true ? "地址暂时取不到" : "未配置地图服务"
    }

    private func mapUnavailableHint(_ location: VehicleLocation) -> String {
        if location.mapAvailable == true {
            return "地图服务已配置，但这次没取到地址（可能是第三方额度用完或网络问题）。稍后会自动重试。"
        }
        return "尚未配置腾讯地图 key，仅显示坐标。在服务端 .env 填入 TENCENT_MAP_KEY 并重启，即可显示地址与地图。"
    }

    /// 把服务端透传的 `yyyy-MM-dd HH:mm:ss` 变成「今天 10:48」/「10月19日 10:48」。
    /// 解析失败就原样显示 —— 宁可难看，也不要把时间吞掉（时间本身是有意义的）。
    private func formatReportedAt(_ raw: String) -> String {
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.timeZone = TimeZone(identifier: "Asia/Shanghai")
        parser.dateFormat = "yyyy-MM-dd HH:mm:ss"

        guard let date = parser.date(from: raw) else { return raw }

        let isToday = Calendar.current.isDateInToday(date)
        let output = DateFormatter()
        output.locale = Locale(identifier: "zh_CN")
        output.timeZone = TimeZone(identifier: "Asia/Shanghai")
        output.dateFormat = isToday ? "HH:mm" : "M月d日 HH:mm"
        let text = output.string(from: date)
        return isToday ? "今天 \(text)" : text
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

    // MARK: - 未登录引导

    /// 明确说明「不是页面坏了，是还没登录」，并给出去登录的入口
    private var loginWall: some View {
        VStack(spacing: 12) {
            Image(systemName: "person.crop.circle.badge.questionmark")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(Theme.textTertiary(scheme))

            Text("需要先登录极氪账号")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Theme.textPrimary(scheme))

            Text("服务端已连上（真实数据模式）。\n登录前不会请求任何车况 / 行程 / 充电接口。")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textTertiary(scheme))
                .multilineTextAlignment(.center)
                .lineSpacing(3)

            Button {
                store.selectedTab = .settings
            } label: {
                Text("去登录")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(ChineseColor.xiangYaBai)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 10)
                    .background(Theme.accent(scheme))
                    .clipShape(Capsule())
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
        .padding(.horizontal, 20)
        .background(Theme.surface(scheme))
        .clipShape(RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous))
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

    /// 里程一律显示原始公里数 —— 不做「万」换算：15545 被压成「1.6 万」后
    /// 既有精度损失，也无法与官方 App 的读数直接比对。
    private func formatDistance(_ km: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        formatter.groupingSeparator = ","
        formatter.maximumFractionDigits = 0
        formatter.roundingMode = .halfUp
        let text = formatter.string(from: NSNumber(value: km)) ?? String(format: "%.0f", km)
        return "\(text) km"
    }

    private func formatDuration(_ minutes: Double) -> String {
        let total = Int(minutes)
        if total < 60 { return "\(total) 分钟" }
        let hours = total / 60
        let mins = total % 60
        return mins == 0 ? "\(hours) 小时" : "\(hours) 小时 \(mins) 分"
    }
}
