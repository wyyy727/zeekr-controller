//
//  V2ControlGrid.swift
//  ZeekrDash
//
//  车控屏的按钮与栅格（v2）
//
//  真源：`preview/index-v2.html` 的 `renderControls()`（按钮定义与三态）与
//  样式块 2062–2098（`.v2-ctrl-grid` / `.v2-ctrl` / 三态动效）。
//

import SwiftUI

/// 一个车控按钮的规格。
struct V2ControlItem: Identifiable {
    enum Kind {
        /// 开关类：`aria-pressed` 跟随状态
        case toggle
        /// 动作类：点一下发一次
        case action
        /// 场景类：跳转/刷新
        case scene
    }

    /// **稳定语义 key**（`doorLock` / `climate` / `charge` …）。
    /// 不能拿 `cmd` 当 id：车锁的 cmd 会在 `lock`/`unlock` 之间翻转，
    /// 一旦翻转，`ForEach` 会把这个按钮当新视图重建、三态字典也读不到刚写的 `.done`。
    let id: String
    /// 本次要下发的指令（会随状态变，例如 `lock` ↔ `unlock`）
    let cmd: String
    let label: String
    let icon: String        // `Icons.xcassets` 里的名字
    let color: Color
    let kind: Kind
    /// 开关类当前是否开启（决定 `.on` 底色）
    var on: Bool = false
    /// 发送中 / 成功 / 失败
    var phase: Phase = .idle
    /// `.v2-ctrl--wide`：跨两格
    var wide: Bool = false
    /// 不可点（如没插枪时的「开始充电」）
    var disabled: Bool = false

    enum Phase {
        case idle
        case pending
        case done
        case fail
    }
}

/// 三列栅格（`.v2-ctrl-grid`：3 列、gap 11）
///
/// **为什么不用 LazyVGrid**：`.gridCellColumns()` 只对 `Grid` 容器生效，
/// LazyVGrid 根本没有列合并能力 —— 用它的话「寻车」那颗 `.v2-ctrl--wide`
/// 会静默退化成 1 格（不报错、编译通过，只是布局不对）。
/// 这里按 CSS grid 的自动放置规则自己分行，宽项占 2 格、本行放不下就换行。
struct V2ControlGrid: View {

    let items: [V2ControlItem]
    /// 指令总开关关闭时，全部按钮置为禁用（HTML 的 `!cmdsOn`）
    var enabled: Bool = true
    var onTap: (V2ControlItem) -> Void

    private let gap: CGFloat = 11
    private let cellHeight: CGFloat = 90

    /// CSS grid 自动放置：从左往右填 3 列，`span 2` 的项占两格，填不下就换行。
    /// 例：13 单格 + 1 双格 → 4 满行 + 最后一行「寻车(2) + 刷新(1)」。
    private var rows: [[V2ControlItem]] {
        var result: [[V2ControlItem]] = []
        var current: [V2ControlItem] = []
        var used = 0
        for item in items {
            let span = item.wide ? 2 : 1
            if used + span > 3 {
                if !current.isEmpty { result.append(current) }
                current = []
                used = 0
            }
            current.append(item)
            used += span
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    var body: some View {
        let laid = rows
        let count = laid.count
        // GeometryReader 不会自己撑高，总高度得显式算出来
        let totalHeight = CGFloat(count) * cellHeight + CGFloat(max(0, count - 1)) * gap

        return GeometryReader { proxy in
            let colWidth = max(0, (proxy.size.width - gap * 2) / 3)
            VStack(spacing: gap) {
                ForEach(Array(laid.enumerated()), id: \.offset) { _, row in
                    HStack(spacing: gap) {
                        ForEach(row) { item in
                            let span = item.wide ? 2 : 1
                            V2ControlButton(item: item, enabled: enabled) { onTap(item) }
                                .frame(width: colWidth * CGFloat(span) + gap * CGFloat(span - 1))
                        }
                        // 最后一行没填满时保持左对齐（CSS grid 也是左对齐，不会撑开）
                        Spacer(minLength: 0)
                    }
                    .frame(height: cellHeight)
                }
            }
        }
        .frame(height: totalHeight)
    }
}

/// 一颗车控按钮（`.v2-ctrl`：112×90 / r16 / 图标 28 / 文字 12-500）
struct V2ControlButton: View {

    let item: V2ControlItem
    var enabled: Bool
    var onTap: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var blocked: Bool { !enabled || item.disabled }

    var body: some View {
        Button(action: {
            guard !blocked else { return }
            onTap()
        }) {
            VStack(spacing: 8) {
                ZStack {
                    // 进行中：20×20 紫圈转圈，同时把图标隐掉（HTML `.busy .v2-ci{opacity:0}`）
                    if item.phase == .pending {
                        ProgressView()
                            .controlSize(.small)
                            .tint(V2Color.accent)
                    } else if item.phase == .done {
                        // 成功：绿勾（`check` 图标，20×20）
                        Image("ic-check")
                            .renderingMode(.template)
                            .resizable()
                            .frame(width: 20, height: 20)
                            .foregroundStyle(V2Color.good)
                    } else {
                        Image(item.icon)
                            .renderingMode(.template)
                            .resizable()
                            .frame(width: 28, height: 28)
                            .foregroundStyle(iconColor)
                            // `.v2-ctrl[disabled] .v2-ci{opacity:.55}` ——
                            // 总开关关闭 / 未插枪都算 disabled，两者都该淡下去
                            .opacity(blocked ? 0.55 : 1)
                    }
                }
                .frame(width: 28, height: 28)

                Text(item.label)
                    .v2Text(.label12, color: textColor)
                    .lineLimit(1)
                    .fixedSize()
            }
            .frame(maxWidth: .infinity)
            .frame(height: 90)
            .padding(.horizontal, 8)
            .background(background)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(borderOverlay)
        }
        /* 按压缩放交给 ButtonStyle：它拿到的 `isPressed` 会被系统在**开始滚动时自动复位**。
           之前用 `simultaneousGesture(DragGesture(minimumDistance: 0))` 模拟 —
           在 ScrollView 里滚动时手指经过的按钮会一直保持缩小，直到抬手才恢复。 */
        .buttonStyle(ControlPressStyle(reduceMotion: reduceMotion))
        .disabled(blocked)
        .accessibilityLabel(item.label)
        .accessibilityAddTraits(item.kind == .toggle && item.on ? [.isSelected] : [])
    }

    /// 图标色：失败态整颗变红；车辆不支持的能力统一灰 `#A8AFBE`
    private var iconColor: Color {
        if item.phase == .fail { return V2Color.bad }
        if item.disabled { return Color(hex: 0xA8AFBE) }
        return item.color
    }

    private var textColor: Color {
        item.disabled ? Color(hex: 0xA8AFBE) : V2Color.text1
    }

    /// `.v2-ctrl` 白 .50 / `.on` 紫 .10 / `.off` 白 .32
    private var background: Color {
        if item.disabled { return Color.white.opacity(0.32) }
        return item.on ? V2Color.accent.opacity(0.10) : Color.white.opacity(0.50)
    }

    /// 三态外框：done 1.5px 绿 / fail 1.5px 红；其余是白 .90 内描边 + 白高光
    @ViewBuilder
    private var borderOverlay: some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        if item.phase == .done {
            shape.strokeBorder(V2Color.good, lineWidth: 1.5)
        } else if item.phase == .fail {
            shape.strokeBorder(V2Color.bad, lineWidth: 1.5)
        } else {
            shape
                .strokeBorder(Color.white.opacity(item.disabled ? 0.50 : 0.90), lineWidth: 1)
                .overlay(
                    shape.stroke(Color.white.opacity(0.70), lineWidth: 2)
                        .offset(y: 1)
                        .clipShape(shape)
                )
        }
    }
}

/// 车控按钮按下反馈：`scale .97`（`.v2-ctrl:active{transform:scale(.97)}`）。
///
/// 用 `ButtonStyle` 而不是手势：`configuration.isPressed` 由系统维护，
/// 滚动开始时会被自动复位，不会出现「滚过去了按钮还缩着」。
/// 减弱动效开启时直接不缩放（只保留按压即响应的语义）。
private struct ControlPressStyle: ButtonStyle {

    let reduceMotion: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .animation(
                reduceMotion ? nil : .easeOut(duration: 0.12),
                value: configuration.isPressed
            )
    }
}

/// 车辆不支持的能力：**画出来**（灰按钮），不是藏掉 —— 藏掉会让人以为 App 没做。
struct V2UnsupportedRow: View {

    /// (名称, 图标)：HTML 那 5 项
    static let defaults: [(String, String)] = [
        ("天窗", "ctrl-sunroof"),
        ("后备箱", "ctrl-trunk"),
        ("前备箱", "ctrl-frunk"),
        ("驾驶模式", "ctrl-drive-mode"),
        ("离家", "ctrl-home"),
    ]

    var items: [(String, String)] = V2UnsupportedRow.defaults

    private let columns = Array(
        repeating: GridItem(.flexible(), spacing: 8),
        count: 5
    )

    var body: some View {
        LazyVGrid(columns: columns, spacing: 8) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                VStack(spacing: 8) {
                    Image(item.1)
                        .renderingMode(.template)
                        .resizable()
                        .frame(width: 28, height: 28)
                        .foregroundStyle(Color(hex: 0xA8AFBE))
                        .opacity(0.55)
                    Text(item.0)
                        .v2Text(.label12, color: Color(hex: 0xA8AFBE))
                        .lineLimit(1)
                        .fixedSize()
                }
                .frame(maxWidth: .infinity)
                .frame(height: 90)
                .background(Color.white.opacity(0.32))
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.50), lineWidth: 1)
                )
            }
        }
    }
}
