//
//  SOCRing.swift
//  ZeekrDash
//
//  电量环形进度 —— 用 Canvas 手绘，避免引入图表依赖
//

import SwiftUI

/// 电量环形进度指示器
///
/// 设计：极简的圆环 + 居中大字号电量数字。
/// 颜色随电量变化（充足/中等/不足），充电中显示为青色并带呼吸效果。
struct SOCRing: View {

    /// 电量百分比 0–100
    let soc: Double
    /// 是否充电中
    var isCharging: Bool = false
    /// 圆环直径
    var size: CGFloat = 160
    /// 线宽
    var lineWidth: CGFloat = 12

    @Environment(\.colorScheme) private var scheme
    @State private var breathe = false

    private var progress: Double {
        max(0, min(1, soc / 100))
    }

    private var ringColor: Color {
        isCharging ? ChineseColor.statusCharging : Theme.socColor(soc)
    }

    var body: some View {
        ZStack {
            // 底环
            Circle()
                .stroke(
                    Theme.separator(scheme),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )

            // 进度环
            Circle()
                .trim(from: 0, to: progress)
                .stroke(
                    ringColor,
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                // 进度变化时平滑过渡，而不是跳变
                .animation(.easeOut(duration: 0.6), value: progress)
                .opacity(isCharging && breathe ? 0.72 : 1.0)

            // 中心文字
            VStack(spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 1) {
                    Text(String(format: "%.0f", soc))
                        .font(.system(size: size * 0.28, weight: .medium, design: .rounded))
                        .foregroundStyle(Theme.textPrimary(scheme))
                        .monospacedDigit()
                    Text("%")
                        .font(.system(size: size * 0.11, weight: .regular, design: .rounded))
                        .foregroundStyle(Theme.textSecondary(scheme))
                }

                if isCharging {
                    Label("充电中", systemImage: "bolt.fill")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(ChineseColor.statusCharging)
                        .labelStyle(.titleAndIcon)
                }
            }
        }
        .frame(width: size, height: size)
        .onAppear {
            guard isCharging else { return }
            withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) {
                breathe = true
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("电量 \(Int(soc)) 百分比\(isCharging ? "，正在充电" : "")")
    }
}

#Preview("电量状态") {
    VStack(spacing: 32) {
        SOCRing(soc: 82, isCharging: false)
        HStack(spacing: 20) {
            SOCRing(soc: 14, isCharging: false, size: 90, lineWidth: 8)
            SOCRing(soc: 45, isCharging: true, size: 90, lineWidth: 8)
        }
    }
    .padding()
    .background(Theme.background(.light))
}
