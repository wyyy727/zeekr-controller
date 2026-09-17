//
//  LoadingView.swift
//  ZeekrDash
//
//  加载态
//

import SwiftUI

struct LoadingView: View {

    @Environment(\.colorScheme) private var scheme

    var text: String = "加载中…"

    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
                .tint(Theme.accent(scheme))
                .controlSize(.large)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary(scheme))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
