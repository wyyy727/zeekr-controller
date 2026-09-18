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
/// 颜色随电量变化（充足/中等/不足），充电中显示为靛青并带呼吸效果。
///
/// 三档视觉：
/// - `≥50%` 青碧：纯净，无特效
/// - `30~50%` 藤黄：环体柔和外发光
/// - `<30%` 朱砂：环体呼吸脉冲 + 强外发光 + 数字脉冲 + 「电量偏低」胶囊标签
///
/// 充电中（`isCharging == true`）主色为靛青，不触发上述三档警示。
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 充电呼吸（沿用原有逻辑，独立于低电量脉冲）
    @State private var breathe = false
    /// 低电量呼吸脉冲
    @State private var lowPulse = false
    /// 「电量偏低」标签入场
    @State private var alertShown = false

    private var progress: Double {
        max(0, min(1, soc / 100))
    }

    /// 主色：充电中固定靛青，否则按三档阈值取色
    private var ringColor: Color {
        isCharging ? ChineseColor.dianQing : Theme.socColor(soc)
    }

    /// 低电量档（<30%）—— 充电中不触发
    private var isLow: Bool {
        !isCharging && soc < 30
    }

    /// 中电量档（30~50%）—— 充电中不触发
    private var isMid: Bool {
        !isCharging && soc >= 30 && soc < 50
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
                // 充电呼吸（原有逻辑）
                .opacity(isCharging && breathe ? 0.72 : 1.0)
                // 低电量：环体呼吸脉冲（透明度 1.0→0.55）
                .opacity(isLow && lowPulse ? 0.55 : 1.0)
                // 低电量：缩放脉冲 1.0→1.035
                .scaleEffect(isLow && lowPulse ? 1.035 : 1.0)
                // 外发光：中档柔和 / 低档强化
                .shadow(color: glowColor, radius: glowRadius)

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
                        .foregroundStyle(ChineseColor.dianQing)
                        .labelStyle(.titleAndIcon)
                }
            }
            // 低电量：中心数字同步脉冲（透明度 1.0→0.68）
            .opacity(isLow && lowPulse ? 0.68 : 1.0)
        }
        .frame(width: size, height: size)
        // 「电量偏低」胶囊标签，贴在环下方
        .overlay(alignment: .bottom) {
            if isLow {
                Text("电量偏低")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 2)
                    .background(ChineseColor.zhuSha, in: RoundedRectangle(cornerRadius: 10))
                    .shadow(color: ChineseColor.zhuSha.opacity(0.6), radius: 4, y: 2)
                    .fixedSize()
                    .offset(y: 7)
                    .scaleEffect(alertShown ? 1 : 0.8)
                    .opacity(alertShown ? 1 : 0)
            }
        }
        .onAppear(perform: startAnimations)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            // 与屏幕上的 `%.0f` 保持一致：都用四舍五入。
            // 此前读屏用的是 Int(soc)（向零截断），soc=82.6 时屏幕显示 83、
            // 读屏却念「82」—— 视障用户拿到的是错的数值。
            "电量 \(Int(soc.rounded())) 百分比\(isCharging ? "，正在充电" : (isLow ? "，电量偏低" : ""))"
        )
    }

    // MARK: - 光晕

    private var glowColor: Color {
        if isLow { return ChineseColor.zhuSha.opacity(0.55) }
        if isMid { return ChineseColor.tengHuang.opacity(0.42) }
        return .clear
    }

    private var glowRadius: CGFloat {
        if isLow { return 7 }
        if isMid { return 5 }
        return 0
    }

    // MARK: - 动画启动

    private func startAnimations() {
        // 充电呼吸（原有逻辑，缩放脉冲下不叠加）
        if isCharging {
            withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) {
                breathe = true
            }
        }

        guard isLow else { return }

        // 尊重减弱动态效果：静态呈现警示（颜色 + 光晕 + 标签），不做脉冲
        guard !reduceMotion else {
            alertShown = true
            return
        }

        withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) {
            lowPulse = true
        }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.6)) {
            alertShown = true
        }
    }
}

#Preview("电量状态") {
    VStack(spacing: 32) {
        SOCRing(soc: 82, isCharging: false)
        HStack(spacing: 20) {
            SOCRing(soc: 22, isCharging: false, size: 90, lineWidth: 8)
            SOCRing(soc: 40, isCharging: false, size: 90, lineWidth: 8)
            SOCRing(soc: 45, isCharging: true, size: 90, lineWidth: 8)
        }
    }
    .padding()
    .background(Theme.background(.light))
}
