//
//  ErrorBanner.swift
//  ZeekrDash
//
//  错误提示条（可点击重试）
//

import SwiftUI

struct ErrorBanner: View {

    @Environment(\.colorScheme) private var scheme

    let message: String
    var onRetry: (() -> Void)?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(ChineseColor.zhuSha)

            Text(message)
                .font(.footnote)
                .foregroundStyle(Theme.textPrimary(scheme))
                .frame(maxWidth: .infinity, alignment: .leading)

            if let onRetry {
                Button("重试", action: onRetry)
                    .font(.footnote.bold())
                    .foregroundStyle(Theme.accent(scheme))
                    .frame(minHeight: Metrics.minTouchTarget)
            }
        }
        .padding(.horizontal, Metrics.cardPadding)
        .padding(.vertical, 8)
        .background(ChineseColor.feiSe.opacity(scheme == .dark ? 0.25 : 0.35),
                    in: .rect(cornerRadius: 12))
    }
}
