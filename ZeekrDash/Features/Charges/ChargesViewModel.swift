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

    /// 截图识别是否可用。`nil` = 还没问过服务端（此时不显示任何降级提示）。
    var ocrConfigured: Bool?
    /// 识别失败的原因（界面在「金额补录」卡里就地显示，不只靠 Toast ——
    /// Toast 一秒就没了，用户回头想看清为什么失败时已经找不到）
    var ocrErrorMessage: String?

    /// 识别完成的时刻（核对框副标题「已识别 N 张 · HH:MM」用）
    var ocrAt: Date?

    /// 识别结果（**未入库**），核对弹窗的数据源
    var ocrResult: OcrPayload?
    /// 金额证据列表（含已绑定的 —— 绑错了要能撤）
    var payments: [ChargePayment] = []

    /// 当前展示的是不是演示数据（界面据此标徽标、禁用补录入口）
    private(set) var isMock = false

    /// 上次同步完成的时间。存 `UserDefaults`（见 `ChargeSyncStamp`）——
    /// "今天同步过没有"必须跨启动记得住，否则每次冷启动都会重拉一遍两年流水。
    private(set) var lastSyncedAt: Date?

    /// 本次启动是否已经自动同步过：切 tab / 反复刷新不该连打网关
    private var autoSyncedThisRun = false
    /// 充电结束后已排队一次同步，别重复排
    private var chargeEndSyncPending = false

    /// 加载代次。切月份会连发请求，先发后到时用它丢弃过时的结果 ——
    /// 否则旧月份的数据会把新选中的月份覆盖掉。
    private var loadGeneration = 0

    init() {
        lastSyncedAt = ChargeSyncStamp.last
    }

    // MARK: - 派生值

    /// 供通用月份滚轮使用（`MonthPickerSheet` 只认 `MonthOption`）
    var monthOptions: [MonthOption] {
        months.map { MonthOption(yearMonth: $0.yearMonth ?? "currentMonth", label: $0.label ?? "本月") }
    }

    var isCurrentMonth: Bool { selectedMonth == "currentMonth" }

    /// 月份胶囊文案。与行程页同一套真源（HTML `v2MonthText()`）：
    /// 本月显示「2026年10月」，不是「本月」。
    var selectedMonthLabel: String {
        MonthLabel.text(for: selectedMonth)
    }

    var records: [ChargeSession] { stat?.records ?? [] }
    var count: Int { stat?.count ?? 0 }

    /// 累计金额：所有可查月份的金额之和（服务端按月汇总好，这里只做加法）。
    /// 没有月份带金额时给 nil —— 显示 0 会被读成"一分没花"。
    var totalAmountText: String {
        let sum = months.reduce(0.0) { $0 + ($1.amount ?? 0) }
        return sum > 0 ? "¥" + String(format: "%.2f", sum) : "--"
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

    /// 标题行右侧那行小字。**页面没有同步按钮，这是唯一的数据新鲜度线索**。
    var lastSyncText: String {
        guard let lastSyncedAt else { return "未同步" }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return "同步于 " + formatter.string(from: lastSyncedAt)
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

        var hasData = true
        do {
            let loaded: ChargeMonthsPayload = try await APIClient.shared.get(APIRoutes.chargeMonths)
            guard generation == loadGeneration, !Task.isCancelled else { return }
            months = loaded.months ?? []
            hasData = loaded.hasData ?? !months.isEmpty

            // 跨月后原来选中的月份可能已不在清单里，退回本月
            if !months.isEmpty && !months.contains(where: { $0.yearMonth == selectedMonth }) {
                selectedMonth = "currentMonth"
            }
        } catch {
            // 月份清单取不到也要继续取当月流水：整页空白比少几个选项糟得多
            guard generation == loadGeneration else { return }
            months = []
            hasData = false
        }

        /* 空库 / 跨天 ⇒ 静默同步一次。
           页面上没有手动同步按钮，这里是"补数据"的主要入口：
             · 空库 —— 第一次打开必须填上，否则整页是空的；
             · 跨天 —— 上次同步不是今天（防"上次充电时 App 没开"漏数据）。
           同一天反复进页面不会再打网关：官方接口一次给两年全量，每次都拉纯属浪费。 */
        if (!hasData || ChargeSyncStamp.isStale || ChargeSyncStamp.hasPendingCharge)
            && !autoSyncedThisRun {
            autoSyncedThisRun = true
            let synced = await sync(silent: true)
            /* 成功时 sync 内部已经重新 load 过（会走完下面的读取），直接返回；
               失败（429 冷却 / 401 / 网络抖动）**必须继续往下读本地库** ——
               原来无条件 return，页面会显示"本月没有充电记录"，而库里其实有。 */
            if synced { return }
        }

        await loadSessions(generation: generation)
        await loadOcrStatus()
        await loadPayments()
    }

    func select(month: String) async {
        selectedMonth = month
        // 自增代次会让正在跑的 load() 提前退出，而它的 defer 因代次不等不会复位 ——
        // 这里补一次，否则月份行永远显示"· 更新中"、首屏骨架永不消失。
        isLoading = false
        loadGeneration += 1
        let generation = loadGeneration

        /* 切月期间把旧月份的汇总清掉。
           `loadSessions` 是异步的，不清就会出现「新月份的标题 + 上个月的数字」——
           HTML 用 `ymMismatch` 专门挡这个（4819 行），这里用骨架顶住同样的窗口。 */
        stat = nil
        isLoading = true
        await loadSessions(generation: generation)
        if generation == loadGeneration { isLoading = false }
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

    /// 幂等。并发由 `isSyncing` 挡住，服务端还有 10 秒冷却兜底。
    ///
    /// `silent` 用于自动触发（空库 / 跨天 / 充电结束）—— 那时用户没点任何东西，
    /// 成功失败都不该弹 toast。
    @discardableResult
    func sync(silent: Bool = false) async -> Bool {
        guard !isSyncing else { return false }
        isSyncing = true
        defer { isSyncing = false }

        if SettingsStore.shared.prefersMockData {
            if !silent { showToast("演示数据不落库，同步只在真实数据源下有意义") }
            return false
        }

        do {
            let result: ChargeSyncResult = try await APIClient.shared.post(APIRoutes.chargeSync)
            /* 只有**真的打到网关**才记时间：429（10 秒冷却）/ 401 / 网络失败都不记，
               否则一次失败会被当成"今天已经同步过"，当天不再重试。
               服务端说 `persisted == false`（它自己处于 mock 态）同理不算 ——
               否则切到真实数据源后当天不会再同步，充电页空一天。 */
            if result.persisted != false {
                ChargeSyncStamp.mark()
                lastSyncedAt = ChargeSyncStamp.last
            }

            if !silent {
                if result.persisted == false {
                    showToast("演示数据不落库（上游 \(result.fetched ?? 0) 条）")
                } else {
                    let inserted = result.inserted ?? 0
                    let note = inserted > 0 ? "新增 \(inserted) 条" : "无新增"
                    showToast("已同步 · \(note)，共 \(result.total ?? 0) 条")
                }
            }
        } catch let error as ApiError {
            if !silent { showToast(error.errorDescription ?? "同步失败") }
            return false
        } catch {
            if !silent { showToast("同步失败：\(error.localizedDescription)") }
            return false
        }

        await load()
        return true
    }

    /// 下拉刷新：等于"现在就去拉一次"（原生手势，界面上不占位置）。
    /// 演示模式下没有可拉的网关，退回本地重算。
    func refresh() async {
        if isMock || SettingsStore.shared.prefersMockData {
            await load()
            return
        }
        await sync(silent: false)
    }

    /// 充电结束 = **唯一真正会产生新流水的时刻**。
    ///
    /// 官方落库有延迟（实测几十秒），所以等一分钟再拉；
    /// 轮询间隔本来就跟着充电状态走（充电中 60 秒一次），这个跳变一定抓得到。
    func syncAfterChargeEnd() async {
        guard !chargeEndSyncPending else { return }
        chargeEndSyncPending = true
        defer { chargeEndSyncPending = false }

        try? await Task.sleep(nanoseconds: 60_000_000_000)
        guard !Task.isCancelled else { return }
        await sync(silent: true)
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

    /// 上传一张「补能订单」截图（文件 URL 版）。**不入库** —— 结果进 ocrResult 等用户核对。
    func runOcr(fileURL: URL) async {
        await runOcrUpload {
            try await APIClient.shared.uploadFile(
                APIRoutes.chargeOcr,
                fileURL: fileURL,
                fieldName: "file"
            )
        }
    }

    /// 上传一张「补能订单」截图（字节版，**相册选图走这条**）。
    ///
    /// 为什么单开一条：iOS 相册选出来的图没有稳定文件 URL，PhotosPicker 直接把
    /// Data 交给我们；为了复用 fileURL 版先落一个临时文件再读回来，既多一次
    /// 磁盘往返，又要自己负责删。字节版直接把内存里的字节拼进 multipart。
    func runOcr(imageData: Data, filename: String) async {
        await runOcrUpload {
            try await APIClient.shared.uploadFile(
                APIRoutes.chargeOcr,
                data: imageData,
                filename: filename,
                fieldName: "file"
            )
        }
    }

    /// 两条入口共用：忙碌标记、错误归一、结果写进 ocrResult（**不入库**）。
    private func runOcrUpload(_ upload: () async throws -> OcrPayload) async {
        guard !isOcrBusy else { return }
        isOcrBusy = true
        ocrErrorMessage = nil
        defer { isOcrBusy = false }

        do {
            let payload = try await upload()
            if let rows = payload.rows, !rows.isEmpty {
                ocrResult = payload
                // 副标题要显示「已识别 N 张 · HH:MM」，记下这一刻
                ocrAt = Date()
            } else {
                ocrResult = nil
                showToast("没从这张图里认出金额，换一张清楚点的试试")
            }
        } catch let error as ApiError {
            ocrResult = nil
            ocrErrorMessage = error.errorDescription ?? "截图识别失败"
            showToast(ocrErrorMessage ?? "截图识别失败")
        } catch {
            ocrResult = nil
            ocrErrorMessage = error.localizedDescription
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

    /// 提示交给全局 Toast（`AppStore.showToast`），由 RootView 统一呈现。
    ///
    /// 以前这里自己存了一份 `toast` 并在充电页 overlay 里渲染，
    /// 位置（底部 110pt）与全局 Toast（底部导航胶囊上方）不一样 ——
    /// 同一种提示在两个高度出现，用户会以为是两条消息。
    /// 全 App 统一一处，位置、动效、时长才一致。
    func showToast(_ message: String) {
        AppStore.shared.showToast(message)
    }
}

// MARK: - 接口响应模型

/// 充电流水的同步时间戳（`UserDefaults`，跨启动保留）。
///
/// 页面上**没有手动同步按钮**，只有三种自动触发：空库 / 跨天 / 充电结束。
/// "今天同步过没有"必须跨启动记得住，否则每次冷启动都会重拉一遍两年流水。
///
/// 与服务端的 10 秒冷却无关 —— 那个只防连点。
enum ChargeSyncStamp {

    private static let key = "zk.chargeSyncAt"
    /// 充电结束但还没同步过的标记。
    ///
    /// 为什么需要它：充电结束的监听挂在 `ChargesView` 上，而切 tab 会销毁这个视图 ——
    /// 用户充完电去看车况，那次同步就丢了；而"当天已同步"又拦住了后续补同步。
    /// 所以 RootView 全局记一个待办，下次进充电页由 `load()` 消费。
    private static let pendingKey = "zk.chargeSyncPending"

    static var last: Date? {
        let stamp = UserDefaults.standard.double(forKey: key)
        return stamp > 0 ? Date(timeIntervalSince1970: stamp) : nil
    }

    /// 上次同步不是今天 ⇒ 该补一次。跨天就算过期，不看几小时 ——
    /// 一天最多打一次网关，比"6 小时"更省也更好解释。
    static var isStale: Bool {
        guard let last else { return true }
        return !Calendar.current.isDateInToday(last)
    }

    /// 充电结束（`isCharging` true→false）：记一笔待办，下次进充电页补同步
    static func markCharged() {
        UserDefaults.standard.set(true, forKey: pendingKey)
    }

    /// 有没有"充完电还没同步"的待办
    static var hasPendingCharge: Bool {
        UserDefaults.standard.bool(forKey: pendingKey)
    }

    static func mark() {
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: key)
        // 同步成功 ⇒ 待办已消化
        UserDefaults.standard.removeObject(forKey: pendingKey)
    }

    /// 退出登录时清掉：换个人登录不该沿用上一位的「同步于」，也会打乱跨天判断。
    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
        UserDefaults.standard.removeObject(forKey: pendingKey)
    }
}

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
