//
//  TripsViewModel.swift
//  ZeekrDash
//
//  行程页状态管理（官方「行程与能耗」统计）
//

import Foundation
import SwiftUI

@Observable
@MainActor
final class TripsViewModel {

    // MARK: - 状态

    /// 每日图表的区间。**仅「本月」可选**；选了历史月份时图表固定整月。
    var selectedDays: Int = 7

    /// 选中的统计月份：`currentMonth` 表示本月，其余形如 `2026-09`。
    var selectedMonth: String = "currentMonth"

    /// 可选月份（官方 `mileageBaseInfo.existingMonth`，首项固定「本月」）
    var months: [EnergyMonth] = []

    /// 供通用月份滚轮使用（`MonthPickerSheet` 只认 `MonthOption`）
    var monthOptions: [MonthOption] {
        months.map { MonthOption(yearMonth: $0.yearMonth, label: $0.label) }
    }

    /// 汇总卡数据：本月 → 本月 1 日至今；历史月 → 该整月
    var monthStats: DailyEnergy?
    /// 图表数据：本月 → 近 N 天；历史月 → 该整月
    var windowStats: DailyEnergy?

    var isLoading = false
    var errorMessage: String?

    // MARK: - 派生

    var isCurrentMonth: Bool {
        selectedMonth == "currentMonth" || selectedMonth.isEmpty
    }

    var selectedMonthLabel: String {
        if isCurrentMonth { return "本月" }
        return months.first(where: { $0.yearMonth == selectedMonth })?.label ?? selectedMonth
    }

    var series: [DailyEnergyPoint] {
        windowStats?.series ?? []
    }

    /// 充电次数 = 快充 + 慢充
    var chargeCount: Int {
        (monthStats?.fastChargeCount ?? 0) + (monthStats?.slowChargeCount ?? 0)
    }

    /// 里程柱状图的 Y 轴：峰值先取整到 1/2/5×10ⁿ，再留 10% 余量。
    ///
    /// 直接贴着峰值画会把柱子顶到框顶，和电耗折线看起来几乎一样；
    /// 留白后两组数据的量级差异才看得出来（与网页 `niceMax` 同一规则）。
    var distanceRange: ClosedRange<Double> {
        let values = series.compactMap(\.distanceKm)
        guard let highest = values.max(), highest > 0 else { return 0...50 }

        let exponent = floor(log10(highest))
        let base = pow(10, exponent)
        let ratio = highest / base
        let step: Double = ratio <= 1 ? 1 : (ratio <= 2 ? 2 : (ratio <= 5 ? 5 : 10))
        return 0...(step * base * 1.1)
    }

    /// 电耗折线：上下各留 12% 余量
    var energyRange: ClosedRange<Double> {
        let values = series.compactMap(\.energyKwh)
        guard let lowest = values.min(), let highest = values.max(), lowest < highest else {
            return 0...10
        }
        let padding = (highest - lowest) * 0.12
        return Swift.max(0, lowest - padding)...(highest + padding)
    }

    /// 图表内容宽度：每个数据点固定 56pt，点多了横向滚动（不压缩间距）
    var chartWidth: CGFloat {
        max(300, CGFloat(series.count) * 56)
    }

    // MARK: - 加载

    /// 当前加载代次。每次 `load` 自增，用于丢弃"过时请求"的结果。
    ///
    /// 为什么需要：切月份 / 切区间都会触发加载，同时飞多个请求时，
    /// 先发的如果后返回就会用**旧月份**的数据覆盖新选中的月份。
    private var loadGeneration = 0

    func load(days: Int) async {
        loadGeneration += 1
        let generation = loadGeneration

        isLoading = true
        errorMessage = nil
        defer {
            if generation == loadGeneration { isLoading = false }
        }

        // 地址未配置 / 指向 localhost：直接用本地演示数据，不联网
        if SettingsStore.shared.prefersMockData {
            applyMock(days: days)
            return
        }

        // 后端可达但未登录：不请求接口，否则只会刷满服务端报错
        guard !AppStore.shared.needsLogin else {
            monthStats = nil
            windowStats = nil
            errorMessage = "请先在「设置」中登录极氪账号"
            return
        }

        do {
            // 月份清单只取一次；失败不影响主流程（只是选择器少几个选项）
            if months.isEmpty {
                let loaded: EnergyMonths = try await APIClient.shared.get(APIRoutes.tripsEnergyMonths)
                months = loaded.months ?? []
            }

            var monthQuery = ["scope": "month"]
            if !isCurrentMonth {
                monthQuery["yearMonth"] = selectedMonth
            }
            let month: DailyEnergy = try await APIClient.shared.get(
                APIRoutes.tripsEnergy,
                query: monthQuery
            )

            // 本月才额外取「近 N 天」；历史月份图表就用整月数据
            var window = month
            if isCurrentMonth {
                let clamped = Swift.max(1, Swift.min(days, 31))   // 官方上限 31 天（A008）
                let loaded: DailyEnergy? = try? await APIClient.shared.get(
                    APIRoutes.tripsEnergy,
                    query: ["days": String(clamped)]
                )
                if let loaded { window = loaded }
            }

            guard generation == loadGeneration, !Task.isCancelled else { return }

            monthStats = month
            windowStats = window
        } catch {
            guard generation == loadGeneration else { return }

            applyMock(days: days)
            // 保留错误提示：否则用户不知道当前看到的是模拟数据
            errorMessage = "连接服务端失败，当前展示的是模拟数据"
        }
    }

    /// 切换统计月份（选择器回调）
    func select(month: String) async {
        selectedMonth = month
        await load(days: selectedDays)
    }

    /// 用本地模拟数据填充
    private func applyMock(days: Int) {
        if months.isEmpty {
            months = MockData.energyMonths().months ?? []
        }
        monthStats = isCurrentMonth
            ? MockData.dailyEnergy(days: Calendar.current.component(.day, from: Date()))
            : MockData.dailyEnergy(yearMonth: selectedMonth)
        windowStats = isCurrentMonth ? MockData.dailyEnergy(days: days) : monthStats
        errorMessage = nil
    }
}
