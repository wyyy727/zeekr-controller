//
//  ChargesViewModel.swift
//  ZeekrDash
//
//  充电页状态管理：充入电量（官方流水）+ 金额补录（截图识别 / 手工）
//

import Foundation
import SwiftUI

@Observable
@MainActor
final class ChargesViewModel {

    // MARK: - 状态

    /// 可查月份清单（倒序，当月在第一个）
    var months: [ChargeMonthOption] = []
    var selectedMonth: String = "currentMonth"
    /// 所选月份的汇总 + 逐笔记录
    var stat: ChargeMonthStat?

    var isLoading = false
    var isSyncing = false
    var isOcrBusy = false
    var errorMessage: String?
    var toast: String?

    /// 截图识别是否可用。`nil` = 还没问过服务端（此时不显示任何降级提示）。
    var ocrConfigured: Bool?
    /// 识别结果（**未入库**），核对弹窗的数据源
    var ocrResult: OcrPayload?
    /// 金额证据列表（含已绑定的 —— 绑错了要能撤）
    var payments: [ChargePayment] = []

    /// 当前展示的是不是演示数据（界面据此标徽标、禁用补录入口）
    private(set) var isMock = false

    /// 加载代次。切月份会连发请求，先发后到时用它丢弃过时的结果 ——
    /// 否则旧月份的数据会把新选中的月份覆盖掉。
    private var loadGeneration = 0

    // MARK: - 派生值

    /// 供通用月份滚轮使用（`MonthPickerSheet` 只认 `MonthOption`）
    var monthOptions: [MonthOption] {
        months.map { MonthOption(yearMonth: $0.yearMonth ?? "currentMonth", label: $0.label ?? "本月") }
    }

    var isCurrentMonth: Bool { selectedMonth == "currentMonth" }

    var selectedMonthLabel: String {
        if isCurrentMonth { return "本月" }
        return months.first(where: { $0.yearMonth == selectedMonth })?.label ?? selectedMonth
    }

    var records: [ChargeSession] { stat?.records ?? [] }
    var count: Int { stat?.count ?? 0 }

    /// 趋势图用：月份清单是倒序的，图要从左往右读
    var trendMonths: [ChargeMonthOption] {
        Array(months.filter { ($0.yearMonth ?? "").isEmpty == false }.reversed())
    }

    /// 待确认金额笔数（配不上流水 + 有多条候选）
    var pendingCount: Int {
        (stat?.pendingPayments ?? 0) + (stat?.unmatchedPayments ?? 0)
    }

    /// 能不能写金额：只有真实数据源才有"可配对的充电流水"。
    /// 演示/离线下后端会返回 503，与其让用户点一个必然失败的按钮，不如直接禁用。
    var canWrite: Bool {
        !isMock && !AppStore.shared.needsLogin
    }

    // MARK: - 加载

    func load() async {
        loadGeneration += 1
        let generation = loadGeneration

        isLoading = true
        errorMessage = nil
        defer {
            if generation == loadGeneration { isLoading = false }
        }

        if SettingsStore.shared.prefersMockData {
            applyMock()
            return
        }

        // 后端可达但未登录：不请求接口，否则只会刷满服务端报错
        guard !AppStore.shared.needsLogin else {
            stat = nil
            months = []
            errorMessage = "请先在「设置」中登录极氪账号"
            return
        }

        isMock = false

        do {
            let loaded: ChargeMonthsPayload = try await APIClient.shared.get(APIRoutes.chargeMonths)
            guard generation == loadGeneration, !Task.isCancelled else { return }
            months = loaded.months ?? []

            // 跨月后原来选中的月份可能已不在清单里，退回本月
            if !months.isEmpty && !months.contains(where: { $0.yearMonth == selectedMonth }) {
                selectedMonth = "currentMonth"
            }
        } catch {
            // 月份清单取不到也要继续取当月流水：整页空白比少几个选项糟得多
            guard generation == loadGeneration else { return }
            months = []
        }

        await loadSessions(generation: generation)
        await loadOcrStatus()
        await loadPayments()
    }

    func select(month: String) async {
        selectedMonth = month
        loadGeneration += 1
        await loadSessions(generation: loadGeneration)
    }

    /// 单月流水。**只读本地库**，不打网关 —— 每次切月份都去打官方接口既慢又容易被风控。
    private func loadSessions(generation: Int) async {
        var query: [String: String] = [:]
        if !isCurrentMonth { query["yearMonth"] = selectedMonth }

        do {
            let loaded: ChargeMonthStat = try await APIClient.shared.get(
                APIRoutes.chargeSessions,
                query: query
            )
            guard generation == loadGeneration, !Task.isCancelled else { return }
            stat = loaded
            errorMessage = nil
        } catch {
            guard generation == loadGeneration else { return }
            // 真实地址不可达：回落演示数据，保证页面不空白
            applyMock()
            errorMessage = "连接服务端失败，当前展示的是演示数据"
        }
    }

    /// 用本地演示数据填充
    private func applyMock() {
        isMock = true
        months = MockData.chargeMonthOptions
        stat = MockData.chargeStat(yearMonth: selectedMonth)
        payments = []
        ocrConfigured = nil
    }

    // MARK: - 同步官方流水

    /// 幂等。连点由 `isSyncing` 挡住，服务端还有 10 秒冷却兜底。
    func sync() async {
        guard !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }

        if SettingsStore.shared.prefersMockData {
            showToast("演示数据不落库，同步只在真实数据源下有意义")
            return
        }

        do {
            let result: ChargeSyncResult = try await APIClient.shared.post(APIRoutes.chargeSync)
            if result.persisted == false {
                showToast("演示数据不落库（上游 \(result.fetched ?? 0) 条）")
            } else {
                let inserted = result.inserted ?? 0
                let note = inserted > 0 ? "新增 \(inserted) 条" : "无新增"
                showToast("已同步 · \(note)，共 \(result.total ?? 0) 条")
            }
        } catch let error as ApiError {
            showToast(error.errorDescription ?? "同步失败")
            return
        } catch {
            showToast("同步失败：\(error.localizedDescription)")
            return
        }

        await load()
    }

    // MARK: - 金额补录：截图识别

    func loadOcrStatus() async {
        guard !isMock else { return }
        do {
            let status: OcrStatus = try await APIClient.shared.get(APIRoutes.chargeOcrStatus)
            ocrConfigured = status.configured
        } catch {
            ocrConfigured = nil
        }
    }

    /// 上传一张「补能订单」截图。**不入库** —— 结果进 `ocrResult` 等用户核对。
    func runOcr(fileURL: URL) async {
        guard !isOcrBusy else { return }
        isOcrBusy = true
        defer { isOcrBusy = false }

        do {
            let payload: OcrPayload = try await APIClient.shared.uploadFile(
                APIRoutes.chargeOcr,
                fileURL: fileURL,
                fieldName: "file"
            )
            if let rows = payload.rows, !rows.isEmpty {
                ocrResult = payload
            } else {
                ocrResult = nil
                showToast("没从这张图里认出金额，换一张清楚点的试试")
            }
        } catch let error as ApiError {
            ocrResult = nil
            showToast(error.errorDescription ?? "截图识别失败")
        } catch {
            ocrResult = nil
            showToast("截图识别失败：\(error.localizedDescription)")
        }
    }

    /// 把核对过的识别结果入库。
    ///
    /// `rows` 直接是给服务端的 JSON 体（金额 / 电量 / 时间 / 站点 / 归属哪次充电），
    /// 用 `[String: Any]` 而不是模型：**用户在核对框里可能把某项清掉**，
    /// 模型的所有字段都是可选的，序列化时反而要额外处理 nil。
    func commitOcr(imageSha8: String?, rows: [[String: Any]]) async -> Bool {
        guard !rows.isEmpty else { return false }

        var body: [String: Any] = ["rows": rows]
        if let imageSha8 { body["imageSha8"] = imageSha8 }

        do {
            let result: CommitResult = try await APIClient.shared.post(
                APIRoutes.chargeOcrCommit,
                body: body
            )
            let linked = result.linked ?? 0
            let waiting = (result.pending ?? 0) + (result.unmatched ?? 0)
            if waiting > 0 {
                showToast("已保存 \(linked) 笔，\(waiting) 笔待你指定归属")
            } else {
                showToast("已保存 \(linked) 笔金额")
            }
            ocrResult = nil
            await load()
            return true
        } catch let error as ApiError {
            showToast(error.errorDescription ?? "保存失败")
            return false
        } catch {
            showToast("保存失败：\(error.localizedDescription)")
            return false
        }
    }

    // MARK: - 金额补录：手工

    func addManual(amount: Double, paidAt: String, energyKwh: Double?, stationName: String?) async -> Bool {
        var body: [String: Any] = ["amount": amount, "paidAt": paidAt]
        if let energyKwh { body["energyKwh"] = energyKwh }
        if let stationName, !stationName.isEmpty { body["stationName"] = stationName }

        do {
            let result: CommitResult = try await APIClient.shared.post(
                APIRoutes.chargePaymentManual,
                body: body
            )
            if (result.unmatched ?? 0) > 0 {
                showToast("已记录，但没找到对应的充电 —— 去「待确认」指定一下")
            } else {
                showToast("已记录")
            }
            await load()
            return true
        } catch let error as ApiError {
            showToast(error.errorDescription ?? "保存失败")
            return false
        } catch {
            showToast("保存失败：\(error.localizedDescription)")
            return false
        }
    }

    // MARK: - 金额补录：待确认队列

    /// **不筛掉 matched** —— 绑错了要能撤，列表里必须看得到已绑定的那些。
    func loadPayments() async {
        guard !isMock else { payments = []; return }
        do {
            let payload: ChargePaymentsPayload = try await APIClient.shared.get(APIRoutes.chargePayments)
            payments = payload.payments ?? []
        } catch {
            payments = []
        }
    }

    func link(paymentId: String, sessionId: String) async {
        do {
            let _: LinkResult = try await APIClient.shared.post(
                APIRoutes.chargePaymentLink(paymentId),
                body: ["sessionId": sessionId]
            )
            showToast("已绑定到这次充电")
            await load()
        } catch let error as ApiError {
            showToast(error.errorDescription ?? "绑定失败")
        } catch {
            showToast("绑定失败：\(error.localizedDescription)")
        }
    }

    func unlink(paymentId: String) async {
        do {
            let _: LinkResult = try await APIClient.shared.delete(
                APIRoutes.chargePaymentLink(paymentId)
            )
            showToast("已解绑，金额退回待确认")
            await load()
        } catch let error as ApiError {
            showToast(error.errorDescription ?? "解绑失败")
        } catch {
            showToast("解绑失败：\(error.localizedDescription)")
        }
    }

    // MARK: - 提示

    /// 当前 toast 的自动清除任务。连续提示时先取消上一个 ——
    /// 否则先前那个 Task 到点会把**后一条**仍在展示的 toast 提前清掉
    /// （表现为第二条只闪了不到 2.4 秒就消失）。
    private var toastTask: Task<Void, Never>?

    func showToast(_ message: String) {
        toast = message
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_400_000_000)
            guard !Task.isCancelled else { return }
            // 只有"仍然是这条消息"时才清除，避免误清掉更新后的那条
            if self?.toast == message { self?.toast = nil }
        }
    }
}

// MARK: - 接口响应模型

/// 金额入库结果（`_persist_payments` 的返回值）
struct CommitResult: Codable {
    var inserted: Int?
    var skipped: Int?
    var linked: Int?
    var pending: Int?
    var unmatched: Int?
}

/// 绑定 / 解绑结果
struct LinkResult: Codable {
    var sessionId: String?
    var paymentId: String?
}
