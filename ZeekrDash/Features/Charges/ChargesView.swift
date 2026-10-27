//
//  ChargesView.swift
//  ZeekrDash
//
//  充电页（v2）
//
//  真源：`preview/index-v2.html` 的 `renderCharges()`（4812–4885）与 `costCard()`（4886–4980），
//  样式块 1945–1990。卡片顺序：充入电量 → 附近充电站 → 充电记录 → 金额补录。
//

import Foundation
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import PhotosUI

/// 充电页
///
/// 与 `preview/index-v2.html` 的充电屏一一对应：
///   1. 右上角月份胶囊（浮层，与数据来源徽标同一行）；
///   2. **充入电量**：左电量大数 / 右当月金额与累计，底部「N 次充电 · 均值 X kW」；
///   3. 附近充电站（实时、要定位，三行推荐位）；
///   4. 充电记录（逐笔）；
///   5. 金额补录（截图识别 / 手工录入，**不显示估算金额**）。
struct ChargesView: View {

    @Environment(AppStore.self) private var store
    @State private var model = ChargesViewModel()

    @State private var showMonthPicker = false
    /// 相册选图弹层的开关（截图识别入口）
    @State private var showPhotoPicker = false
    /// 相册里选中的那一张；变化即触发上传识别
    @State private var pickedPhoto: PhotosPickerItem?
    @State private var showOcrReview = false
    @State private var showManualEntry = false
    @State private var showPayments = false
    /// 从核对框里点「重选截图 / 手写录入」时记下的意图，等弹层退场后再执行
    @State private var pendingOcrExit: OcrExitAction?

    /// 核对框的两种「退出后去哪」
    private enum OcrExitAction {
        case reselect
        case manual
    }

    /// 关闭核对框并记下接下来要打开的入口
    private func exitOcr(_ action: OcrExitAction) {
        pendingOcrExit = action
        showOcrReview = false
    }

    /// 相册选完一张 → 取字节 → 交给服务端识别 → 有结果就弹核对框。
    ///
    /// loadTransferable 不保证有值：iCloud 原图还没下载完、选中的是 Live Photo
    /// 只剩视频轨、文件本身损坏，都会返回 nil。这种情况必须给可见提示 ——
    /// 静默 return 会让人以为按钮是坏的。
    @MainActor
    private func handlePickedPhoto(_ item: PhotosPickerItem) async {
        // 先清掉选中项：否则用户再选同一张图不会触发 onChange（值没变）。
        pickedPhoto = nil

        guard let data = try? await item.loadTransferable(type: Data.self) else {
            model.showToast("这张图读不出来（可能还在 iCloud 下载），换一张试试")
            return
        }

        let ext = item.supportedContentTypes.first?.preferredFilenameExtension ?? "jpg"
        await model.runOcr(imageData: data, filename: "screenshot.\(ext)")

        if model.ocrResult != nil { showOcrReview = true }
    }

    /// 首次加载中（还没拿到任何月度汇总）
    private var isFirstLoad: Bool {
        model.isLoading && model.stat == nil
    }

    var body: some View {
        NavigationStack {
            ScreenContainer(
                modePill: store.modePill,
                trailingAccessory: {
                    if !store.needsLogin { monthChip }
                }
            ) {
                content
            }
            .toolbar(.hidden, for: .navigationBar)
            // 下拉 = 现在就去拉一次（原生手势替代已移除的「同步」按钮）
            .refreshable { await model.refresh() }
        }
        .task { await model.load() }
        /* 充电中 → 未充电：这是唯一会产生新充电流水的时刻。
           车况轮询间隔本来就跟着充电状态走（充电中 60 秒一次），跳变一定抓得到。 */
        .onChange(of: store.isCharging) { wasCharging, isCharging in
            if wasCharging && !isCharging {
                Task { await model.syncAfterChargeEnd() }
            }
        }
        // 月份选择：与行程页共用同一个原生滚轮
        .sheet(isPresented: $showMonthPicker) {
            MonthPickerSheet(months: model.monthOptions, selection: model.selectedMonth) { picked in
                Task { await model.select(month: picked) }
            }
        }
        /* 截图识别：**从相册选图** → 服务端识别 → 先核对再入库。
           原来是 .fileImporter：它打开的是「文件」App，而用户的截图在相册里，
           等于点了个用不上的入口。PhotosPicker 直接进系统相册（支持截图、
           最近项目、iCloud），和 HTML 版 input[type=file] 在 iOS 上的行为一致。 */
        .photosPicker(
            isPresented: $showPhotoPicker,
            selection: $pickedPhoto,
            matching: .images,
            photoLibrary: .shared()
        )
        .onChange(of: pickedPhoto) { _, item in
            guard let item else { return }
            Task { await handlePickedPhoto(item) }
        }
        // 核对弹层用自绘面板（不是系统 sheet）：与 v2 的圆角/遮罩/把手一致
        .fullScreenCover(isPresented: $showOcrReview) {
            if let payload = model.ocrResult {
                OcrReviewSheet(
                    payload: payload,
                    records: model.records,
                    recognizedAt: model.ocrAt,
                    // 没匹配到流水时的两个兜底：退出核对框后再打开各自的入口
                    onReselectImage: { exitOcr(.reselect) },
                    onManualEntry: { exitOcr(.manual) }
                ) { rows in
                    await model.commitOcr(imageSha8: payload.imageSha8, rows: rows)
                }
            }
        }
        /* 兜底入口不能在 cover 还没退场时就 present 下一个 —— 会丢。
           先记下意图，等 `showOcrReview` 落成 false 再延时 0.4s 打开。 */
        .onChange(of: showOcrReview) { _, presented in
            guard !presented, let action = pendingOcrExit else { return }
            pendingOcrExit = nil
            Task {
                try? await Task.sleep(nanoseconds: 400_000_000)
                switch action {
                case .reselect: showPhotoPicker = true
                case .manual:   showManualEntry = true
                }
            }
        }
        .fullScreenCover(isPresented: $showManualEntry) {
            ManualPaymentSheet { amount, paidAt, energyKwh, stationName in
                await model.addManual(
                    amount: amount,
                    paidAt: paidAt,
                    energyKwh: energyKwh,
                    stationName: stationName
                )
            }
        }
        .fullScreenCover(isPresented: $showPayments) {
            PaymentsSheet(payments: model.payments) { paymentId, sessionId in
                await model.link(paymentId: paymentId, sessionId: sessionId)
            } onUnlink: { paymentId in
                await model.unlink(paymentId: paymentId)
            }
        }
    }

    // MARK: - 月份胶囊（`.v2-month-chip`）

    private var monthChip: some View {
        Button {
            showMonthPicker = true
        } label: {
            Text(model.selectedMonthLabel)
                .v2Text(V2Type.month13.bumped(), color: V2Color.accent)
                .padding(.horizontal, 14)
                .frame(minWidth: V2Metrics.monthChipMinWidth, minHeight: V2Metrics.monthChipHeight)
                .glassSurface(cornerRadius: V2Metrics.monthChipRadius)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("充入电量月份 \(model.selectedMonthLabel)")
    }

    // MARK: - 内容分派

    @ViewBuilder
    private var content: some View {
        if store.needsLogin {
            V2LoginWall { store.selectedTab = .settings }
        } else {
            VStack(spacing: V2Metrics.screenGap) {
                if isFirstLoad {
                    skeleton
                } else if let stat = model.stat {
                    if (stat.count ?? 0) > 0 {
                        sumCard(stat)
                    } else {
                        emptyMonth
                    }
                } else if model.errorMessage != nil {
                    errorCard
                } else {
                    emptyMonth
                }

                if let message = model.errorMessage, model.stat != nil {
                    V2StaleBanner(
                        text: "这一轮没读到最新流水，下面是上次读到的数据",
                        detail: message
                    ) { Task { await model.load() } }
                }

                /* 附近站与充入电量是**两块独立的数据**（前者实时、后者是本地历史），
                   所以它必须在充入电量的空态判断之外渲染 —— 没充过电，
                   不代表看不到"附近哪能充、现在多少钱"。 */
                NearbyStationsCard()

                if !isFirstLoad, let stat = model.stat, (stat.count ?? 0) > 0 {
                    recordCard
                    costCard
                }

                footNote
            }
        }
    }

    // MARK: - 充入电量（`.v2-cc-*`）

    private func sumCard(_ stat: ChargeMonthStat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 0) {
                    Text("本月充入电量")
                        .v2Text(V2Type.label12.bumped(), color: V2Color.text2)
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        // 电量大数递增入场；没读到仍是 --（不是 0.0）
                        if let kwh = stat.totalKwh {
                            V2CountUp(target: kwh, reserveWidth: true) {
                                String(format: "%.1f", $0)
                            }
                            .v2Text(V2Type.hero34.bumped())
                        } else {
                            Text("--")
                                .v2Text(V2Type.hero34.bumped())
                                .v2Numeric()
                        }
                        Text("kWh")
                            .v2Text(V2Type.body14m.bumped(), color: V2Color.text2)
                    }
                    .padding(.top, 12)
                }

                Spacer(minLength: 0)

                VStack(alignment: .trailing, spacing: 14) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("本月金额")
                            .v2Text(V2Type.label12.bumped(), color: V2Color.text2)
                            .frame(width: 56, alignment: .leading)
                        amountChip(stat.amountTotal)
                    }

                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("累计")
                            .v2Text(V2Type.label12.bumped(), color: V2Color.text2)
                            .frame(width: 56, alignment: .leading)
                        Text(totalAmountText)
                            .v2Text(V2Type.body14m.bumped(), color: V2Color.text3)
                            .v2Numeric()
                    }

                    // 有金额、也有没补的笔数时说明"合计里不含这几笔"
                    if (stat.amountCount ?? 0) > 0, (stat.unpricedCount ?? 0) > 0 {
                        Text("含 \(stat.unpricedCount ?? 0) 笔未补录")
                            .v2Text(V2Type.label11.bumped(), color: V2Color.text3)
                            .padding(.top, -6)
                    }
                }
            }

            HStack(spacing: 24) {
                V2CountUp(target: Double(stat.count ?? 0), delay: 0.10) {
                    String(format: "%.0f 次充电", $0)
                }
                .v2Text(V2Type.stat15.bumped(), color: V2Color.info)

                if let avg = stat.avgPowerKw {
                    V2CountUp(target: avg, delay: 0.16) {
                        "均值 " + String(format: "%.1f", $0) + " kW"
                    }
                    .v2Text(V2Type.stat15.bumped(), color: V2Color.text1)
                } else {
                    Text("均值 \(number(stat.avgPowerKw, 1)) kW")
                        .v2Text(V2Type.stat15.bumped(), color: V2Color.text1)
                }
            }
            .padding(.top, 10)
        }
        .v2Card()
    }

    /// 本月金额：没有金额时是「未补录」胶囊，不是 ¥0.00
    @ViewBuilder
    private func amountChip(_ amount: Double?) -> some View {
        if let amount {
            V2CountUp(target: amount, delay: 0.06, reserveWidth: true) {
                "¥" + String(format: "%.2f", $0)
            }
            .v2Text(V2Type.amt19.bumped())
        } else {
            Text("未补录")
                .v2Text(V2Type.label11.bumped(), color: V2Color.warn)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(V2Color.tintWarn)
                .clipShape(Capsule())
        }
    }

    /// 所有可查月份的金额之和；没有一个月带金额时给 `--`
    private var totalAmountText: String {
        let sum = model.months.reduce(0.0) { $0 + ($1.amount ?? 0) }
        return sum > 0 ? "¥" + String(format: "%.2f", sum) : "--"
    }

    // MARK: - 加载骨架 / 读失败 / 空态

    private var skeleton: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("本月充入电量").v2Text(V2Type.title14.bumped())
                Spacer(minLength: 0)
                Text("加载中")
                    .v2Text(V2Type.label11.bumped(), color: V2Color.text2)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(V2Color.tintMuted)
                    .clipShape(Capsule())
            }
            GeometryReader { proxy in
                VStack(alignment: .leading, spacing: 12) {
                    SkeletonBar(width: proxy.size.width * 0.70)
                    SkeletonBar(width: proxy.size.width * 0.35)
                    SkeletonBar(width: proxy.size.width * 0.55)
                }
                .padding(.top, 8)
            }
            .frame(height: 66 + 8)
        }
        .v2Card()
        .accessibilityLabel("正在读取充电流水")
    }

    private var errorCard: some View {
        VStack(spacing: 0) {
            // 注意：HTML 的充电页空态/错误态**没有图标**（只有行程页有 SVG.chart），别自己加
            Text("充电流水没有读到")
                .v2Text(V2Type.emptyTitle.bumped())
                .padding(.top, 12)
            Text("后端可能正在重启，或登录状态已失效")
                .v2Text(V2Type.emptyDesc.bumped(), color: V2Color.text3)
                .padding(.top, 6)
            Button {
                Task { await model.load() }
            } label: {
                Text("重试")
                    .v2Text(V2Type.button14.bumped(), color: V2Color.accent)
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

    private var emptyMonth: some View {
        VStack(spacing: 0) {
            Text("\(model.selectedMonthLabel)没有充电记录")
                .v2Text(V2Type.emptyTitle.bumped())
            Text("换个月份看看；新流水会在充完电或跨天后的同步里出现")
                .v2Text(V2Type.emptyDesc.bumped(), color: V2Color.text3)
                .multilineTextAlignment(.center)
                .padding(.top, 6)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 22)
        .frame(maxWidth: .infinity)
        .v2Card()
    }

    // MARK: - 充电记录（`.v2-rec`）

    private var recordCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("充电记录").v2Text(V2Type.title14.bumped())
            VStack(alignment: .leading, spacing: 0) {
                ForEach(model.records) { record in
                    ChargeRecordRow(record: record)
                }
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .v2Card()
    }

    // MARK: - 金额补录（`costCard()`，4886–4980）

    private var costCard: some View {
        let stat = model.stat
        let priced = stat?.amountCount ?? 0
        let unpriced = stat?.unpricedCount ?? 0
        let estimated = stat?.estimatedCount ?? 0
        let totalBills = priced + unpriced + estimated
        let badge: String = {
            if priced == 0 { return "未补录" }
            return totalBills > priced ? "已补录 \(priced)/\(totalBills) 笔" : "已补全"
        }()
        let pending = model.pendingCount

        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("金额补录").v2Text(V2Type.title14.bumped())
                Spacer(minLength: 0)
                Text(badge)
                    .v2Text(V2Type.chip11.bumped(), color: V2Color.accent)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(V2Color.accent.opacity(0.12))
                    .clipShape(Capsule())
            }

            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(costNotes.enumerated()), id: \.offset) { _, note in
                    Text(note)
                        .v2Text(V2Type.note11b.bumped(), color: V2Color.text3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.top, 8)

            if let error = model.ocrErrorMessage {
                Text("识别失败：\(error)，可以手写录入")
                    .v2Text(V2Type.note11b.bumped(), color: V2Color.bad)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(V2Color.tintBad)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .padding(.top, 8)
            }

            // 三个入口：截图识别 / 手写录入 / 待确认
            HStack(spacing: 8) {
                Button {
                    showPhotoPicker = true
                } label: {
                    HStack(spacing: 5) {
                        if model.isOcrBusy {
                            ProgressView().controlSize(.mini).tint(.white)
                        } else {
                            Image("ic-scan")
                                .renderingMode(.template)
                                .resizable()
                                .frame(width: 14, height: 14)
                        }
                        Text(model.isOcrBusy ? "识别中…" : "截图识别")
                    }
                    .v2Text(V2Type.text12.bumped(), color: .white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(V2Color.accent)
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(!model.canWrite || model.isOcrBusy)
                .opacity(model.canWrite && !model.isOcrBusy ? 1 : 0.45)

                Button {
                    showManualEntry = true
                } label: {
                    HStack(spacing: 5) {
                        Image("ic-money")
                            .renderingMode(.template)
                            .resizable()
                            .frame(width: 14, height: 14)
                        Text("手写录入")
                    }
                    .v2Text(V2Type.text12.bumped(), color: V2Color.text1)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(Color.white.opacity(0.50))
                    .clipShape(Capsule())
                    .overlay(Capsule().strokeBorder(Color.white.opacity(0.90), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .disabled(!model.canWrite)
                .opacity(model.canWrite ? 1 : 0.45)

                if pending > 0 {
                    Button {
                        showPayments = true
                    } label: {
                        Text("待确认 \(pending)")
                            .v2Text(V2Type.text12.bumped(), color: V2Color.warn)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(V2Color.tintWarn)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(!model.canWrite)
                    .opacity(model.canWrite ? 1 : 0.45)
                }

                Spacer(minLength: 0)
            }
            .padding(.top, 12)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .v2Card()
    }

    /// 补录说明。**三态**：一笔都没补 / 补了一部分 / 全部补齐。
    private var costNotes: [String] {
        let stat = model.stat
        let priced = stat?.amountCount ?? 0
        let unpriced = stat?.unpricedCount ?? 0
        var notes: [String] = []

        if priced == 0 {
            notes.append("极氪只给电量，不给金额 —— 车不知道电价，站点也不在充电记录里。补录后上面的「当月金额 / 累计」才会有数。")
        } else {
            let unit = stat?.unitPrice.map { "，每度约 ¥" + String(format: "%.2f", $0) } ?? ""
            if unpriced > 0 {
                notes.append("已补录 \(priced) 笔\(unit)；还有 \(unpriced) 笔（\(number(stat?.unpricedKwh, 1)) 度）没补，单价只按已补录的算。")
            } else {
                notes.append("已补录 \(priced) 笔，全部有金额\(unit)。")
            }
        }

        if let estimated = stat?.estimatedCount, estimated > 0 {
            notes.append("另有 \(estimated) 笔为电价估算，未计入合计与单价。")
        }
        if model.pendingCount > 0 {
            notes.append("有 \(model.pendingCount) 笔金额配不上充电流水，在「待确认」里等你指定。")
        }
        if !model.canWrite {
            notes.append("当前是演示/离线数据，补录入口不可用（没有真实流水可配对）。")
        } else if model.ocrConfigured == false {
            notes.append("截图识别未开启：服务端 .env 填 DEEPSEEK_API_KEY 并重启后可用；在那之前先用手写录入。")
        }
        return notes
    }


    // MARK: - 页脚

    private var footNote: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let last = store.lastRefresh {
                Text("更新于 \(last.formatted(date: .omitted, time: .shortened))")
            }
            Text("数据来自非官方接口，仅供参考")
        }
        .v2Text(V2Type.foot11.bumped(), color: V2Color.text3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 8)
    }

    // MARK: - 小工具

    private func number(_ value: Double?, _ digits: Int) -> String {
        guard let value else { return "--" }
        return String(format: "%.\(digits)f", value)
    }
}

// MARK: - 一条充电流水（`chargeSessionItem()`，5002–5031）

private struct ChargeRecordRow: View {

    let record: ChargeSession

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(whenText)
                    .v2Text(V2Type.label12.bumped(), color: V2Color.text3)
                Spacer(minLength: 0)
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(String(format: "%.1f", record.energyKwh ?? 0))
                        .v2Text(V2Type.body15.bumped())
                        .v2Numeric()
                    Text("kWh")
                        .v2Text(V2Type.label11.bumped(), color: V2Color.text3)
                }
            }

            HStack(alignment: .center, spacing: 8) {
                Text(record.stationName ?? record.kindText)
                    .v2Text(V2Type.label12.bumped(), color: V2Color.text1)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 0)

                if let power = averagePower {
                    chip("均 \(String(format: "%.0f", power)) kW")
                }
                if let amount = record.amount {
                    chip("¥" + String(format: "%.2f", amount) + (record.amountSource == "estimate" ? " 估算" : ""))
                }
            }
        }
        .padding(.vertical, 4)
    }

    /// `startTime · 时长`；时长为 0 时只留时间
    private var whenText: String {
        let start = record.startTime ?? "--"
        guard let minutes = record.durationMin, minutes > 0 else { return start }
        return "\(start) · \(durationText(minutes))"
    }

    /// 均值功率。时长缺失/为 0 时这个除法会给出 Infinity，必须挡掉
    private var averagePower: Double? {
        guard let energy = record.energyKwh, let minutes = record.durationMin, minutes > 0 else { return nil }
        let power = energy / (minutes / 60)
        return power.isFinite && power > 0 ? power : nil
    }

    private func durationText(_ minutes: Double) -> String {
        let total = Int(minutes.rounded())
        if total < 60 { return "\(total) 分钟" }
        let hours = total / 60
        let rest = total % 60
        return rest == 0 ? "\(hours) 小时" : "\(hours) 小时 \(rest) 分"
    }

    private func chip(_ text: String) -> some View {
        Text(text)
            .v2Text(V2Type.label11.bumped(), color: V2Color.warn)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(V2Color.tintWarn)
            .clipShape(Capsule())
    }
}

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
        /* 默认选**第一笔**候选：后端已按匹配强度排好序，让用户从"确认"开始，
           而不是每次都要自己下拉挑一遍。HTML 在核对弹层里也是默认选中第一笔。 */
        self.chosenSessionId = candidates.first?.sessionId
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
    /// 当月充电流水：用来判断候选那笔是不是**已经补录过**
    var records: [ChargeSession] = []
    /// 识别时刻（副标题「已识别 N 张 · 21:34」用）
    var recognizedAt: Date?
    let onCommit: ([[String: Any]]) async -> Bool
    /// 没匹配到流水时的两个兜底入口（HTML `data-ocr-again` / `data-ocr-manual`）
    var onReselectImage: () -> Void = {}
    var onManualEntry: () -> Void = {}

    @Environment(\.dismiss) private var dismiss

    @State private var drafts: [OcrRowDraft]
    @State private var isSaving = false
    /// 用户**亲手点过**候选的行（HTML `state.ocrUserPicked`）——
    /// 这些行再改时间/电量也不撤销绑定，那是用户自己的判断。
    @State private var userPicked: Set<Int> = []
    /// 改过时间/电量、原自动匹配已作废的行（HTML `.ocr-rebind`）
    @State private var rebinding: Set<Int> = []

    init(
        payload: OcrPayload,
        records: [ChargeSession] = [],
        recognizedAt: Date? = nil,
        onReselectImage: @escaping () -> Void = {},
        onManualEntry: @escaping () -> Void = {},
        onCommit: @escaping ([[String: Any]]) async -> Bool
    ) {
        self.payload = payload
        self.records = records
        self.recognizedAt = recognizedAt
        self.onReselectImage = onReselectImage
        self.onManualEntry = onManualEntry
        self.onCommit = onCommit
        _drafts = State(initialValue: (payload.rows ?? []).map { OcrRowDraft(row: $0) })
    }

    var body: some View {
        /* 全部按 `index-v2.html`：
           · 标题「识别充电小票」16/600，右侧副标题「已识别 N 张 · HH:MM」；
           · 面板没有把手、没有右上按钮，圆角 18，白底，遮罩黑 28%；
           · 高度随内容，正文区封顶内滚（`.ocr-body` = max-height:min(58vh,430)）；
           · 取消 / 确认补录 固定在底部（`.ocr-actions`），48 高、r12。 */
        V2BottomSheet(
            title: "识别充电小票",
            subtitle: subtitleText,
            titleType: .ocrTitle16,
            closeTitle: nil,
            onClose: { dismiss() },
            hugContent: true,
            showsGrip: false,
            headerInset: 12,
            cornerRadius: 18,
            panelBackground: .white,
            maskColor: Color.black.opacity(0.28),
            footer: AnyView(footerBar)
        ) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(drafts.indices, id: \.self) { index in
                    draftCard(index)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 4)
            .padding(.bottom, 2)
        }
    }

    // MARK: - 顶部副标题

    private var subtitleText: String {
        let time: String
        if let recognizedAt {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "HH:mm"
            time = formatter.string(from: recognizedAt)
        } else {
            time = "--"
        }
        return "已识别 \(drafts.count) 张 · \(time)"
    }

    private var validCount: Int {
        drafts.filter { $0.isValid }.count
    }

    // MARK: - 单张小票（`.ocr-row`）

    private func draftCard(_ index: Int) -> some View {
        let row = (payload.rows ?? [])[safe: index]
        let candidates = row?.candidates ?? []
        let multi = drafts.count > 1

        return VStack(alignment: .leading, spacing: 0) {
            rowHeader(index: index, row: row, multi: multi)

            if row?.needsReview == true {
                Text(reviewText(row))
                    .v2Text(.ocrWarn115, color: V2Color.ocrWarnText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(V2Color.ocrWarnFill)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .padding(.bottom, 8)
            }

            fieldsGrid(index: index)

            if candidates.isEmpty {
                noCandidateBlock
            } else {
                Text("对应哪次充电")
                    .v2Text(.note11, color: V2Color.text3)
                    .padding(.top, 10)
                    .padding(.bottom, 2)
            }

            VStack(spacing: 6) {
                ForEach(Array(candidates.enumerated()), id: \.offset) { _, candidate in
                    candidateRow(
                        index: index,
                        target: candidate.sessionId,
                        main: "\(Self.clock(candidate.startTime)) · \(String(format: "%.1f", candidate.energyKwh ?? 0)) kWh",
                        side: Self.dayDiffText(from: row?.startAt, to: candidate.startTime),
                        duplicated: isDuplicate(row: row, candidate: candidate),
                        forcedOn: nil
                    )
                }

                /* 没有候选时这一行的文案变成「仍要保存这笔金额」，
                   而且**不高亮**（HTML：只有存在候选且没选时才 `on`）。 */
                candidateRow(
                    index: index,
                    target: nil,
                    main: candidates.isEmpty ? "仍要保存这笔金额" : "暂不绑定（放进待确认）",
                    side: "",
                    duplicated: false,
                    forcedOn: candidates.isEmpty ? false : nil
                )
            }

            if rebinding.contains(index) {
                Text("时间和电量改过了，原来那次自动匹配不再作数 —— 请重新选一次对应哪次充电")
                    .v2Text(.ocrWarn115, color: V2Color.ocrWarnText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(V2Color.ocrWarnFill)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .padding(.top, 6)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        // `.ocr-row`：白 .45 底 + 1px 分隔线 + r16
        .background(V2Color.softFill)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(V2Color.separator, lineWidth: 1)
        )
        /* 改了「开始时间 / 电量」→ 自动匹配作废（HTML 的 input 监听）：
           用户自己点过候选的行不动；本来就没绑的也不用提示。 */
        .onChange(of: drafts[index].startText) { _, _ in handleRebind(index) }
        .onChange(of: drafts[index].energyText) { _, _ in handleRebind(index) }
    }

    /// `.ocr-row-top`：左「第 N 笔」、中站名 13/600、右「置信度 N%」胶囊
    private func rowHeader(index: Int, row: OcrRow?, multi: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if multi {
                Text("第 \(index + 1) 笔")
                    .v2Text(.ocrRowTop12, color: V2Color.text2)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Text(stationText(row))
                .v2Text(.ocrStation13)
                .lineLimit(1)

            if let conf = confidenceText(row) {
                Text(conf)
                    .v2Text(.ocrConf11, color: V2Color.confText)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(V2Color.confFill)
                    .clipShape(Capsule())
            }
        }
        .padding(.bottom, 7)
    }

    /// `.ocr-fields`：两列等分、gap 8
    private func fieldsGrid(index: Int) -> some View {
        LazyVGrid(
            columns: [
                GridItem(.flexible(), spacing: 8),
                GridItem(.flexible(), spacing: 8),
            ],
            alignment: .leading,
            spacing: 8
        ) {
            field("金额", text: $drafts[index].amountText, unit: "元",
                  placeholder: "", keyboard: .decimalPad)
            field("充电量", text: $drafts[index].energyText, unit: "kWh",
                  placeholder: "", keyboard: .decimalPad)
            field("开始时间", text: $drafts[index].startText, unit: nil,
                  placeholder: "2026-10-16 22:10", keyboard: .numbersAndPunctuation)
            field("站点名", text: $drafts[index].stationText, unit: nil,
                  placeholder: "选填", keyboard: .default)
        }
    }

    /// `.ocr-field`：标签 10.5 在输入框上方；输入框 38 高、r10、无边框 + 内白环；
    /// 单位浮在右侧（HTML `.ocr-unit`），不占 label。
    private func field(
        _ label: String,
        text: Binding<String>,
        unit: String?,
        placeholder: String,
        keyboard: UIKeyboardType
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .v2Text(.ocrLabel105, color: V2Color.text3)
                .padding(.leading, 2)

            ZStack(alignment: .trailing) {
                TextField(placeholder, text: text)
                    .v2Text(.ocrInput14, color: V2Color.text1)
                    .keyboardType(keyboard)
                    .padding(.leading, 9)
                    .padding(.trailing, unit == nil ? 9 : 34)
                    .frame(height: 38)
                    .background(V2Color.inputFill)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.90), lineWidth: 1)
                    )

                if let unit {
                    Text(unit)
                        .v2Text(.ocrUnit12, color: V2Color.text3)
                        .padding(.trailing, 10)
                        .allowsHitTesting(false)
                }
            }
        }
    }

    /// `.ocr-nocand`：没匹配到流水时的兜底（两颗胶囊按钮）
    private var noCandidateBlock: some View {
        VStack(spacing: 6) {
            Text("没匹配到充电流水")
                .v2Text(.nocandT14)
            Text("可以先记下金额放进「待确认」，之后再指定属于哪次充电。")
                .v2Text(.ocrSub12, color: V2Color.text3)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                actionButton("重选截图") { onReselectImage() }
                actionButton("手写录入") { onManualEntry() }
            }
            .padding(.top, 6)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 16)
        .padding(.bottom, 4)
    }

    /// `.ocr-act`：44 高、左右 20、r999、淡紫底
    private func actionButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .v2Text(.ocrAct14, color: V2Color.accent)
                .padding(.horizontal, 20)
                .frame(height: 44)
                .background(V2Color.chipFill)
                .clipShape(Capsule())
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// 一行候选（`.ocr-cand`）：无边框；选中整行铺紫底白字、右侧打勾；
    /// 未选中写「差 N 天」；「已补录」是勾左边的绿胶囊，纯标记不可点。
    ///
    /// - Parameter forcedOn: 传 `false` 强制不高亮（没有候选时的「仍要保存」行）
    private func candidateRow(
        index: Int,
        target: String?,
        main: String,
        side: String,
        duplicated: Bool,
        forcedOn: Bool?
    ) -> some View {
        let on = forcedOn ?? (drafts[index].chosenSessionId == target)

        return Button {
            drafts[index].chosenSessionId = target
            userPicked.insert(index)
            rebinding.remove(index)
        } label: {
            HStack(spacing: 8) {
                Text(main)
                    .v2Text(on ? .ocrCandOn : .ocrCand, color: on ? .white : V2Color.text1)
                    .lineLimit(1)

                Spacer(minLength: 8)

                /* 「已补录」只在**金额与站点都匹配**时出现（HTML `detectDupReceipts`）：
                   只做标记，不可点、不弹提示 —— 撤回仍走「金额记录」里的解绑。 */
                if duplicated {
                    Text("已补录")
                        .v2Text(.dupBadge, color: V2Color.good)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        // 选中行是紫底，胶囊要换成近白底，否则绿字压在紫底上看不清
                        .background(on ? Color.white.opacity(0.92) : V2Color.tintGood)
                        .clipShape(Capsule())
                }

                if on {
                    Text("✓")
                        .v2Text(.ocrCandOn, color: .white)
                } else if !side.isEmpty {
                    Text(side)
                        .v2Text(.ocrSide, color: V2Color.text3)
                        .fixedSize()
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .frame(minHeight: 38)
            .background(on ? V2Color.accent : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? AccessibilityTraits.isSelected : [])
    }

    // MARK: - 底部操作（`.ocr-actions`）

    private var footerBar: some View {
        HStack(spacing: 8) {
            Button {
                dismiss()
            } label: {
                Text("取消")
                    .v2Text(.ocrPrimary15, color: V2Color.text1)
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                    .background(V2Color.softFill)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                Task { await save() }
            } label: {
                Text(isSaving ? "补录中…" : "确认补录")
                    .v2Text(.ocrPrimary15, color: .white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                    .background(V2Color.accent)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .opacity(validCount > 0 && !isSaving ? 1 : 0.5)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(validCount == 0 || isSaving)
        }
        // `.ocr-actions` 在 `.sheet` 的 10px 内距里（正文 `.ocr-body` 是 12）
        .padding(.horizontal, 10)
    }

    // MARK: - 数据

    private func stationText(_ row: OcrRow?) -> String {
        if let name = row?.stationName, !name.isEmpty { return name }
        return "未识别到站点"
    }

    /// `ocrConf()`：<=1 当比例、否则当百分数
    private func confidenceText(_ row: OcrRow?) -> String? {
        guard let raw = row?.confidence else { return nil }
        let pct = raw <= 1 ? (raw * 100).rounded() : raw.rounded()
        return "置信度 \(Int(pct))%"
    }

    /// 需核对：HTML 固定句式「需要核对：{note}。金额请按「实付」填，别填服务费原价。」
    private func reviewText(_ row: OcrRow?) -> String {
        let note: String
        if let raw = row?.reviewNote, !raw.isEmpty {
            note = raw
        } else {
            note = "这一项读得不准"
        }
        return "需要核对：\(note)。金额请按「实付」填，别填服务费原价。"
    }

    /// 小票的「金额 + 站点」是否已经补录过（对应 HTML `detectDupReceipts`）
    private func isDuplicate(row: OcrRow?, candidate: OcrCandidate) -> Bool {
        guard let row, let amount = row.amount, amount > 0 else { return false }
        let station = Self.normStation(row.stationName)
        guard !station.isEmpty, let sessionId = candidate.sessionId else { return false }
        guard let record = records.first(where: { $0.sessionId == sessionId }) else { return false }
        guard let recorded = record.amount, record.amountSource != "estimate" else { return false }
        guard abs(recorded - amount) <= 0.005 else { return false }
        return Self.normStation(record.stationName) == station
    }

    /// 站名归一：「极氪超充·上海中心」与「极氪超充上海中心（B2）」视为同一站。只用于判重。
    private static func normStation(_ raw: String?) -> String {
        guard let raw else { return "" }
        var text = raw.lowercased()
        text = String(text.unicodeScalars.filter { scalar in
            let v = scalar.value
            let chinese = v >= 0x4E00 && v <= 0x9FFF
            let ascii = (v >= 0x61 && v <= 0x7A) || (v >= 0x30 && v <= 0x39)
            return chinese || ascii
        })
        for suffix in ["充电站", "充电桩", "超充站"] where text.hasSuffix(suffix) {
            text.removeLast(suffix.count)
        }
        return text
    }

    /// `22:10` —— 只取时分（HTML `fmtTime`）
    private static func clock(_ raw: String?) -> String {
        guard let raw, raw.count >= 16 else { return raw ?? "--" }
        let time = raw.split(separator: " ").last.map(String.init) ?? raw
        return String(time.prefix(5))
    }

    /// 小票时间与候选时间差几天（HTML `diffTxt`：`同一天` / `差 N 天`）
    private static func dayDiffText(from base: String?, to other: String?) -> String {
        guard let base, let other, base.count >= 10, other.count >= 10 else { return "" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        guard let a = formatter.date(from: String(base.prefix(10))),
              let b = formatter.date(from: String(other.prefix(10))) else { return "" }
        let days = abs(Calendar.current.dateComponents([.day], from: a, to: b).day ?? 0)
        return days == 0 ? "同一天" : "差 \(days) 天"
    }

    // MARK: - 动作

    /// 改了开始时间/电量：自动预选的那条已不可信，撤销并提示重选。
    /// 用户自己点过候选的行不动；本来就没绑的也不用提示。
    private func handleRebind(_ index: Int) {
        guard !userPicked.contains(index) else { return }
        guard drafts[index].chosenSessionId != nil else { return }
        drafts[index].chosenSessionId = nil
        rebinding.insert(index)
    }

    private func save() async {
        guard !isSaving, validCount > 0 else { return }
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

    @State private var amountText = ""
    @State private var paidAtText = ""
    @State private var energyText = ""
    @State private var stationText = ""
    @State private var isSaving = false

    var body: some View {
        V2BottomSheet(
            title: "手写录入",
            closeTitle: "取消",
            trailingTitle: isSaving ? "保存中…" : "保存",
            trailingEnabled: isValid && !isSaving,
            onTrailing: { Task { await save() } },
            onClose: { dismiss() },
            heightRatio: 0.70
        ) {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text("金额 + 时间就能存，其余两项有就填 —— 电量影响每度单价。")
                        .v2Text(.note11b, color: V2Color.text3)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, 2)

                    field("金额（元）", $amountText, .decimalPad)
                    field("时间", $paidAtText, .numbersAndPunctuation)
                    field("电量（度）", $energyText, .decimalPad)
                    field("站点", $stationText, .default)
                }
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .padding(.bottom, 28)
            }
        }
    }

    private var isValid: Bool {
        (Double(amountText) ?? 0) > 0 && !paidAtText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// 一行输入：左标签 + 右输入，白 .45 底 + r10（与 OCR 弹层同一套）
    private func field(
        _ title: String,
        _ text: Binding<String>,
        _ keyboard: UIKeyboardType
    ) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .v2Text(.label12, color: V2Color.text3)
                .frame(width: 64, alignment: .leading)
            TextField(title == "时间" ? "2026-10-27 14:30" : "", text: text)
                .v2Text(.label12, color: V2Color.text1)
                .keyboardType(keyboard)
                .multilineTextAlignment(.trailing)
                .frame(minHeight: 44)
        }
        .padding(.horizontal, 10)
        .background(Color.white.opacity(0.45))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
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

    var body: some View {
        V2BottomSheet(
            title: "待确认金额",
            closeTitle: "完成",
            onClose: { dismiss() },
            heightRatio: 0.74
        ) {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if payments.isEmpty {
                        Text("没有待处理的金额记录。")
                            .v2Text(.label12, color: V2Color.text3)
                    } else {
                        ForEach(payments) { payment in
                            paymentCard(payment)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .padding(.bottom, 28)
            }
        }
    }

    private func paymentCard(_ payment: ChargePayment) -> some View {
        let candidates = payment.candidates ?? []
        let statusText = payment.status == "unmatched" ? "没找到对应充电" : "有多条候选"

        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("¥" + String(format: "%.2f", payment.amount ?? 0))
                    .v2Text(.amt19)
                    .v2Numeric()
                Spacer(minLength: 0)
                Text(payment.paidAt ?? "时间未知")
                    .v2Text(.label11, color: V2Color.text3)
            }

            if payment.isMatched {
                Text("已绑定到一次充电")
                    .v2Text(.label11, color: V2Color.good)
                Button {
                    Task { await onUnlink(payment.id) }
                } label: {
                    Text("解绑")
                        .v2Text(.label12, color: V2Color.bad)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                Text(statusText)
                    .v2Text(.label11, color: V2Color.text2)

                if candidates.isEmpty {
                    Text("时间附近没有充电流水，可能是停车费 / 占位费，或这笔是别人付的。先留着，别删。")
                        .v2Text(.label11, color: V2Color.text3)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach(candidates) { candidate in
                        Button {
                            Task { await onLink(payment.id, candidate.sessionId ?? "") }
                        } label: {
                            HStack(spacing: 8) {
                                Text("\(candidate.startTime ?? "--") · \(String(format: "%.1f", candidate.energyKwh ?? 0)) 度")
                                    .v2Text(.label12, color: V2Color.text1)
                                Spacer(minLength: 0)
                                Text(candidate.kindText)
                                    .v2Text(.label11, color: V2Color.text3)
                            }
                            .padding(.horizontal, 10)
                            .frame(minHeight: 44)
                            .background(Color.white.opacity(0.45))
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.55))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.white.opacity(0.90), lineWidth: 1)
        )
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
