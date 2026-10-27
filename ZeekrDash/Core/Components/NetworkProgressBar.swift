//
//  NetworkProgressBar.swift
//  ZeekrDash
//
//  顶部 2pt 全局请求进度条。
//
//  为什么是"扫光"而不是真实进度：请求没有进度回调，硬编成 0→90% 的假进度
//  反而会让人以为它快好了。扫光只表达"在跑"，不承诺什么时候结束。
//
//  无障碍：开了「减弱动态效果」就不扫 —— 持续移动的光带对前庭敏感人群不友好。
//  此时退化成一条静态的 40% 淡色条，依旧能说明"有请求在飞"。
//

import SwiftUI

struct NetworkProgressBar: View {

    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var sweeping = false

    /// 与网页 `#netBar` 一致：2pt 高、光带占 40% 宽度、1.1s 一轮
    private static let height: CGFloat = 2
    private static let bandFraction: CGFloat = 0.4
    private static let duration: Double = 1.1

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let band = width * Self.bandFraction

            LinearGradient(
                colors: [
                    V2Color.accent.opacity(0),
                    V2Color.accent,
                    V2Color.accent.opacity(0),
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: band, height: Self.height)
            // 起点在左外侧（-band）、终点在右外侧（width），保证首尾都能滑出去
            .offset(x: reduceMotion ? 0 : (sweeping ? width : -band))
            .frame(width: width, height: Self.height, alignment: .leading)
        }
        .frame(height: Self.height)
        .clipped()
        .opacity(reduceMotion ? 0.55 : 1)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.linear(duration: Self.duration).repeatForever(autoreverses: false)) {
                sweeping = true
            }
        }
        .accessibilityHidden(true)   // 纯装饰：状态本身不该靠一条光带来播报
    }
}
