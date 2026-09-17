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
    @State private var model = ChargesViewModel()
    @State private var showImporter = false
    @State private var showClearConfirm = false

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: Metrics.sectionSpacing) {
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
                .padding(.horizontal, Metrics.screenPadding)
                .padding(.bottom, 24)
            }
            .background(Theme.background(scheme))
            .navigationTitle("充电")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
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
                    }
                }
            }
            .refreshable { await model.load() }
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
            .overlay(alignment: .bottom) {
                if let toast = model.toast {
                    Text(toast)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(ChineseColor.xiangYaBai)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(ChineseColor.xuanQing.opacity(0.94))
                        .clipShape(Capsule())
                        .padding(.bottom, 20)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.25), value: model.toast)
        }
        .task { await model.load() }
    }

    // MARK: - 总额卡片

    private var totalCard: some View {
        VStack(spacing: 14) {
            VStack(spacing: 4) {
                Text("累计充电消费")
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
