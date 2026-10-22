//
//  ChargesView.swift
//  ZeekrDash
//
//  充电页：充入电量（官方流水）+ 金额补录（截图识别 / 手工录入）
//

import Charts
import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// 充电页
///
/// 与 `preview/index.html` 的充电页一一对应，卡片顺序与口径都保持一致：
///   1. 附近充电站（实时、要定位）；
///   2. **充入电量**：一张卡 = 月度大数（左电量 / 右当月与累计金额）+ 当月逐次图
///      （柱=本次电量、折线=本次时长）+ 直/交流电量；
///   3. 充电记录（逐笔）；
///   4. 金额补录（金额只能靠截图识别 / 手工补录，**不显示估算数字**）。
struct ChargesView: View {

    @Environment(\.colorScheme) private var scheme
    @Environment(AppStore.self) private var store
    @State private var model = ChargesViewModel()

    @State private var showMonthPicker = false
    @State private var showImporter = false
    @State private var showOcrReview = false
    @State private var showManualEntry = false
    @State private var showPayments = false

    var body: some View {
        NavigationStack {
            ScreenContainer(modeText: store.modeBadgeText) {
                // 附近充电站与充入电量是**两块独立的数据**（前者实时、后者是本地历史），
                // 所以它必须在空态判断**之外**渲染 —— 没充过电，不代表看不到
                // "附近哪能充、现在多少钱"，而那恰恰是这一页最有用的信息。
                //
                // 未登录时不显示：服务端会拒绝 /api/stations，放出卡片只会
                // 诱导用户点一个必然失败的按钮，那比不显示更糟。
                if !store.needsLogin {
                    NearbyStationsCard()
                }

                monthRow

                if let errorMessage = model.errorMessage {
                    ErrorBanner(message: errorMessage) {
                        Task { await model.load() }
                    }
                }

                if model.isLoading && model.stat == nil {
                    LoadingView(text: "正在读取充电流水")
                        .padding(.top, 60)
                } else {
                    energyCard
                    if !model.records.isEmpty {
                        recordList
                    }
                    costCard
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            // 下拉 = 现在就去拉一次（原生手势替代已移除的「同步」按钮）
            .refreshable { await model.refresh() }
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
        /* 充电中 → 未充电：这是唯一会产生新充电流水的时刻。
           车况轮询间隔本来就跟着充电状态走（充电中 60 秒一次），跳变一定抓得到。 */
        .onChange(of: store.isCharging) { wasCharging, isCharging in
            if wasCharging && !isCharging {
                Task { await model.syncAfterChargeEnd() }
            }
        }

        // 月份选择：与行程页共用同一个滚轮（MonthPickerSheet）
        .sheet(isPresented: $showMonthPicker) {
            MonthPickerSheet(months: model.monthOptions, selection: model.selectedMonth) { picked in
                Task { await model.select(month: picked) }
            }
        }
        // 截图识别：选图 → 服务端识别 → **先核对再入库**
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.image],
            allowsMultipleSelection: false
        ) { result in
            Task {
                guard case .success(let urls) = result, let url = urls.first else { return }
                await model.runOcr(fileURL: url)
                if model.ocrResult != nil { showOcrReview = true }
            }
        }
        .sheet(isPresented: $showOcrReview) {
            if let payload = model.ocrResult {
                OcrReviewSheet(payload: payload) { rows in
                    await model.commitOcr(imageSha8: payload.imageSha8, rows: rows)
                }
            }
        }
        .sheet(isPresented: $showManualEntry) {
            ManualPaymentSheet { amount, paidAt, energyKwh, stationName in
                await model.addManual(
                    amount: amount,
                    paidAt: paidAt,
                    energyKwh: energyKwh,
                    stationName: stationName
                )
            }
        }
        .sheet(isPresented: $showPayments) {
            PaymentsSheet(payments: model.payments) { paymentId, sessionId in
                await model.link(paymentId: paymentId, sessionId: sessionId)
            } onUnlink: { paymentId in
                await model.unlink(paymentId: paymentId)
            }
        }
    }

    // MARK: - 月份行

    /// 左侧「统计月份」+ 右侧「同步时间小字 + 月份按钮」。
    ///
    /// **没有同步按钮**：时机全自动（空库 / 跨天 / 充电结束），
    /// 所以这行小字是唯一的数据新鲜度线索，必须看得见；
    /// 想立刻刷新就下拉（原生手势，不占界面位置）。
    private var monthRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "calendar")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textTertiary(scheme))
            Text("统计月份")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textTertiary(scheme))
            if model.isLoading {
                Text("· 更新中")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textTertiary(scheme))
            }

            Spacer(minLength: 8)

            Text(model.isSyncing ? "同步中…" : model.lastSyncText)
                .font(.system(size: 11))
                .foregroundStyle(Theme.textTertiary(scheme))
                .monospacedDigit()

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
                .frame(minHeight: Metrics.minTouchTarget)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - 充入电量（一张卡）

    /// 大数 + 月度趋势图合成**一张卡**。
    ///
    /// 原来这是两张卡，但它们是同一笔账的两个切面：分开摆，最右边那根柱子和
    /// 上面的大数看着像两个数。合进一张卡后，把所选月份那根柱子高亮、其余压暗 ——
    /// "大数对应哪根"不用再靠月份标签去对。
    private var energyCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("充入电量")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary(scheme))
                Spacer(minLength: 8)
                Text(model.selectedMonthLabel)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary(scheme))
            }

            if let stat = model.stat, (stat.count ?? 0) > 0 {
                heroBlock(stat)
                Divider().overlay(Theme.separator(scheme))
                subBlock(stat)
                if !sessionPoints.isEmpty {
                    legendRow
                    sessionChart
                }
                splitLine(stat)
            } else {
                // 这个月没记录：逐次图没有可画的点，只留空态
                emptyMonthBlock
            }
        }
        .padding(Metrics.cardPadding)
        .background(Theme.surface(scheme))
        .clipShape(RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous))
    }

    /// 左边电量、右边金额 —— 这两个数是同一笔账的两面：
    /// "充了 182 度"和"花了 234 块"分开摆会让人以为是两件事。
    /// 金额只能来自截图识别 / 手工录入，没补录时写「未补录」，绝不编。
    private func heroBlock(_ stat: ChargeMonthStat) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(model.selectedMonthLabel) · 共 \(stat.count ?? 0) 次")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary(scheme))

                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(fmt(stat.totalKwh, 1))
                        .font(.system(size: 33, weight: .medium, design: .rounded))
                        .foregroundStyle(Theme.textPrimary(scheme))
                        .monospacedDigit()
                    Text("度")
                        .font(.system(size: 15, weight: .regular))
                        .foregroundStyle(Theme.textSecondary(scheme))
                }
            }

            Spacer(minLength: 8)

            moneyBlock(stat)
        }
    }

    /// 金额区：一行一条「标签 + 数字」。
    /// 拆成"数字一行、标签一行"要多扫一眼才知道那个数是什么，所以放同一行。
    private func moneyBlock(_ stat: ChargeMonthStat) -> some View {
        VStack(alignment: .trailing, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(model.selectedMonthLabel)金额")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.textTertiary(scheme))
                if let amount = stat.amountTotal {
                    Text("¥" + String(format: "%.2f", amount))
                        .font(.system(size: 21, weight: .semibold, design: .rounded))
                        .foregroundStyle(Theme.textPrimary(scheme))
                        .monospacedDigit()
                } else {
                    // 0 会被读成"这个月一分没花"，所以写「未补录」
                    Text("未补录")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.textTertiary(scheme))
                }
            }

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("累计")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.textTertiary(scheme))
                Text(model.totalAmountText)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.textSecondary(scheme))
                    .monospacedDigit()
            }
        }
    }

    /// 三个副数字**必须同框**：只给总量，"这个月充得多"到底是单次充得满、
    /// 还是充得勤，看不出来。
    private func subBlock(_ stat: ChargeMonthStat) -> some View {
        HStack(spacing: 0) {
            subItem("平均单次", value: fmt(stat.avgKwh, 1), unit: "度")
            subItem("总时长", value: durationText(stat.totalMinutes), unit: nil)
            subItem("平均功率", value: fmt(stat.avgPowerKw, 1), unit: "kW")
        }
    }

    private func subItem(_ title: String, value: String, unit: String?) -> some View {
        VStack(spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value)
                    .font(.system(size: 16, weight: .medium, design: .rounded))
                    .foregroundStyle(Theme.textPrimary(scheme))
                    .monospacedDigit()
                if let unit {
                    Text(unit)
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.textTertiary(scheme))
                }
            }
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(Theme.textTertiary(scheme))
        }
        .frame(maxWidth: .infinity)
    }

    private var emptyMonthBlock: some View {
        VStack(spacing: 8) {
            Image(systemName: "bolt.slash")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(Theme.textTertiary(scheme))
            Text("\(model.selectedMonthLabel)没有充电记录")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Theme.textSecondary(scheme))
            Text("换个日期看看；新流水会在充完电 / 跨天后的自动同步里出现")
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.textTertiary(scheme))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }

    /// 直流 / 交流只留电量，不再各列一次「几次」：
    /// 快充几次 + 慢充几次 = 上面的「共 N 次」，换个说法重复一遍而已。
    /// 但"快充充了多少度、慢充充了多少度"是新信息，压成图下面一行。
    private func splitLine(_ stat: ChargeMonthStat) -> some View {
        let dc = stat.dcKwh ?? 0
        let ac = stat.acKwh ?? 0
        guard dc > 0 || ac > 0 else { return AnyView(EmptyView()) }

        return AnyView(
            Text("直流快充 \(fmt(stat.dcKwh, 1)) 度 · 交流慢充 \(fmt(stat.acKwh, 1)) 度")
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.textTertiary(scheme))
                .monospacedDigit()
                .frame(maxWidth: .infinity, alignment: .leading)
        )
    }

    // MARK: - 当月逐次图

    private var legendRow: some View {
        HStack(spacing: 14) {
            legendDot(ChineseColor.tianQing, "本次电量 · 度")
            legendDot(ChineseColor.tengHuang, "本次时长 · 小时")
            Spacer(minLength: 0)
        }
        .font(.system(size: 11))
    }

    private func legendDot(_ color: Color, _ text: String) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text(text)
                .foregroundStyle(Theme.textTertiary(scheme))
        }
    }

    /// 柱 = 这一次充了多少度（左轴），折线 = 这一次充了多久（右轴）。
    ///
    /// 横轴是**所选月份里的每一次充电**（时间正序），跟着月份筛选走 ——
    /// 这张卡讲的就是"这一个月"，摆一条全年趋势在下面只会让人怀疑看的是哪个月。
    ///
    /// Swift Charts 没有"每系列一套刻度"，所以时长按 `scale` 折算进电量的
    /// 坐标空间，右轴刻度再反向折算回小时显示。峰值压在 ~74% 高度：
    /// 柱顶的数值标注在 ~91%，两组数字才不会叠在一起。
    private var sessionChart: some View {
        let points = sessionPoints
        let axisMax = niceMax(points.map { $0.kwh }.max() ?? 1)
        let maxHours = max(points.compactMap { $0.hours }.max() ?? 0.1, 0.1)
        let scale = (axisMax * 0.74) / maxHours

        return Chart {
            ForEach(points) { point in
                BarMark(
                    x: .value("日期", point.label),
                    y: .value("电量", point.kwh)
                )
                .foregroundStyle(ChineseColor.tianQing)
                .cornerRadius(3)
            }

            ForEach(points) { point in
                if let hours = point.hours {
                    LineMark(
                        x: .value("日期", point.label),
                        y: .value("时长", hours * scale),
                        series: .value("系列", "时长")
                    )
                    .foregroundStyle(ChineseColor.tengHuang)
                    .lineStyle(StrokeStyle(lineWidth: 1.8, lineCap: .round))
                    .interpolationMethod(.monotone)

                    PointMark(
                        x: .value("日期", point.label),
                        y: .value("时长", hours * scale)
                    )
                    .foregroundStyle(ChineseColor.tengHuang)
                    .symbolSize(20)
                }
            }
        }
        .chartYScale(domain: 0...axisMax)
        .chartLegend(.hidden)
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
            AxisMarks(
                position: .trailing,
                values: [0.0, axisMax / 3.0, axisMax * 2.0 / 3.0, axisMax]
            ) { value in
                AxisValueLabel {
                    if let raw = value.as(Double.self), scale > 0 {
                        Text(String(format: "%.1f", raw / scale))
                            .font(.system(size: 9))
                            .foregroundStyle(ChineseColor.tengHuang)
                    }
                }
            }
        }
        .frame(height: 176)
    }

    /// 时间正序（图要从左往右读）。标签 `10-09`；同一天充两次追加 `#2` ——
    /// 重复标签在类目轴上会被当成同一个刻度，Swift Charts 会直接把两根柱子合并。
    private var sessionPoints: [SessionPoint] {
        var seen: [String: Int] = [:]

        return model.records.reversed().map { record in
            let stamp = record.startTime ?? ""
            let base = stamp.count >= 10 ? String(stamp.dropFirst(5).prefix(5)) : stamp
            let key = base.isEmpty ? "--" : base
            let n = (seen[key] ?? 0) + 1
            seen[key] = n

            let minutes = record.durationMin ?? 0
            return SessionPoint(
                id: record.id,
                label: n == 1 ? key : "\(key)#\(n)",
                kwh: record.energyKwh ?? 0,
                hours: minutes > 0 ? minutes / 60 : nil
            )
        }
    }

    /// 纵轴顶端取"好看的整数"再留 10% 余量：峰值 45 → 轴到 55，
    /// 否则柱子几乎顶到框顶，几个月之间读不出差距。
    private func niceMax(_ value: Double) -> Double {
        let v = max(value, 1)
        let exp = floor(log10(v))
        let base = pow(10.0, exp)
        let ratio = v / base
        let step = ratio <= 1 ? 1.0 : (ratio <= 2 ? 2.0 : (ratio <= 5 ? 5.0 : 10.0))
        return step * base * 1.1
    }

    // MARK: - 充电记录

    private var recordList: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("充电记录")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.textPrimary(scheme))

            ForEach(model.records) { record in
                ChargeSessionRow(record: record)
                if record.id != model.records.last?.id {
                    Divider().overlay(Theme.separator(scheme))
                }
            }
        }
        .padding(Metrics.cardPadding)
        .background(Theme.surface(scheme))
        .clipShape(RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous))
    }

    // MARK: - 金额补录

    /// 金额数字已经搬进上面的「充入电量」卡（当月 + 累计），这里**不再重复摆数字**，
    /// 只留三件补录入口 + 一句状态 —— 一块放数、一块放操作，各自只有一件事。
    ///
    /// 立场不变：**一个编出来的数字都不显示**。
    /// 官方接口只给电量（车不知道电价），金额只能来自截图识别 / 手工录入。
    private var costCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("金额补录")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary(scheme))
                Spacer(minLength: 8)
                Text(costBadge)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary(scheme))
            }

            VStack(alignment: .leading, spacing: 4) {
                ForEach(costNotes, id: \.self) { note in
                    Text(note)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.textTertiary(scheme))
                }
            }

            // 三个入口。「截图识别」不是"识别完就完事"：识别结果会弹出核对框，
            // 金额 / 电量 / 归属哪次充电都能改 —— 模型把服务费原价当金额是常事。
            HStack(spacing: 8) {
                costButton("截图识别", systemImage: "doc.text.viewfinder", primary: true) {
                    showImporter = true
                }
                .disabled(!model.canWrite || model.isOcrBusy)

                costButton("手写录入", systemImage: "pencil", primary: false) {
                    showManualEntry = true
                }
                .disabled(!model.canWrite)

                if model.pendingCount > 0 {
                    costButton("待确认 \(model.pendingCount)", systemImage: "questionmark.circle", primary: false) {
                        showPayments = true
                    }
                    .disabled(!model.canWrite)
                }
            }
        }
        .padding(Metrics.cardPadding)
        .background(Theme.surface(scheme))
        .clipShape(RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous))
    }

    private var costBadge: String {
        guard let stat = model.stat else { return "未补录" }
        let priced = stat.amountCount ?? 0
        if priced == 0 { return "未补录" }
        let unpriced = stat.unpricedCount ?? 0
        return unpriced > 0 ? "已补录 \(priced)/\(priced + unpriced) 笔" : "已补全"
    }

    private var costNotes: [String] {
        var notes: [String] = []
        let priced = model.stat?.amountCount ?? 0
        let unpriced = model.stat?.unpricedCount ?? 0

        if priced == 0 {
            notes.append("极氪只给电量，不给金额 —— 车不知道电价，站点也不在充电记录里。"
                         + "补录后上面的「当月金额 / 累计」才会有数。")
        } else {
            let unit = model.stat?.unitPrice == nil
                ? ""
                : "，每度约 ¥\(fmt(model.stat?.unitPrice, 2))"
            if unpriced > 0 {
                notes.append("已补录 \(priced) 笔\(unit)；还有 \(unpriced) 笔"
                             + "（\(fmt(model.stat?.unpricedKwh, 1)) 度）没补，单价只按已补录的算。")
            } else {
                notes.append("已补录 \(priced) 笔，全部有金额\(unit)。")
            }
        }
        if let estimated = model.stat?.estimatedCount, estimated > 0 {
            notes.append("另有 \(estimated) 笔为电价估算，未计入合计与单价。")
        }
        if model.pendingCount > 0 {
            notes.append("有 \(model.pendingCount) 笔金额配不上充电流水，在「待确认」里等你指定。")
        }
        if !model.canWrite {
            notes.append("当前是演示/离线数据，补录入口不可用（没有真实流水可配对）。")
        } else if model.ocrConfigured == false {
            notes.append("截图识别未开启：服务端 .env 填 DEEPSEEK_API_KEY 并重启后可用；"
                         + "在那之前先用手写录入。")
        }
        return notes
    }

    private func costButton(
        _ title: String,
        systemImage: String,
        primary: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .frame(maxWidth: .infinity)
                .frame(minHeight: Metrics.minTouchTarget)
                .foregroundStyle(primary ? Color.white : Theme.textPrimary(scheme))
                .background(primary ? Theme.accent(scheme) : Theme.surfaceAlt(scheme))
                .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        }
        .buttonStyle(.plain)
        .opacity(primary && !model.canWrite ? 0.45 : 1)
    }

    // MARK: - 格式化

    private func fmt(_ value: Double?, _ digits: Int) -> String {
        guard let value else { return "--" }
        return String(format: "%.\(digits)f", value)
    }

    /// 平均时长按"是否超过 1 小时"换单位：统一成分钟会出现 "183"，
    /// 统一成小时又会出现 0.4 这种读不出量级的数。
    private func durationText(_ minutes: Double?) -> String {
        guard let minutes, minutes > 0 else { return "--" }
        let total = Int(minutes.rounded())
        if total < 60 { return "\(total) 分" }
        let h = total / 60
        let m = total % 60
        return m == 0 ? "\(h) 小时" : "\(h) 小时 \(m) 分"
    }
}

/// 当月逐次图的一根柱子 / 一个点
private struct SessionPoint: Identifiable {
    var id: String
    var label: String
    var kwh: Double
    /// 这一次充了多久（小时）；没有时长的记录为 nil，折线在那里断开
    var hours: Double?
}

// MARK: - 单条充电流水

private struct ChargeSessionRow: View {

    let record: ChargeSession

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(record.titleText)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.textPrimary(scheme))
                Text(record.shortTimeText)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textTertiary(scheme))
                    .monospacedDigit()
            }

            Spacer(minLength: 0)

            VStack(alignment: .trailing, spacing: 3) {
                Text("\(String(format: "%.1f", record.energyKwh ?? 0)) 度")
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .foregroundStyle(Theme.textPrimary(scheme))
                    .monospacedDigit()

                HStack(spacing: 6) {
                    if let minutes = record.durationMin, minutes > 0 {
                        Text("\(Int(minutes.rounded())) 分钟")
                    }
                    if let power = record.powerKw {
                        Text(String(format: "%.0f kW", power))
                    }
                    // 金额只在这笔补录过才有 —— 没补录就不显示，绝不填 0
                    if let amount = record.amount {
                        Text("¥" + String(format: "%.2f", amount))
                            .foregroundStyle(Theme.accent(scheme))
                    }
                }
                .font(.system(size: 10))
                .foregroundStyle(Theme.textTertiary(scheme))
            }
        }
        .padding(.vertical, 9)
    }
}

// MARK: - 截图识别核对弹窗

/// 识别结果**不直接入库**：金额 / 电量 / 时间 / 站点都能改，
/// 还能指定它属于哪次充电。唯一候选才预选，多候选一律留空让人挑。
private struct OcrRowDraft: Identifiable {
    let id: String
    var amountText: String
    var energyText: String
    var startText: String
    var stationText: String
    var chosenSessionId: String?

    init(row: OcrRow) {
        self.id = row.id
        self.amountText = row.amount.map { String(format: "%.2f", $0) } ?? ""
        self.energyText = row.energyKwh.map { String(format: "%.1f", $0) } ?? ""
        self.startText = row.startAt ?? ""
        self.stationText = row.stationName ?? ""
        let candidates = row.candidates ?? []
        self.chosenSessionId = candidates.count == 1 ? candidates[0].sessionId : nil
    }

    /// 交给服务端的 JSON 体。字段缺失就不写 —— 让服务端按"没有"处理，
    /// 而不是塞一个空字符串进去。
    var payload: [String: Any] {
        var dict: [String: Any] = [:]
        if let amount = Double(amountText), amount > 0 { dict["amount"] = amount }
        if let energy = Double(energyText) { dict["energyKwh"] = energy }
        if !startText.trimmingCharacters(in: .whitespaces).isEmpty { dict["startAt"] = startText }
        if !stationText.trimmingCharacters(in: .whitespaces).isEmpty { dict["stationName"] = stationText }
        if let chosenSessionId { dict["sessionId"] = chosenSessionId }
        return dict
    }

    var isValid: Bool {
        (Double(amountText) ?? 0) > 0
    }
}

private struct OcrReviewSheet: View {

    let payload: OcrPayload
    let onCommit: ([[String: Any]]) async -> Bool

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme

    @State private var drafts: [OcrRowDraft]
    @State private var isSaving = false

    init(payload: OcrPayload, onCommit: @escaping ([[String: Any]]) async -> Bool) {
        self.payload = payload
        self.onCommit = onCommit
        _drafts = State(initialValue: (payload.rows ?? []).map { OcrRowDraft(row: $0) })
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("确认下面的金额，改完再保存 —— 识别只是草稿。")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.textTertiary(scheme))

                    ForEach(drafts.indices, id: \.self) { index in
                        draftRow(index)
                    }
                }
                .padding(16)
            }
            .navigationTitle("核对识别结果")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await save() }
                    } label: {
                        Text(isSaving ? "保存中…" : "保存 \(validCount) 笔")
                    }
                    .disabled(isSaving || validCount == 0)
                }
            }
        }
    }

    private var validCount: Int {
        drafts.filter { $0.isValid }.count
    }

    private func draftRow(_ index: Int) -> some View {
        let row = (payload.rows ?? [])[safe: index]
        let candidates = row?.candidates ?? []

        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("第 \(index + 1) 笔")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary(scheme))
                Spacer(minLength: 8)
                if row?.needsReview == true, let note = row?.reviewNote {
                    Text(note)
                        .font(.system(size: 10.5))
                        .foregroundStyle(ChineseColor.tiSe)
                }
            }

            fieldRow("金额（元）", text: $drafts[index].amountText, numeric: true)
            fieldRow("电量（度）", text: $drafts[index].energyText, numeric: true)
            fieldRow("时间", text: $drafts[index].startText, numeric: false)
            fieldRow("站点", text: $drafts[index].stationText, numeric: false)

            if !candidates.isEmpty {
                Menu {
                    Button("不指定") { drafts[index].chosenSessionId = nil }
                    ForEach(candidates) { candidate in
                        Button {
                            drafts[index].chosenSessionId = candidate.sessionId
                        } label: {
                            Text("\(candidate.startTime ?? "--") · \(String(format: "%.1f", candidate.energyKwh ?? 0)) 度 · \(candidate.kindText)")
                        }
                    }
                } label: {
                    HStack {
                        Text(chosenLabel(index, candidates: candidates))
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textSecondary(scheme))
                            .lineLimit(1)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.textTertiary(scheme))
                    }
                    .padding(.horizontal, 10)
                    .frame(minHeight: Metrics.minTouchTarget)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.surfaceAlt(scheme))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            } else {
                Text("时间附近没有充电流水，可能是停车费 / 占位费，或这笔是别人付的。先留着，别删。")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.textTertiary(scheme))
            }
        }
        .padding(12)
        .background(Theme.surfaceAlt(scheme).opacity(0.55))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func chosenLabel(_ index: Int, candidates: [OcrCandidate]) -> String {
        guard let chosen = drafts[index].chosenSessionId,
              let hit = candidates.first(where: { $0.sessionId == chosen }) else {
            return "属于哪次充电：不指定"
        }
        return "属于哪次充电：\(hit.startTime ?? "--") · \(String(format: "%.1f", hit.energyKwh ?? 0)) 度"
    }

    private func fieldRow(
        _ title: String,
        text: Binding<String>,
        numeric: Bool
    ) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textTertiary(scheme))
                .frame(width: 78, alignment: .leading)
            TextField("", text: text)
                .font(.system(size: 13))
                .foregroundStyle(Theme.textPrimary(scheme))
                .keyboardType(numeric ? .decimalPad : .default)
                .multilineTextAlignment(.trailing)
                .frame(minHeight: Metrics.minTouchTarget)
        }
        .padding(.horizontal, 10)
        .background(Theme.surface(scheme))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func save() async {
        guard !isSaving else { return }
        isSaving = true
        let rows = drafts.filter { $0.isValid }.map { $0.payload }
        let ok = await onCommit(rows)
        isSaving = false
        if ok { dismiss() }
    }
}

// MARK: - 手工录入

private struct ManualPaymentSheet: View {

    let onSave: (Double, String, Double?, String?) async -> Bool

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme

    @State private var amountText = ""
    @State private var paidAtText = ""
    @State private var energyText = ""
    @State private var stationText = ""
    @State private var isSaving = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("金额（元）", text: $amountText)
                        .keyboardType(.decimalPad)
                    TextField("时间（YYYY-MM-DD HH:mm）", text: $paidAtText)
                        .keyboardType(.numbersAndPunctuation)
                    TextField("电量（度，可留空）", text: $energyText)
                        .keyboardType(.decimalPad)
                    TextField("站点（可留空）", text: $stationText)
                } header: {
                    Text("金额 + 时间就能存，其余两项有就填 —— 电量影响每度单价。")
                }
            }
            .navigationTitle("手写录入")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await save() }
                    } label: {
                        Text(isSaving ? "保存中…" : "保存")
                    }
                    .disabled(!isValid || isSaving)
                }
            }
        }
    }

    private var isValid: Bool {
        (Double(amountText) ?? 0) > 0 && !paidAtText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func save() async {
        guard !isSaving, isValid else { return }
        isSaving = true
        let ok = await onSave(
            Double(amountText) ?? 0,
            paidAtText,
            Double(energyText),
            stationText.trimmingCharacters(in: .whitespaces).isEmpty ? nil : stationText
        )
        isSaving = false
        if ok { dismiss() }
    }
}

// MARK: - 待确认队列

/// 配不上的金额一条都不丢：零命中 → 未配对，多候选 → 待确认，
/// 点一下即可绑定；已绑定的还给「解绑」，绑错了能撤。
private struct PaymentsSheet: View {

    let payments: [ChargePayment]
    let onLink: (String, String) async -> Void
    let onUnlink: (String) async -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if payments.isEmpty {
                        Text("没有待处理的金额记录。")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textTertiary(scheme))
                    } else {
                        ForEach(payments) { payment in
                            paymentRow(payment)
                        }
                    }
                }
                .padding(16)
            }
            .navigationTitle("待确认金额")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    private func paymentRow(_ payment: ChargePayment) -> some View {
        let candidates = payment.candidates ?? []
        let statusText = payment.status == "unmatched" ? "没找到对应充电" : "有多条候选"

        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("¥\(String(format: "%.2f", payment.amount ?? 0))")
                    .font(.system(size: 15, weight: .medium, design: .rounded))
                    .foregroundStyle(Theme.textPrimary(scheme))
                    .monospacedDigit()
                Spacer(minLength: 8)
                Text(payment.paidAt ?? "时间未知")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary(scheme))
            }

            if payment.isMatched {
                Text("已绑定到一次充电")
                    .font(.system(size: 11.5))
                    .foregroundStyle(ChineseColor.zhuQing)
                Button {
                    Task { await onUnlink(payment.id) }
                } label: {
                    Text("解绑")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(ChineseColor.zhuSha)
                        .frame(minHeight: Metrics.minTouchTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                Text(statusText)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textSecondary(scheme))

                if candidates.isEmpty {
                    Text("时间附近没有充电流水，可能是停车费 / 占位费，或这笔是别人付的。先留着，别删。")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.textTertiary(scheme))
                } else {
                    ForEach(candidates) { candidate in
                        Button {
                            Task { await onLink(payment.id, candidate.sessionId ?? "") }
                        } label: {
                            HStack {
                                Text("\(candidate.startTime ?? "--") · \(String(format: "%.1f", candidate.energyKwh ?? 0)) 度")
                                    .font(.system(size: 12))
                                    .foregroundStyle(Theme.textPrimary(scheme))
                                Spacer(minLength: 8)
                                Text(candidate.kindText)
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(Theme.textTertiary(scheme))
                            }
                            .padding(.horizontal, 10)
                            .frame(minHeight: Metrics.minTouchTarget)
                            .background(Theme.surfaceAlt(scheme))
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(12)
        .background(Theme.surfaceAlt(scheme).opacity(0.55))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

// MARK: - 小工具

private extension Array {
    /// 安全下标：核对弹窗里按索引取原始行，越界不该崩
    subscript(safe index: Int) -> Element? {
        guard index >= 0, index < count else { return nil }
        return self[index]
    }
}
