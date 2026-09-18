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

    func load(days: Int) async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

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
            trips = loadedTrips
            trend = loadedTrend
        } catch {
            // 真实地址不可达：回落模拟数据，保证页面不空白；
            // 用户已由首页的弹框与徽标知晓当前不是真实数据
            applyMock(days: days)
        }
    }

    /// 用本地模拟数据填充（按所选区间截取趋势尾部）
    private func applyMock(days: Int) {
        trips = MockData.trips
        trend = Array(MockData.energyTrend.suffix(days))
        errorMessage = nil
    }
}
