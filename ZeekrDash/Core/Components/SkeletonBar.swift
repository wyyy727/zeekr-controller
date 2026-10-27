//
//  SkeletonBar.swift
//  ZeekrDash
//
//  加载骨架条（行程 / 充电等屏共用）
//

import SwiftUI

/// 一条呼吸的骨架条。
///
/// 出处 `index-v2.html` 的 `.v2-skel i` / `@keyframes v2skel`：
/// 高 14、圆角 7、`rgba(255,255,255,.55)`，1.6 秒一个来回，透明度 .55 ↔ .9。
struct SkeletonBar: View {

    let width: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dim = false

    var body: some View {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(V2Color.skeletonFill)
            .frame(width: width, height: 14)
            .opacity(reduceMotion ? 0.7 : (dim ? 0.9 : 0.55))
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                    dim = true
                }
            }
    }
}
