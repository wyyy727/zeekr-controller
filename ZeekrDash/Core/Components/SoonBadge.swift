//
//  SoonBadge.swift
//  ZeekrDash
//
//  「即将上线」灰色小标签
//

import SwiftUI

struct SoonBadge: View {

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Text("即将上线")
            .font(.caption2)
            .foregroundStyle(Theme.textTertiary(scheme))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Theme.surfaceAlt(scheme), in: Capsule())
    }
}
