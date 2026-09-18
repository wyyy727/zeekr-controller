//
//  ToastBubble.swift
//  ZeekrDash
//
//  底部提示条
//

import SwiftUI

/// 底部提示条：毛玻璃半透明胶囊 + 深色文字，对应预览页的 `.toast`
///
/// 由 `RootView` 统一呈现车控指令回执，`ChargesView` 用于导入/清空结果。
///
/// 底色沿用页面既有的液态玻璃语言（与顶部数据来源徽标、底部 tab bar 同款），
/// 而非黑底实心 —— 黑底在浅色界面上过于突兀，且与整页的玻璃质感割裂。
struct ToastBubble: View {

    let text: String

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Text(text)
            .font(.system(size: 12.5, weight: .medium))
            // 浅色模式墨色、深色模式浅色，随配色方案自动切换
            .foregroundStyle(Theme.textPrimary(scheme))
            .multilineTextAlignment(.center)
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            // 毛玻璃半透明底：与卡片/徽标/tab bar 同一套材质
            .glassEffect(.regular, in: .capsule)
            // 保留柔和投影，让它从滚动内容上「浮」起来
            .shadow(
                color: ChineseColor.moSe.opacity(scheme == .dark ? 0.35 : 0.12),
                radius: 10,
                y: 3
            )
            .fixedSize(horizontal: false, vertical: true)
    }
}

#Preview {
    VStack(spacing: 16) {
        ToastBubble(text: "车辆已上锁")
        ToastBubble(text: "连接服务端失败，已切换为模拟数据")
    }
    .padding()
    .background(Theme.background(.light))
}
