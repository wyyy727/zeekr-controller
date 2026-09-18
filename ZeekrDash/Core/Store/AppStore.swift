//
//  AppStore.swift
//  ZeekrDash
//
//  全局状态：车辆状态、加载、错误、上次刷新；可配置轮询（充电中 60s）
//
//  数据来源（DataMode）：
//
//    mock    —— 地址未配置或指向 localhost，直接用本地模拟数据，不联网
//    live    —— 配置了真实地址且请求成功
//    offline —— 配置了真实地址但连不上，已回落模拟数据并提示用户
//
//  回落策略：只有当用户真的填了远程地址、却请求失败时才回落，
//  并且会弹框告知一次（避免用户误以为看到的是真车数据）。
//

import SwiftUI

/// 当前页面数据的实际来源
enum DataMode: Equatable {
    /// 本地模拟数据（地址未配置 / 指向 localhost）
    case mock
    /// 真实服务端数据
    case live
    /// 配置了真实地址但连不上，已回落模拟数据
    case offline

    /// 顶栏徽标文案；返回 nil 表示不展示徽标（真实数据无需标识）
    var badgeText: String? {
        switch self {
        case .mock:    return "模拟数据"
        case .offline: return "模拟数据 · 后端不可达"
        case .live:    return nil
        }
    }
}

@Observable
@MainActor
final class AppStore {

    static let shared = AppStore(settings: SettingsStore.shared)

    // MARK: - 状态

    var vehicleStatus: VehicleStatus?
    var isLoading = false
    var errorMessage: String?
    var lastRefresh: Date?

    /// 全局 Toast 文案（车控指令回执等），由 RootView 统一呈现
    var toast: String?

    /// 当前数据来源；真实地址连不上时会停留在 .offline
    var dataMode: DataMode = .mock

    /// 需要在界面上弹框告知的数据源变化（由 RootView 消费后置回 nil）
    var pendingDataSourceNotice: String?

    private var toastTask: Task<Void, Never>?
    /// 已经为「当前这个地址」提示过回落，避免每次轮询都弹一次
    private var didNotifyFallback = false

    /// 是否已成功拿到过数据
    var hasData: Bool { vehicleStatus != nil }

    /// 充电中（决定轮询节奏）
    var isCharging: Bool { vehicleStatus?.isCharging == true }

    /// 顶栏徽标文案（nil 表示不显示）
    var modeBadgeText: String? { dataMode.badgeText }

    private let settings: SettingsStore
    private var pollTask: Task<Void, Never>?

    init(settings: SettingsStore) {
        self.settings = settings
        // 首次进入按地址形态定基线；真实地址要等第一次请求才知道通不通
        dataMode = settings.prefersMockData ? .mock : .live
    }

    // MARK: - 手动刷新

    func refresh() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        // ① 地址未配置 / 指向 localhost：直接用模拟数据，不发起请求
        guard !settings.prefersMockData else {
            applyMockData()
            return
        }

        // ② 配置了真实地址：正常请求，失败则回落模拟数据并提示
        do {
            let status: VehicleStatus = try await APIClient.shared.get(APIRoutes.vehicleStatus)
            vehicleStatus = status
            lastRefresh = Date()
            dataMode = .live
            didNotifyFallback = false
        } catch let error as ApiError {
            fallbackToMock(reason: error.errorDescription)
        } catch {
            fallbackToMock(reason: error.localizedDescription)
        }
    }

    // MARK: - 模拟数据

    /// 直接用本地模拟数据填充状态
    private func applyMockData() {
        vehicleStatus = MockData.vehicleStatus
        lastRefresh = Date()
        dataMode = .mock
        // 数据已拿到，空态卡片的报错没有意义
        errorMessage = nil
    }

    /// 真实地址不可达时的回落：切到模拟数据，并（每个地址只弹一次）告知用户
    private func fallbackToMock(reason: String?) {
        vehicleStatus = MockData.vehicleStatus
        lastRefresh = Date()
        dataMode = .offline
        errorMessage = nil

        guard !didNotifyFallback else { return }
        didNotifyFallback = true
        pendingDataSourceNotice = Self.fallbackNotice(reason: reason)
    }

    private static func fallbackNotice(reason: String?) -> String {
        let detail = (reason?.isEmpty == false) ? "\n\n\(reason!)" : ""
        return """
        连接服务端失败，已暂时切换为模拟数据，当前展示的不是真实车况。\(detail)

        请检查设置中的服务端地址，或确认服务端已启动。
        """
    }

    /// 地址变更后重置提示状态，让新地址可以重新提示一次
    func resetFallbackNotification() {
        didNotifyFallback = false
    }

    // MARK: - 轮询

    /// 启动轮询（App 进入前台时调用；重复调用安全）
    ///
    /// 模拟数据模式下没有可轮询的后端，直接不启动 —— 既省电，也避免
    /// 每 5 分钟把同一份演示数据重新赋值一次造成的无意义重绘。
    func startPolling() {
        guard !settings.prefersMockData else { return }
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            await self?.refresh()
            while !Task.isCancelled {
                guard let interval = self?.currentInterval() else { break }
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard !Task.isCancelled else { break }
                await self?.refresh()
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// 当前轮询间隔：充电中 60 秒，否则按设置（分钟）
    private func currentInterval() -> TimeInterval {
        isCharging ? 60 : settings.pollIntervalMinutes * 60
    }

    /// 下发车控指令（供车控面板调用）
    ///
    /// 模拟数据模式下不发真实请求，直接返回本地回执，
    /// 让车控面板的动效链路在无后端时同样可以完整预览。
    func send(command: VehicleCommand) async -> CommandResult? {
        guard dataMode != .mock else {
            applyLocalCommand(command)
            return CommandResult(
                success: true,
                message: "模拟数据模式：指令已在本地生效",
                command: command.rawValue
            )
        }

        do {
            let result: CommandResult = try await APIClient.shared.post(
                APIRoutes.vehicleCommand,
                body: ["command": command.rawValue, "params": [:] as [String: Any]]
            )
            if result.success { await refresh() }
            return result
        } catch let error as ApiError {
            errorMessage = error.errorDescription
            return nil
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    /// 模拟数据模式下让状态随指令联动，开关类按钮才有「点得动」的真实感。
    ///
    /// 覆盖范围与 `preview/index.html` 的 `applyDemoCommand` 保持一致（7 项）。
    /// 其余纯瞬时动作（闪灯 / 鸣笛 / 寻车等）在模拟模式下本就没有状态可改，
    /// 只回执成功即可。
    private func applyLocalCommand(_ command: VehicleCommand) {
        guard var status = vehicleStatus else { return }
        switch command {
        case .lock:
            status.isLocked = true
        case .unlock:
            status.isLocked = false
        case .climateOn:
            status.climateOn = true
        case .climateOff:
            status.climateOn = false
        case .closeWindows:
            status.windows = ["driver": false, "passenger": false,
                              "rearLeft": false, "rearRight": false]
        case .chargeStart:
            status.isCharging = true
        case .chargeStop:
            status.isCharging = false
        default:
            // 瞬时动作 / 场景类：无状态可联动
            break
        }
        vehicleStatus = status
        lastRefresh = Date()
    }

    // MARK: - 全局提示

    /// 展示一条底部 Toast，2.2 秒后自动消失
    func showToast(_ message: String) {
        toast = message
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_200_000_000)
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }
}
