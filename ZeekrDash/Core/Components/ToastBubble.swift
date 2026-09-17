//
//  ToastBubble.swift
//  ZeekrDash
//
//  底部提示条
//

import SwiftUI

/// 底部提示条：黑底白字胶囊，对应确认版预览页的 `.toast`
///
/// 由 `RootView` 统一呈现车控指令回执，`ChargesView` 用于导入/清空结果。
struct ToastBubble: View {

    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(ChineseColor.xiangYaBai)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background(ChineseColor.moSe.opacity(0.95), in: Capsule())
            .shadow(color: ChineseColor.moSe.opacity(0.22), radius: 8, y: 3)
            .fixedSize(horizontal: false, vertical: true)
    }
}

#Preview {
    ToastBubble(text: "车辆已上锁")
        .padding()
        .background(Theme.background(.light))
}
