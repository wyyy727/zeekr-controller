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

    /// 电量百分比 0–100；**nil 表示没读到**，显示 `--` 而不是 0%
    /// （0% 是「电量耗尽」的正常读数，把「没读到」画成 0 会让人以为车趴窝了）
    let soc: Double?
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
        max(0, min(1, (soc ?? 0) / 100))
    }

    /// 主色：v2 是**固定三色渐变，不随电量分档**。
    ///
    /// 出处 `index-v2.html` 4320–4324：`v2Ring()` 里没有任何按 SOC 取色的分支。
    /// 渐变 `#7CE8B5` → `#7EDCEE` → `#B9A5FF`，方向左下 → 右上
    /// （`x1,y1 = 0,1` → `x2,y2 = 1,0`）。
    /// 旧的三档阈值色（低电量转朱砂）是 v1 的东西，v2 没有。
    private var ringGradient: LinearGradient {
        LinearGradient(
            colors: [
                Color(hex: 0x7CE8B5),
                Color(hex: 0x7EDCEE),
                Color(hex: 0xB9A5FF),
            ],
            startPoint: .bottomLeading,
            endPoint: .topTrailing
        )
    }

    /// 轨道色：v2 是 rgba(27,34,51,.05)，不是旧的分割线色。
    private var trackColor: Color {
        Color(hex: 0x1B2233).opacity(0.05)
    }

    /// 低电量档（<30%）—— 充电中不触发；没读到就不算低
    private var isLow: Bool {
        guard let soc, !isCharging else { return false }
        return soc < 30
    }

    /// 中电量档（30~50%）—— 充电中不触发
    private var isMid: Bool {
        guard let soc, !isCharging else { return false }
        return soc >= 30 && soc < 50
    }

    var body: some View {
        ZStack {
            // 底环
            Circle()
                .stroke(
                    trackColor,
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )

            // 进度环
            Circle()
                .trim(from: 0, to: progress)
                .stroke(
                    ringGradient,
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

            /* 中心文字：v2 是**一整段**「68%」，26/700/31/−0.4（`.v2-ring-txt b`，1745 行）——
               百分号与数字同字号同字重，不是小的上标。字号按环径等比缩放：
               v2 的基准是环 100 → 字 26，所以系数是 size/100。 */
            VStack(spacing: 2) {
                // 数字递增入场（0 → 实际电量）；没读到时仍是 --，不走动画
                if let soc {
                    V2CountUp(target: soc.rounded()) { String(format: "%.0f%%", $0) }
                        .v2Text(.hero26.scaled(size / 100), color: V2Color.text1)
                } else {
                    Text("--")
                        .v2Text(.hero26.scaled(size / 100), color: V2Color.text1)
                        .v2Numeric()
                }

                if isCharging {
                    Text("充电中")
                        .v2Text(.label11.scaled(size / 100), color: V2Color.info)
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
                    .v2Text(.alert10, color: .white)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 2)
                    .background(V2Color.bad, in: RoundedRectangle(cornerRadius: 10))
                    .shadow(color: V2Color.bad.opacity(0.6), radius: 4, y: 2)
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
            soc.map { "电量 \(Int($0.rounded())) 百分比\(isCharging ? "，正在充电" : (isLow ? "，电量偏低" : ""))" }
                ?? "电量未读到"
        )
    }

    // MARK: - 光晕

    private var glowColor: Color {
        if isLow { return V2Color.bad.opacity(0.55) }
        if isMid { return V2Color.warn.opacity(0.42) }
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
    .background(V2Background())
}
