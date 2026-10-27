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

    /// 图表**实际**用的区间。
    ///
    /// 历史月份没有 7/30 段控件（HTML 4628 行），布局固定按 30 天：
    /// 否则本月选过 7 天后切历史月，整月柱子会按 56pt 窄柱横滑，却没有入口能改回来。
    var effectiveDays: Int { isCurrentMonth ? selectedDays : 30 }

    /// 入场动画代次。+1 相当于「可以重播」：
    /// · 进页面 → +1（HTML `goTab()` 里把 tripsChartAnim 清零）
    /// · 切 7/30 → +1（HTML 7506 行同样清零）
    /// · 切月份 → **不变**（页内切月份不重播，这是 HTML 的既定行为）
    private(set) var chartAnimToken = 0

    func replayChartAnimation() { chartAnimToken += 1 }

    func setDays(_ days: Int) {
        guard days != selectedDays else { return }
        selectedDays = days
        chartAnimToken += 1
    }

    /// 选中的统计月份：`currentMonth` 表示本月，其余形如 `2026-09`。
    var selectedMonth: String = "currentMonth"

    /// 可选月份（官方 `mileageBaseInfo.existingMonth`，首项固定「本月」）
    var months: [EnergyMonth] = []

    /// 当前 `months` 是不是**服务端真实清单**。
    ///
    /// 为什么需要这个标记：以前只有 `months.isEmpty` 一道判断，一旦某次请求失败，
    /// `applyMock()` 会用演示月份填满它，之后**整个会话都不会再请求** ——
    /// 网络恢复了也还是那几个月，重启 App 才恢复。这是个真 bug（真机表现为
    /// 「年份只有今年、月份只到 5 月」，因为演示数据当时只造了 5 个历史月）。
    private var monthsAreLive = false

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

    /// 月份胶囊文案。真源是 HTML 的 `v2MonthText()`：本月也显示成「2026年10月」，
    /// 不是「本月」。别再按 `isCurrentMonth` 分叉。
    var selectedMonthLabel: String {
        MonthLabel.text(for: selectedMonth)
    }

    var series: [DailyEnergyPoint] {
        windowStats?.series ?? []
    }

    // MARK: - 图表数据点

    /// 里程柱。`value` 取 `distanceKm`，不拆分。
    var distancePoints: [V2ChartPoint] {
        series.enumerated().map { index, p in
            V2ChartPoint(
                id: index,
                value: p.distanceKm,
                dynamic: nil,
                staticPart: nil,
                label: dayLabel(p.date),
                full: fullDay(p.date)
            )
        }
    }

    /// 电耗柱。`dynamic` / `staticPart` 都有值时画成上下两段（HTML `v2BarBody()`），
    /// 缺任一侧退回单色柱 —— 与 HTML 的 `if (d == null || s == null)` 判据一致。
    var energyPoints: [V2ChartPoint] {
        series.enumerated().map { index, p in
            V2ChartPoint(
                id: index,
                value: p.energyKwh,
                dynamic: p.dynamicKwh,
                staticPart: p.staticKwh,
                label: dayLabel(p.date),
                full: fullDay(p.date)
            )
        }
    }

    /// X 轴标签：7 天只写日号（`9`），30 天写 `10/9`。日期缺失/畸形时返回空串，
    /// 而不是渲染出 `NaN/NaN`（HTML 4620 行专门处理过）。
    private func dayLabel(_ raw: String) -> String {
        guard let (month, day) = Self.monthDay(raw) else { return "" }
        return effectiveDays == 7 ? String(day) : "\(month)/\(day)"
    }

    /// 气泡里的完整日期，始终 `10/9`（不含年份：图表窗口最长 31 天，MM/DD 唯一）
    private func fullDay(_ raw: String) -> String {
        guard let (month, day) = Self.monthDay(raw) else { return "" }
        return "\(month)/\(day)"
    }

    /// `2026-10-09` → (10, 9)；用 Number 语义，去掉前导零
    private static func monthDay(_ raw: String) -> (Int, Int)? {
        let parts = raw.split(separator: "-")
        guard parts.count >= 3,
              let m = Int(parts[1]), let d = Int(parts[2]),
              m > 0, d > 0 else { return nil }
        return (m, d)
    }

    // MARK: - 加载

    /// 当前加载代次。每次 `load` 自增，用于丢弃"过时请求"的结果。
    ///
    /// 为什么需要：切月份 / 切区间都会触发加载，同时飞多个请求时，
    /// 先发的如果后返回就会用**旧月份**的数据覆盖新选中的月份。
    private var loadGeneration = 0

    func load() async {
        loadGeneration += 1
        let generation = loadGeneration
        var days = effectiveDays

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
            /* 月份清单：拿到过真实清单就不再重复请求；**失败不致命** ——
               它只影响选择器能选几个月，不该把整页数据一起拖进 catch。
               以前这里是 `try await`，注释写着"失败不影响主流程"，实际却会整页回落演示数据。 */
            if !monthsAreLive {
                let loaded: EnergyMonths? = try? await APIClient.shared.get(APIRoutes.tripsEnergyMonths)
                if let loaded {
                    months = loaded.months ?? []
                    monthsAreLive = true
                    // 选中月份已不在可查清单里（跨月 / 清单变短）：退回本月，
                    // 别停在一个查不到的月份上（HTML `loadEnergyMonths` 同样有这段兜底）
                    if !isCurrentMonth, !months.contains(where: { $0.yearMonth == selectedMonth }) {
                        selectedMonth = "currentMonth"
                        selectedDays = 7
                        days = 7          // 本次请求就按本月口径取，别沿用历史月的 30
                    }
                }
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
    ///
    /// 换月把区间复位成 7 天（HTML 6437 行 `state.days = 7`）：
    /// 上月选了 30 天，再切回本月时不该沿用那个选择。
    /// 注意**不动** `chartAnimToken` —— 页内切月份不重播入场动画。
    func select(month: String) async {
        selectedMonth = month
        selectedDays = 7
        await load()
    }

    /// 用本地模拟数据填充
    ///
    /// ⚠️ 这里填 `months` **只是为了让选择器有内容可显示**，
    /// 不能把它当成「已加载真实清单」—— `monthsAreLive` 保持 false，
    /// 下次进页面仍会重新请求，否则一次失败就把月份选择器永久锁在演示数据上。
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
