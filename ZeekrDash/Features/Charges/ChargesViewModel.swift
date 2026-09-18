//
//  ChargesViewModel.swift
//  ZeekrDash
//
//  充电消费页状态管理
//

import Foundation
import SwiftUI

@Observable
@MainActor
final class ChargesViewModel {

    // MARK: - 状态

    var summary: ChargeSummary?
    var records: [ChargeRecord] = []
    var isLoading = false
    var errorMessage: String?
    var toast: String?

    // MARK: - 派生值

    var totalAmount: Double { summary?.totalAmount ?? 0 }
    var totalCount: Int { summary?.totalCount ?? 0 }
    var avgUnitPrice: Double? { summary?.avgUnitPrice }

    var providerCount: Int {
        (summary?.byProvider ?? []).count
    }

    /// 服务商统计（按金额降序，供图表使用）
    var providerStats: [ChargeProviderStat] {
        (summary?.byProvider ?? [])
            .filter { ($0.amount ?? 0) > 0 }
            .sorted { ($0.amount ?? 0) > ($1.amount ?? 0) }
    }

    /// 月度统计（按时间正序，供图表使用）
    var monthlyStats: [ChargeMonthlyStat] {
        (summary?.monthly ?? []).sorted { $0.month < $1.month }
    }

    // MARK: - 加载

    func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        // 地址未配置 / 指向 localhost：直接使用本地模拟数据，不联网
        if SettingsStore.shared.prefersMockData {
            applyMock()
            return
        }

        do {
            // 并发拉取汇总与明细
            async let summaryTask: ChargeSummary = APIClient.shared.get(
                APIRoutes.chargesSummary,
                query: ["months": "12"]
            )
            async let recordsTask: [ChargeRecord] = APIClient.shared.get(
                APIRoutes.chargesRecords,
                query: ["limit": "100"]
            )

            let (loadedSummary, loadedRecords) = try await (summaryTask, recordsTask)
            summary = loadedSummary
            records = loadedRecords
        } catch {
            // 真实地址不可达：回落模拟数据，保证页面不空白
            applyMock()
        }
    }

    /// 用本地模拟数据填充
    private func applyMock() {
        records = MockData.chargeRecords
        summary = MockData.chargeSummary
        errorMessage = nil
    }

    // MARK: - 导入账单

    func importBill(from url: URL) async {
        isLoading = true
        defer { isLoading = false }

        do {
            let result: ImportResult = try await APIClient.shared.uploadFile(
                APIRoutes.chargesImport,
                fileURL: url
            )

            if result.success {
                let duplicateNote = result.duplicates > 0
                    ? "，跳过 \(result.duplicates) 笔重复"
                    : ""
                showToast("已归集 \(result.imported) 笔充电消费\(duplicateNote)")
                await load()
            } else {
                showToast(result.message ?? "导入失败")
            }
        } catch let error as ApiError {
            showToast(error.errorDescription ?? "导入失败")
        } catch {
            showToast("导入失败：\(error.localizedDescription)")
        }
    }

    // MARK: - 清空

    func clear() async {
        do {
            let _: ClearResult = try await APIClient.shared.delete(APIRoutes.chargesRecords)
            records = []
            summary = nil
            showToast("已清空充电消费记录")
        } catch {
            showToast("清空失败：\(error.localizedDescription)")
        }
    }

    // MARK: - 提示

    func showToast(_ message: String) {
        toast = message
        Task {
            try? await Task.sleep(nanoseconds: 2_400_000_000)
            toast = nil
        }
    }
}

// MARK: - 接口响应模型

/// 账单导入结果
struct ImportResult: Codable {
    var success: Bool
    var message: String?
    var imported: Int
    var duplicates: Int
    var totalParsed: Int?
}

/// 清空结果
struct ClearResult: Codable {
    var cleared: Int
}
