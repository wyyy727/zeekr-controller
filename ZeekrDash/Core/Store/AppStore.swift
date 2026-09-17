//
//  AppStore.swift
//  ZeekrDash
//
//  全局状态：车辆状态、加载、错误、上次刷新；可配置轮询（充电中 60s）
//

import SwiftUI

@Observable
final class AppStore {

    static let shared = AppStore(settings: SettingsStore.shared)

    // MARK: - 状态

    var vehicleStatus: VehicleStatus?
    var isLoading = false
    var errorMessage: String?
    var lastRefresh: Date?

    /// 是否已成功拿到过数据
    var hasData: Bool { vehicleStatus != nil }

    /// 充电中（决定轮询节奏）
    var isCharging: Bool { vehicleStatus?.isCharging == true }

    private let settings: SettingsStore
    private var pollTask: Task<Void, Never>?

    init(settings: SettingsStore) {
        self.settings = settings
    }

    // MARK: - 手动刷新

    @MainActor
    func refresh() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let status: VehicleStatus = try await APIClient.shared.get(APIRoutes.vehicleStatus)
            vehicleStatus = status
            lastRefresh = Date()
        } catch let error as ApiError {
            errorMessage = error.errorDescription
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - 轮询

    /// 启动轮询（App 进入前台时调用；重复调用安全）
    func startPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            await self?.refresh()
            while !Task.isCancelled {
                let interval = await self?.currentInterval() ?? 300
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
    @MainActor
    private func currentInterval() -> TimeInterval {
        isCharging ? 60 : settings.pollIntervalMinutes * 60
    }

    /// 下发车控指令（供车控面板调用）
    @MainActor
    func send(command: VehicleCommand) async -> CommandResult? {
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
}
