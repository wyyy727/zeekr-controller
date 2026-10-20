//
//  ChargesView.swift
//  ZeekrDash
//
//  充电消费
//

import Charts
import SwiftUI
import UniformTypeIdentifiers

/// 充电消费页：跨服务商消费汇总
struct ChargesView: View {

    @Environment(\.colorScheme) private var scheme
    @Environment(AppStore.self) private var store
    @State private var model = ChargesViewModel()
    @State private var showImporter = false
    @State private var showClearConfirm = false

    var body: some View {
        // 页面标题与底部导航重复，已移除；顶部右上角为数据来源徽标
        NavigationStack {
            ScreenContainer(modeText: store.modeBadgeText, trailingAccessory: { historyMenu }) {
                // 附近充电站与消费账单是**两块独立的数据**（前者实时、后者是
                // 导入的历史），所以它必须在空态判断**之外**渲染 ——
                // 没导入过账单，不代表看不到"附近哪能充、现在多少钱"，
                // 而那恰恰是这一页最有用的信息。
                //
                // 未登录时不显示：服务端会拒绝 /api/stations，放出卡片只会
                // 诱导用户点一个必然失败的按钮，那比不显示更糟。
                if !store.needsLogin {
                    NearbyStationsCard()
                }

                // 预约充电计划：与能力集同一次请求返回（/api/vehicle/capability），
                // 取不到就不渲染 —— 不编造"已启用"。
                if let plan = store.chargePlan, plan.hasContent {
                    chargePlanCard(plan)
                }

                if model.isLoading && model.summary == nil {
                    LoadingView(text: "正在加载消费数据")
                        .padding(.top, 60)
                } else if model.totalCount == 0 {
                    emptyState
                } else {
                    totalCard
                    providerChart
                    monthlyChart
                    recordList
                }

                // 电费相关高级功能先占位（老板要求暂搁置）
                upcomingSection
            }
            .toolbar(.hidden, for: .navigationBar)
            .fileImporter(
                isPresented: $showImporter,
                allowedContentTypes: [.commaSeparatedText, .plainText, .spreadsheet],
                allowsMultipleSelection: false
            ) { result in
                Task { await handleImport(result) }
            }
            .confirmationDialog(
                "确定清空所有充电消费记录？",
                isPresented: $showClearConfirm,
                titleVisibility: .visible
            ) {
                Button("清空", role: .destructive) {
                    Task { await model.clear() }
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("此操作不可撤销，建议先导出备份")
            }
        }
        .overlay(alignment: .bottom) {
            if let toast = model.toast {
                ToastBubble(text: toast)
                    .padding(.bottom, 110)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.25), value: model.toast)
        .task { await model.load() }
    }

    // MARK: - 账单操作菜单

    private var historyMenu: some View {
        Menu {
            Button {
                showImporter = true
            } label: {
                Label("导入账单", systemImage: "square.and.arrow.down")
            }

            Button(role: .destructive) {
                showClearConfirm = true
            } label: {
                Label("清空数据", systemImage: "trash")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 17))
                .foregroundStyle(Theme.textSecondary(scheme))
                .frame(width: Metrics.minTouchTarget, height: 32)
                .contentShape(Rectangle())
        }
    }

    // MARK: - 总额卡片

    /// 统计口径说明。
    ///
    /// 服务端保证总额 / 笔数 / 月度 / 服务商分布同属一个统计窗口，
    /// 这里把窗口长度标出来，避免把「累计」误读成"全历史"
    /// （月度图只画最近几个月，两者并排容易让人以为同范围）。
    private var totalScopeCaption: String {
        guard let months = model.summary?.windowMonths else { return "累计充电消费" }
        return "累计充电消费 · 近 \(months) 个月"
    }

    private var totalCard: some View {
        VStack(spacing: 14) {
            VStack(spacing: 4) {
                Text(totalScopeCaption)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textTertiary(scheme))
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text("¥")
                        .font(.system(size: 16, weight: .regular))
                        .foregroundStyle(Theme.textSecondary(scheme))
                    Text(String(format: "%.2f", model.totalAmount))
                        .font(.system(size: 36, weight: .medium, design: .rounded))
                        .foregroundStyle(Theme.textPrimary(scheme))
                        .monospacedDigit()
                }
            }

            Divider().overlay(Theme.separator(scheme))

            HStack(spacing: 0) {
                totalItem("笔数", value: "\(model.totalCount)")
                // 与网页一致显示「总电量」；「覆盖服务商」是 iOS 多出来的一项，保留
                totalItem(
                    "总电量",
                    value: model.totalEnergyKwh.map { String(format: "%.1f", $0) } ?? "--"
                )
                totalItem("覆盖服务商", value: "\(model.providerCount)")
                totalItem(
                    "平均单价",
                    value: model.avgUnitPrice.map { String(format: "%.2f", $0) } ?? "--"
                )
            }
        }
        .padding(Metrics.cardPadding)
        .background(Theme.surface(scheme))
        .clipShape(RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous))
    }

    private func totalItem(_ title: String, value: String) -> some View {
        VStack(spacing: 3) {
            Text(value)
                .font(.system(size: 17, weight: .medium, design: .rounded))
                .foregroundStyle(Theme.textPrimary(scheme))
                .monospacedDigit()
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(Theme.textTertiary(scheme))
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - 预约充电计划

    /// 预约充电（只读展示）。
    ///
    /// 与 `preview/index.html` 的 `chargePlanCard()` 对齐：启用状态、起止时间、
    /// 目标电量、当前电量。**不做编辑** —— 官方 App 里改计划要发另一组命令，
    /// 那部分没验证过，这里不假装能改。
    private func chargePlanCard(_ plan: ChargePlan) -> some View {
        let on = plan.enabled == true
        let socText: String = {
            guard let soc = store.vehicleStatus?.soc else { return "--" }
            return "\(Int(soc.rounded()))%"
        }()

        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("预约充电")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary(scheme))

                Spacer(minLength: 8)

                // 未启用时不用红/绿判断"好坏" —— 没开预约不是故障
                Text(on ? (plan.mode.map { "已启用 · \($0)" } ?? "已启用") : "未启用")
                    .font(.system(size: 11))
                    .foregroundStyle(on ? ChineseColor.statusGood : Theme.textTertiary(scheme))
            }

            LazyVGrid(
                columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)],
                spacing: 8
            ) {
                planItem("开始时间", plan.startTime ?? "--", dimmed: !on)
                planItem("结束时间", plan.endTime ?? "--", dimmed: !on)
                planItem("目标电量", plan.targetSoc.map { "\(Int($0.rounded()))%" } ?? "--", dimmed: !on)
                planItem("当前电量", socText, dimmed: false)
            }
        }
        .padding(Metrics.cardPadding)
        .background(Theme.surface(scheme))
        .clipShape(RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous))
    }

    private func planItem(_ title: String, _ value: String, dimmed: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(Theme.textTertiary(scheme))

            Text(value)
                .font(.system(size: 15, weight: .medium, design: .rounded))
                // 未启用时计划项灰掉：避免把"计划里的 23:30"看成"现在就会充"
                .foregroundStyle(dimmed ? Theme.textTertiary(scheme) : Theme.textPrimary(scheme))
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Theme.surfaceAlt(scheme).opacity(0.55))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: - 服务商分布

    private var providerChart: some View {
        let stats = model.providerStats

        return ChartCard(title: "服务商分布", subtitle: "元") {
            Chart(stats) { stat in
                BarMark(
                    x: .value("金额", stat.amount ?? 0),
                    y: .value("服务商", stat.displayName)
                )
                .foregroundStyle(providerColor(stat.provider))
                .cornerRadius(3)
                .annotation(position: .trailing, alignment: .leading, spacing: 4) {
                    Text(String(format: "%.0f", stat.amount ?? 0))
                        .font(.system(size: 9))
                        .foregroundStyle(Theme.textTertiary(scheme))
                }
            }
            .chartXAxis(.hidden)
            .chartYAxis {
                AxisMarks(position: .leading) { _ in
                    AxisValueLabel()
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.textSecondary(scheme))
                }
            }
        }
    }

    /// 各服务商分配不同传统色，视觉可区分
    private func providerColor(_ provider: ChargeProvider?) -> Color {
        switch provider {
        case .zeekr:      return ChineseColor.tianQing
        case .starCharge: return ChineseColor.dianLan
        case .teld:       return ChineseColor.zhuQing
        case .stateGrid:  return ChineseColor.qunQing
        case .eCharging:  return ChineseColor.qingBi
        default:          return ChineseColor.daiSe.opacity(0.6)
        }
    }

    // MARK: - 月度趋势

    private var monthlyChart: some View {
        let stats = model.monthlyStats

        return ChartCard(title: "月度消费", subtitle: "元") {
            Chart(stats) { stat in
                BarMark(
                    x: .value("月份", stat.shortMonth),
                    y: .value("金额", stat.amount ?? 0)
                )
                .foregroundStyle(Theme.accent(scheme).opacity(0.82))
                .cornerRadius(3)
            }
            .chartXAxis {
                AxisMarks { _ in
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

    // MARK: - 明细列表

    private var recordList: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("消费明细")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.textPrimary(scheme))

            ForEach(model.records) { record in
                ChargeRow(record: record, color: providerColor(record.provider))
                if record.id != model.records.last?.id {
                    Divider().overlay(Theme.separator(scheme))
                }
            }
        }
        .padding(Metrics.cardPadding)
        .background(Theme.surface(scheme))
        .clipShape(RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous))
    }

    // MARK: - 待上线功能（占位）

    private var upcomingSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("即将上线")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.textPrimary(scheme))

            ForEach(upcomingFeatures, id: \.title) { feature in
                HStack(spacing: 10) {
                    Image(systemName: feature.icon)
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.textTertiary(scheme))
                        .frame(width: 22)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(feature.title)
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.textSecondary(scheme))
                        Text(feature.detail)
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textTertiary(scheme))
                    }

                    Spacer()

                    SoonBadge()
                }
                .padding(.vertical, 6)
            }
        }
        .padding(Metrics.cardPadding)
        .background(Theme.surface(scheme).opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous))
    }

    private var upcomingFeatures: [(title: String, detail: String, icon: String)] {
        [
            ("充电量统计", "接入服务商订单后可统计 kWh 与单价", "bolt.horizontal"),
            ("动态电价", "按峰谷时段与场站计算实际电费", "yensign.circle"),
            ("智能充电", "在最低电价时段自动充电", "clock.arrow.circlepath"),
        ]
    }

    // MARK: - 空态

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(Theme.textTertiary(scheme))

            Text("还没有充电消费数据")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Theme.textSecondary(scheme))

            VStack(alignment: .leading, spacing: 6) {
                stepRow("1", "从支付宝导出账单（CSV 格式）")
                stepRow("2", "从微信导出账单（Excel/CSV 格式）")
                stepRow("3", "点下方按钮导入，自动识别充电消费")
            }
            .padding(.horizontal, 8)
            .padding(.top, 4)

            Button {
                showImporter = true
            } label: {
                Label("导入账单", systemImage: "square.and.arrow.down")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(ChineseColor.xiangYaBai)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 11)
                    .background(Theme.accent(scheme))
                    .clipShape(Capsule())
            }
            .padding(.top, 4)

            Text("微信账单单次最多导出 90 天，历史需分批导入")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textTertiary(scheme))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
        .padding(.top, 40)
    }

    private func stepRow(_ index: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(index)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(ChineseColor.xiangYaBai)
                .frame(width: 16, height: 16)
                .background(Theme.accent(scheme))
                .clipShape(Circle())
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary(scheme))
        }
    }

    // MARK: - 导入

    private func handleImport(_ result: Result<[URL], Error>) async {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            await model.importBill(from: url)
        case .failure(let error):
            model.showToast("选择文件失败：\(error.localizedDescription)")
        }
    }
}

// MARK: - 单条消费记录

private struct ChargeRow: View {

    let record: ChargeRecord
    let color: Color

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 12) {
            // 服务商色标
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(color)
                .frame(width: 3, height: 32)

            VStack(alignment: .leading, spacing: 3) {
                Text(record.provider?.displayName ?? "其他")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.textPrimary(scheme))

                HStack(spacing: 6) {
                    Text(dateText)
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.textTertiary(scheme))

                    if let channel = record.channel {
                        Text("·")
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.textTertiary(scheme))
                        Text(channel.displayName)
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.textTertiary(scheme))
                    }
                }

                if let merchant = record.merchant, !merchant.isEmpty {
                    Text(merchant)
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.textTertiary(scheme).opacity(0.85))
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)

            VStack(alignment: .trailing, spacing: 1) {
                Text(String(format: "¥%.2f", record.amount ?? 0))
                    .font(.system(size: 15, weight: .medium, design: .rounded))
                    .foregroundStyle(Theme.textPrimary(scheme))
                    .monospacedDigit()

                if let energy = record.energyKwh {
                    Text(String(format: "%.1f kWh", energy))
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.textTertiary(scheme))
                }
            }
        }
        .padding(.vertical, 9)
    }

    private var dateText: String {
        guard let date = record.timestamp else { return "--" }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }
}
