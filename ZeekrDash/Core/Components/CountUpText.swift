//
//  CountUpText.swift
//  ZeekrDash
//
//  数字入场：递增到目标值
//

import SwiftUI

/// 正在动画的数字本体（`Animatable`）。
///
/// 为什么不用 Text + `.contentTransition(.numericText())`：那只在**值变化**时做逐位滚动，
/// 不会从 0 一路数上去。这里的做法是让 `animatableData` 就是数值本身 —— SwiftUI 逐帧插值后
/// 重算 body，Text 每帧换一个字符串，于是得到「递增进位」而不是整段跳变。
struct CountUpText: View, Animatable {

    /// 当前（正在动画中的）数值
    var value: Double
    /// 数值 → 字符串。用闭包而不是固定格式：各处小数位、百分号、货币符号都不一样
    let format: (Double) -> String

    var animatableData: Double {
        get { value }
        set { value = newValue }
    }

    var body: some View {
        Text(format(value))
            .monospacedDigit()
    }
}

/// 带状态驱动的数字入场。直接当 Text 用（外面照常套 `.v2Text(...)` / `.v2Numeric()`）。
///
/// 行为：
/// - 首次出现：从 0 递增到目标值；
/// - 之后目标值变了（轮询刷新 / 切月份）：从当前值平滑走到新值，**不回 0** ——
///   否则车况页每 30 秒轮询一次，电量数字就闪一下 0；
/// - 系统开了「减弱动态效果」：直接显示目标值。
struct V2CountUp: View {

    let target: Double
    /// 递增时长（秒）；HTML 的柱状入场是 520ms，数字比它慢一点才看得清
    var duration: Double = 0.9
    /// 起点延后（秒），用于同一张卡里多格数字错开
    var delay: Double = 0.04
    /// 用目标值的宽度占位，避免数字从 1 位涨到 3 位时把右边的单位推着走
    var reserveWidth: Bool = false
    let format: (Double) -> String

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown: Double = 0
    @State private var started = false

    var body: some View {
        ZStack(alignment: .leading) {
            if reserveWidth {
                // 透明占位：这一格的宽度 = 最终值的宽度（hidden 仍然参与布局）
                Text(format(target))
                    .monospacedDigit()
                    .hidden()
            }
            CountUpText(value: shown, format: format)
                .animation(reduceMotion ? nil : .easeOut(duration: duration).delay(delay), value: shown)
                /* 起步前（那 40ms 的 0 值）先不画：否则读者会看见一个 0 一闪。
                   reduceMotion 时 run() 直接落到目标值，不需要藏。 */
                .opacity((started || reduceMotion) ? 1 : 0)
        }
        .task(id: target) { await run() }
    }

    private func run() async {
        guard target.isFinite else {
            shown = target
            started = true
            return
        }
        if reduceMotion {
            shown = target
            started = true
            return
        }
        if !started {
            /* 先落到 0，并等它真正渲染一帧再置目标值。
               只靠同一事务里的赋值，SwiftUI 会把「初始 0 → 目标值」合并成
               一次提交，递增整段被跳过 —— 柱子高度动画踩的就是这个坑
               （见 V2BarChart.startAnimation）。 */
            shown = 0
            try? await Task.sleep(nanoseconds: 40_000_000)
            guard !Task.isCancelled else { return }
        }
        started = true
        shown = target
    }
}
