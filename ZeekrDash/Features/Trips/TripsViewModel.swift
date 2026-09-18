//
//  TripsViewModel.swift
//  ZeekrDash
//
//  行程页状态管理
//

import Foundation
import SwiftUI

@Observable
@MainActor
final class TripsViewModel {

    // MARK: - 状态

    var selectedDays: Int = 30
    var trips: [Trip] = []
    var trend: [EnergyTrendPoint] = []
    var isLoading = false
    var errorMessage: String?

    // MARK: - 派生统计

    var totalDistance: Double {
        trend.compactMap(\.distanceKm).reduce(0, +)
    }

    var totalEnergy: Double {
        trend.compactMap(\.energyKwh).reduce(0, +)
    }

    /// 加权平均能耗 —— 用总能耗 / 总里程计算，而非各日平均值的平均
    var avgConsumption: Double? {
        let distance = totalDistance
        guard distance > 0 else { return nil }
        return (totalEnergy / distance) * 100
    }

    /// 图表 Y 轴范围，留出上下边距让曲线不贴边
    var consumptionRange: ClosedRange<Double> {
        let values = trend.compactMap(\.consumption)
        // 注意：不要用 min / max 作局部变量名，会遮蔽 Swift 全局的 min(_:_:) / max(_:_:)
        guard let lowest = values.min(), let highest = values.max(), lowest < highest else {
            return 10...25
        }
        let padding = (highest - lowest) * 0.15
        return Swift.max(0, lowest - padding)...(highest + padding)
    }

    // MARK: - 加载

    /// 当前加载代次。每次 `load` 自增，用于丢弃"过时请求"的结果。
    ///
    /// 为什么需要：分段控件切得快时会同时有多个 load 在飞。先前那个如果后返回，
    /// 就会用**旧区间**的数据覆盖新区间（图表显示的日期范围与选中项不符），
    /// 而且它的 `defer` 会把 `isLoading` 提前置回 false、加载态提前消失。
    private var loadGeneration = 0

    func load(days: Int) async {
        loadGeneration += 1
        let generation = loadGeneration

        isLoading = true
        errorMessage = nil
        defer {
            // 只有"最后一次"加载才有资格关掉加载态
            if generation == loadGeneration { isLoading = false }
        }

        // 地址未配置 / 指向 localhost：直接使用本地模拟数据，不联网
        if SettingsStore.shared.prefersMockData {
            applyMock(days: days)
            return
        }

        do {
            // 两个请求并发，缩短等待时间
            async let tripsTask: [Trip] = APIClient.shared.get(
                APIRoutes.trips,
                query: ["days": String(days)]
            )
            async let trendTask: [EnergyTrendPoint] = APIClient.shared.get(
                APIRoutes.energyTrend,
                query: ["days": String(days)]
            )

            let (loadedTrips, loadedTrend) = try await (tripsTask, trendTask)

            // 已被更新的请求取代（或任务被取消）：丢弃本次结果，不要写回
            guard generation == loadGeneration, !Task.isCancelled else { return }

            trips = loadedTrips
            trend = loadedTrend
        } catch {
            // 期间已经有更新的加载在跑，别用旧请求的失败去覆盖它的状态
            guard generation == loadGeneration else { return }

            // 真实地址不可达：回落模拟数据，保证页面不空白
            applyMock(days: days)
            // 同时把错误留下来供界面提示。
            // 此前这里连 errorMessage 也被 applyMock 置成 nil，导致
            // TripsView 的错误态 UI 永远走不到（是段死代码），用户也就
            // 完全不知道「当前看到的其实是模拟数据」。
            errorMessage = "连接服务端失败，当前展示的是模拟数据"
        }
    }

    /// 用本地模拟数据填充（按所选区间截取趋势尾部）
    private func applyMock(days: Int) {
        trips = MockData.trips
        trend = Array(MockData.energyTrend.suffix(days))
        errorMessage = nil
    }
}
