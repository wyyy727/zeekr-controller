//
//  StatCard.swift
//  ZeekrDash
//
//  通用信息卡片
//

import SwiftUI

struct StatCard<Content: View>: View {

    @Environment(\.colorScheme) private var scheme

    let title: String
    /// 可选的 SF Symbols 图标
    var icon: String?
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textTertiary(scheme))
                }
                Text(title)
                    .font(.footnote)
                    .foregroundStyle(Theme.textSecondary(scheme))
            }

            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Metrics.cardPadding)
        .background(Theme.surface(scheme), in: .rect(cornerRadius: Metrics.cardRadius))
    }
}

/// 大数字 + 单位 的常用组合
struct StatValue: View {
    let value: String
    let unit: String
    var color: Color?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(value)
                .font(.title2.bold())
                .foregroundStyle(color ?? .primary)
                .monospacedDigit()
            Text(unit)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}
