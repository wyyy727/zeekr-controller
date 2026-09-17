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
        guard let min = values.min(), let max = values.max(), min < max else {
            return 10...25
        }
        let padding = (max - min) * 0.15
        return max(0, min - padding)...(max + padding)
    }

    // MARK: - 加载

    func load(days: Int) async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

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
        } catch let error as ApiError {
            errorMessage = error.errorDescription
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
