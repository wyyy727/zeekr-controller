//
//  ControlsPanel.swift
//  ZeekrDash
//
//  快捷车控面板
//
//  结构对齐确认版预览页：三组共 15 个按钮
//  - 车控（状态开关型，6）：解锁/锁车、开/关空调、前除霜、方向盘加热、座椅加热、座椅通风
//  - 远程操作（瞬时动作型，6）：闪灯、鸣笛、关车窗、遮阳帘、开始/结束充电、哨兵模式
//  - 场景（3）：出行规划、寻车、立即刷新
//
//  动效链路（8 段，与确认版逐条对齐）：
//  ① 按压下沉 scale(0.93) + 图标下沉
//  ② 弹性回弹 .spring(response: 0.3, dampingFraction: 0.6)
//  ③ 下发中转圈 loading，期间锁定重复点击
//  ④ 成功：图标变青碧 + 弹跳 0.72→1.16→1 + 外圈青碧脉冲
//  ⑤ 成功：按钮轻弹 0.93 → 1.05 → 1
//  ⑥ 失败：图标变朱砂色 + 左右 5pt 抖动
//  ⑦ Toast 中文回执
//  ⑧ 尊重 accessibilityReduceMotion
//
//  颜色语言（与预览页 preview/index.html 严格对齐）：
//  四种状态 —— 关闭 / 开启 / 成功 / 失败 —— 的**按钮底色始终不变**，
//  一律是普通玻璃。状态只靠**图标着色**（+ 开启态文字加粗）传达，
//  不再有任何整块铺色。这是刻意为之：整块变色在 3 列密集网格里过重，
//  也会把玻璃质感盖掉。
//    · 关闭 → 墨色图标
//    · 开启 → 珊瑚色图标 + 辉光，文字加粗
//    · 成功 → 青碧色图标 + 弹跳 + 脉冲圈
//    · 失败 → 朱砂色图标 + 抖动
//
//  安全设计：车控需要在「设置」中显式开启总开关，关闭时按钮禁用并给出说明 —— 避免误触。
//

import SwiftUI

struct ControlsPanel: View {

    @Environment(AppStore.self) private var store
    @Environment(SettingsStore.self) private var settings
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 正在下发的按钮（用于转圈与锁定重复点击）
    @State private var pending: ControlAction?
    /// 刚成功的按钮（图标青碧 + 弹跳脉冲 + 轻弹）
    @State private var succeeded: ControlAction?
    /// 刚失败的按钮（朱砂 + 抖动）
    @State private var failed: ControlAction?
    /// 抖动位移
    @State private var shakeOffset: CGFloat = 0
    /// 成功轻弹的放大倍数
    @State private var bounceScale: CGFloat = 1

    /// 每行按钮数（与预览页 `.ctrl-grid` 的 `repeat(3, 1fr)` 一致）
    private static let columnsPerRow = 3

    private var isEnabled: Bool {
        settings.commandsEnabled && !store.isLoading
    }

    private var status: VehicleStatus? { store.vehicleStatus }

    /// 已锁
    private var isLocked: Bool { status?.isLocked == true }
    /// 空调开启
    private var climateOn: Bool { status?.climateOn == true }
    /// 充电中
    private var isCharging: Bool { status?.isCharging == true }
    /// 已插枪（未插枪时不能启动充电）
    private var isPlugged: Bool { status?.isPlugged == true || isCharging }

    // MARK: - 三组按钮定义

    /// 第一组：车控（状态开关型）
    private var vehicleControls: [ControlAction] {
        [
            ControlAction(
                command: isLocked ? .unlock : .lock,
                label: isLocked ? "解锁" : "锁车",
                sub: isLocked ? "当前已锁" : "当前未锁",
                icon: isLocked ? "lock.open" : "lock",
                kind: .toggle,
                isOn: isLocked
            ),
            ControlAction(
                command: climateOn ? .climateOff : .climateOn,
                label: climateOn ? "关空调" : "开空调",
                sub: climateOn ? "运行中" : "已关闭",
                icon: "snowflake",
                kind: .toggle,
                isOn: climateOn
            ),
            ControlAction(
                command: .defrost,
                label: "前除霜",
                sub: "风挡除雾",
                icon: "snowflake.circle",
                kind: .toggle
            ),
            ControlAction(
                command: .wheelHeat,
                label: "方向盘",
                sub: "加热",
                icon: "steeringwheel",
                kind: .toggle
            ),
            ControlAction(
                command: .seatHeat,
                label: "座椅加热",
                sub: "主 / 副驾",
                icon: "car.seat.forward.and.heat.waves",
                kind: .toggle
            ),
            ControlAction(
                command: .ventSeat,
                label: "座椅通风",
                sub: "主 / 副驾",
                icon: "wind",
                kind: .toggle
            ),
        ]
    }

    /// 第二组：远程操作（瞬时动作型）
    private var remoteActions: [ControlAction] {
        [
            ControlAction(
                command: .flash,
                label: "闪灯",
                sub: nil,
                icon: "headlight.high.beam",
                kind: .action
            ),
            ControlAction(
                command: .honk,
                label: "鸣笛",
                sub: nil,
                icon: "speaker.wave.2",
                kind: .action
            ),
            ControlAction(
                command: .closeWindows,
                label: "关车窗",
                sub: nil,
                icon: "car.window.left",
                kind: .action
            ),
            ControlAction(
                command: .sunshade,
                label: "遮阳帘",
                sub: nil,
                icon: "sun.max",
                kind: .action
            ),
            ControlAction(
                command: isCharging ? .chargeStop : .chargeStart,
                label: isCharging ? "结束充电" : "开始充电",
                sub: nil,
                icon: "bolt.badge.clock",
                kind: .action,
                // 未插枪时不能启动充电
                isDisabled: !isCharging && !isPlugged
            ),
            ControlAction(
                command: .sentinel,
                label: "哨兵模式",
                sub: nil,
                icon: "shield.lefthalf.filled",
                kind: .toggle
            ),
        ]
    }

    /// 第三组：场景
    private var sceneActions: [ControlAction] {
        [
            ControlAction(
                command: .tripPlan,
                label: "出行规划",
                sub: "预设出发时间",
                icon: "point.topleft.down.to.point.bottomright.curvepath",
                kind: .scene
            ),
            ControlAction(
                command: .carFinder,
                label: "寻车",
                sub: "定位车辆",
                icon: "location.circle",
                kind: .scene
            ),
            ControlAction(
                command: .refresh,
                label: "立即刷新",
                sub: "同步车况",
                icon: "arrow.clockwise",
                kind: .scene
            ),
        ]
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            grid(vehicleControls)

            groupSeparator("远程操作")
            grid(remoteActions)

            groupSeparator("场景")
            grid(sceneActions)

            if !settings.commandsEnabled {
                Text("在「设置」中开启控制指令开关后可用")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary(scheme))
                    .padding(.top, 12)
            }
        }
        .padding(Metrics.cardPadding)
        // 卡片保持实心：密集文字上盖玻璃可读性会崩，Apple HIG 明确反对
        .background(Theme.surface(scheme))
        .clipShape(RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous))
    }

    // MARK: - 头部

    private var header: some View {
        HStack {
            Text("快捷车控")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.textPrimary(scheme))

            Spacer()

            if !settings.commandsEnabled {
                Text("已禁用")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary(scheme))
            } else {
                Text(isLocked ? "车辆已上锁" : "车辆未上锁")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary(scheme))
            }
        }
        .padding(.bottom, 12)
    }

    /// 分组小标题 + 右侧延伸的分隔线（对应预览页的 .ctrl-sep）
    private func groupSeparator(_ title: String) -> some View {
        HStack(spacing: 9) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.textTertiary(scheme))
                .fixedSize()

            Rectangle()
                .fill(Theme.separator(scheme))
                .frame(height: 1)
        }
        .padding(.top, 16)
        .padding(.bottom, 10)
    }

    // MARK: - 按钮网格

    /// 固定三列网格（`Grid` + `GridRow`），不用 `LazyVGrid`。
    ///
    /// 惰性网格只实体化可见行，滚动时行回收/重建会触发布局重算，
    /// 表现为按钮随滚动轻微抖动。本面板恒为 15 个按钮且需常驻，
    /// 惰性布局零收益却牺牲稳定性，故用固定网格。行高/列宽/间距与
    /// 预览页 `.ctrl-grid` 的 `grid-template-columns: repeat(3, 1fr)` 一致。
    private func grid(_ actions: [ControlAction]) -> some View {
        let perRow = Self.columnsPerRow
        let rowCount = (actions.count + perRow - 1) / perRow

        return Grid(
            horizontalSpacing: Metrics.sectionSpacing,
            verticalSpacing: Metrics.sectionSpacing
        ) {
            ForEach(0..<rowCount, id: \.self) { row in
                GridRow {
                    ForEach(0..<perRow, id: \.self) { column in
                        let index = row * perRow + column
                        if index < actions.count {
                            button(for: actions[index])
                        } else {
                            // 末行不满时补占位，保证列宽与其余行对齐
                            Color.clear
                                .gridCellUnsizedAxes([.horizontal, .vertical])
                        }
                    }
                }
            }
        }
    }

    /// 单个车控按钮（动效链路 ①–⑧ 全部由 `ControlButton` 内部承载，此处只接线）
    private func button(for action: ControlAction) -> some View {
        ControlButton(
            action: action,
            isPending: pending == action,
            isSucceeded: succeeded == action,
            isFailed: failed == action,
            isEnabled: isEnabled && !action.isDisabled,
            shakeOffset: failed == action ? shakeOffset : 0,
            bounceScale: succeeded == action ? bounceScale : 1,
            reduceMotion: reduceMotion
        ) {
            Task { await trigger(action) }
        }
    }

    // MARK: - 下发逻辑

    @MainActor
    private func trigger(_ action: ControlAction) async {
        // ③ 下发中锁定重复点击
        guard pending == nil, succeeded == nil else { return }
        pending = action
        failed = nil

        let result = await store.send(command: action.command)
        pending = nil

        if result?.success == true {
            // ④+⑤ 成功：图标变青碧 + 弹跳脉冲 + 按钮轻弹，1 秒后复位
            playSuccess(on: action)
            showToast(result?.message ?? "\(action.label)已下发")
        } else {
            // ⑥ 失败：朱砂色 + 左右 5pt 抖动
            playFailure(on: action)
            showToast(result?.message ?? "\(action.label)失败")
        }
    }

    /// ④⑤ 成功链路
    @MainActor
    private func playSuccess(on action: ControlAction) {
        // ⑧ 减弱动效时只呈现静态对勾，不播动画
        guard !reduceMotion else {
            succeeded = action
            Task {
                try? await Task.sleep(nanoseconds: 950_000_000)
                succeeded = nil
            }
            return
        }

        succeeded = action
        bounceScale = 0.93

        withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {
            bounceScale = 1.05
        }

        Task {
            try? await Task.sleep(nanoseconds: 180_000_000)
            withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {
                bounceScale = 1
            }
            try? await Task.sleep(nanoseconds: 770_000_000)
            succeeded = nil
            bounceScale = 1
        }
    }

    /// ⑥ 失败链路
    @MainActor
    private func playFailure(on action: ControlAction) {
        failed = action

        // ⑧ 减弱动效时不抖动
        guard !reduceMotion else {
            Task {
                try? await Task.sleep(nanoseconds: 900_000_000)
                failed = nil
            }
            return
        }

        Task {
            // 0 → -5 → +5 → -3 → +3 → 0
            for step in [-5.0, 5.0, -3.0, 3.0, 0.0] {
                withAnimation(.easeInOut(duration: 0.08)) {
                    shakeOffset = step
                }
                try? await Task.sleep(nanoseconds: 80_000_000)
            }
            shakeOffset = 0
            try? await Task.sleep(nanoseconds: 400_000_000)
            failed = nil
        }
    }

    /// ⑦ Toast 中文回执（由 RootView 统一呈现在屏幕底部）
    @MainActor
    private func showToast(_ message: String) {
        store.showToast(message)
    }
}

// MARK: - 按钮模型

/// 车控按钮的三种形态
enum ControlKind {
    /// 开关型：对应 switch / lock 实体，显示目标动作，由车况驱动 on 状态
    case toggle
    /// 瞬时动作：对应 button 实体，点击后一次性反馈
    case action
    /// 场景型：组合指令，同样是一次性动作
    case scene
}

/// 一个车控按钮的完整描述
struct ControlAction: Identifiable, Equatable {

    /// 唯一标识：同一指令在不同分组下不会重复出现
    var id: String { command.rawValue }

    let command: VehicleCommand
    let label: String
    var sub: String?
    let icon: String
    let kind: ControlKind
    /// 开关型按钮当前是否处于开启态
    var isOn: Bool = false
    /// 按钮自身的禁用条件（如未插枪时不能开始充电）
    var isDisabled: Bool = false

    static func == (lhs: ControlAction, rhs: ControlAction) -> Bool {
        lhs.id == rhs.id
            && lhs.label == rhs.label
            && lhs.isOn == rhs.isOn
            && lhs.isDisabled == rhs.isDisabled
    }
}

// MARK: - 单个车控按钮

private struct ControlButton: View {

    let action: ControlAction
    let isPending: Bool
    let isSucceeded: Bool
    let isFailed: Bool
    let isEnabled: Bool
    /// 失败抖动位移
    let shakeOffset: CGFloat
    /// 成功轻弹缩放
    let bounceScale: CGFloat
    let reduceMotion: Bool
    let onTap: () -> Void

    @Environment(\.colorScheme) private var scheme
    /// 成功时图标弹跳的当前缩放（对应预览页 ctrlIcoPop 的 0.72 → 1.16 → 1）
    @State private var iconPopScale: CGFloat = 1
    /// 成功时外圈脉冲圈的缩放与透明度（对应 ctrlPulse）
    @State private var pulseScale: CGFloat = 0.55
    @State private var pulseOpacity: Double = 0

    private var minHeight: CGFloat {
        action.kind == .scene ? 74 : 82
    }

    private var iconSize: CGFloat {
        action.kind == .scene ? 20 : 22
    }

    // MARK: 图标着色（状态全靠这里传达）

    /// 图标色优先级：失败 > 成功 > 禁用 > 开启 > 常规。
    ///
    /// 失败排在成功之前 —— 与预览页的覆盖顺序一致（网页 catch 分支会同时
    /// 加 `done` 与 `fail` 两个类，靠 `.ctrl.done:not(.fail)` 让失败胜出）。
    /// iOS 侧两个状态目前由 `trigger` 保证互斥，但显式写死优先级，
    /// 不再依赖「另一个变量恰好为 nil」这种隐式前提。
    private var iconTint: Color {
        if isFailed { return failureColor }
        if isSucceeded { return successColor }
        if !isEnabled { return Theme.textTertiary(scheme) }
        if isOn { return Theme.coral(scheme) }
        return Theme.textPrimary(scheme)
    }

    /// 文字色始终为主文字色，不随状态变化（对齐预览页 `.ctrl { color: var(--text-1) }`）。
    /// 只有图标着色，文字保持稳定的可读性。
    private var titleColor: Color {
        isEnabled ? Theme.textPrimary(scheme) : Theme.textTertiary(scheme)
    }

    /// 开启态图标外加一层珊瑚辉光
    private var iconGlow: Color? {
        guard isEnabled, isOn, !isSucceeded, !isFailed else { return nil }
        return Theme.coral(scheme).opacity(0.45)
    }

    private var subColor: Color {
        isOn ? Theme.textSecondary(scheme) : Theme.textTertiary(scheme)
    }

    /// 开启态文字加粗，与图标的重量感对齐
    private var labelWeight: Font.Weight {
        isOn ? .semibold : .regular
    }

    /// 成功图标弹跳：0.72 → 1.16 → 1
    private func playIconPop() {
        // ⑧ 减弱动效时只呈现静态着色，不播动画
        guard !reduceMotion else {
            iconPopScale = 1
            pulseOpacity = 0
            return
        }

        iconPopScale = 0.72
        pulseScale = 0.55
        pulseOpacity = 0.7

        withAnimation(.spring(response: 0.5, dampingFraction: 0.6)) {
            iconPopScale = 1.16
            pulseScale = 1.05
            pulseOpacity = 0
        }

        Task {
            try? await Task.sleep(nanoseconds: 180_000_000)
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                iconPopScale = 1
            }
        }
    }

    var body: some View {
        Button {
            onTap()
        } label: {
            ZStack {
                ButtonContent(
                    action: action,
                    iconSize: iconSize,
                    foreground: iconTint,
                    titleColor: titleColor,
                    subColor: subColor,
                    labelWeight: labelWeight,
                    glowColor: iconGlow,
                    // 成功时图标弹一下（与 ctrlIcoPop 同曲线）
                    iconScale: isSucceeded ? iconPopScale : 1,
                    reduceMotion: reduceMotion
                )
                overlay
            }
            .frame(maxWidth: .infinity, minHeight: minHeight)
            // 玻璃按钮不铺底色，否则会盖住折射效果
            .background(usesGlass ? Color.clear : background)
            .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
            .glassSurface(isGlass: usesGlass, shape: RoundedRectangle(cornerRadius: 13, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        }
        // ① 按压下沉由 ButtonStyle 提供，比手势更可靠且不影响点击命中
        .buttonStyle(PressDownStyle(isEnabled: isEnabled && !isPending && !isSucceeded))
        .disabled(!isEnabled || isPending || isSucceeded)
        // ⑤ 成功轻弹
        .scaleEffect(bounceScale)
        .offset(x: shakeOffset)
        .animation(.easeInOut(duration: 0.18), value: isFailed)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(action.kind == .toggle && action.isOn ? [.isSelected] : [])
        // 成功：开启图标弹跳 + 外圈脉冲；每次成功都重新播放
        .onChange(of: isSucceeded) { _, succeeded in
            guard succeeded else { return }
            playIconPop()
        }
    }

    // MARK: 覆盖层（转圈 / 成功脉冲圈）

    /// 成功 / 失败不再铺遮罩 —— 颜色只落在图标上（对齐预览页：
    /// 删掉了 `.ctrl-ok` 整块遮罩，改为图标着色 + 弹跳 + 脉冲圈）。
    @ViewBuilder
    private var overlay: some View {
        if isPending {
            // ③ 下发转圈，遮罩同时锁定重复点击
            ZStack {
                Theme.surfaceAlt(scheme).opacity(0.78)

                ProgressView()
                    .controlSize(.small)
                    .tint(Theme.accent(scheme))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if isSucceeded && !reduceMotion {
            // ⑧ 成功后图标外圈扩散一圈青碧描边脉冲。
            // 对齐预览页 `.ctrl.done:not(.fail) .ico::after`：
            // 只用描边、不铺底，直径 40pt，从 0.55 扩到 1.05 并淡出。
            //
            // 纵向对齐：按钮内容 VStack 被 minHeight 居中，图标（含其
            // .frame(height: 24) 与上方 12pt padding）中心约在 26pt 处；
            // 圈顶到按钮顶 6pt 时圆心正好落在此处 —— 所以用 alignment: .top
            // 加一个刚好一半直径的偏移，不用额外的 padding 硬凑。
            Circle()
                .strokeBorder(successColor, lineWidth: 2)
                .frame(width: 40, height: 40)
                .scaleEffect(pulseScale)
                .opacity(pulseOpacity)
                .frame(maxHeight: .infinity, alignment: .top)
                .padding(.top, 6)
                .allowsHitTesting(false)
        }
    }

    // MARK: 配色

    /// 开关型且处于开启态
    private var isOn: Bool {
        action.kind == .toggle && action.isOn
    }

    /// 成功态图标色：青碧
    private var successColor: Color { ChineseColor.qingBi }

    /// 失败态图标色：朱砂（沿用现有告警色）
    private var failureColor: Color { ChineseColor.zhuSha }

    /// 按钮底色（仅在非玻璃时使用）
    private var background: Color {
        if !isEnabled {
            return Theme.surfaceAlt(scheme).opacity(0.5)
        }
        return Theme.surfaceAlt(scheme)
    }

    /// 车控按钮走液态玻璃（规格要求 `.regular.interactive()`）。
    /// 禁用态除外 —— 需明确呈现「不可用」，玻璃的通透反而会削弱这个信号。
    ///
    /// 注：开启态不再整块铺主色，因此也一并走玻璃（原来被排除在外）。
    private var usesGlass: Bool {
        isEnabled
    }

    private var accessibilityText: String {
        var text = action.label
        if action.kind == .toggle {
            text += action.isOn ? "，已开启" : "，已关闭"
        }
        if !isEnabled { text += "，不可用" }
        return text
    }
}

// MARK: - 按钮内容视图

/// 图标 + 文案部分
///
/// 单独拆出来是为了让 `@Environment(\.controlIconPressed)` 能读到
/// `PressDownStyle` 在 `configuration.label` 子树里注入的按压态。
private struct ButtonContent: View {

    let action: ControlAction
    let iconSize: CGFloat
    /// 图标色（成功 / 失败 / 开启 / 常规四态由父视图决定）
    let foreground: Color
    /// 按钮主文字色：不随状态变化，始终是主文字色
    let titleColor: Color
    let subColor: Color
    /// 开启态文字加粗
    let labelWeight: Font.Weight
    /// 开启态图标外发光色；nil 表示不加
    let glowColor: Color?
    /// 成功态图标弹跳缩放
    let iconScale: CGFloat
    let reduceMotion: Bool

    @Environment(\.controlIconPressed) private var iconPressed

    var body: some View {
        VStack(spacing: 7) {
            Image(systemName: action.icon)
                .font(.system(
                    size: iconSize,
                    weight: action.kind == .toggle && action.isOn ? .semibold : .regular
                ))
                .foregroundStyle(foreground)
                // 开启态外发光：线条显色面积小，靠辉光从玻璃底上「浮」起来
                .shadow(color: glowColor ?? .clear, radius: 3)
                .frame(height: 24)
                // ⑧ 成功弹跳
                .scaleEffect(iconScale)
                // ① 图标同步下沉
                .scaleEffect(iconPressed ? 0.86 : 1)
                .offset(y: iconPressed ? 1 : 0)
                // ② 弹性回弹
                .animation(
                    reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.6),
                    value: iconPressed
                )

            VStack(spacing: 1) {
                Text(action.label)
                    .font(.system(size: 12, weight: labelWeight))
                    .foregroundStyle(titleColor)
                    .lineLimit(1)

                if let sub = action.sub {
                    Text(sub)
                        .font(.system(size: 9.5))
                        .lineLimit(1)
                        .foregroundStyle(subColor)
                }
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 12)
    }
}

// MARK: - 按压下沉样式

/// ① 按压下沉 scale(0.93) + 图标下沉　② 弹性回弹
///
/// 用 ButtonStyle 而不是手势：按下即反馈、松开即回弹，
/// 且不会抢走 Button 的点击命中。
private struct PressDownStyle: ButtonStyle {

    let isEnabled: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed && isEnabled

        return configuration.label
            .scaleEffect(pressed ? 0.93 : 1)
            .offset(y: pressed ? 1 : 0)
            // 图标同步下沉：同一动画链路上再缩一档
            .environment(\.controlIconPressed, pressed)
            .animation(
                reduceMotion
                    ? nil
                    // ② 弹性回弹
                    : .spring(response: 0.3, dampingFraction: 0.6),
                value: pressed
            )
    }
}

// MARK: - 图标按压态传递

private struct ControlIconPressedKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// 车控按钮图标是否处于按压态（由 PressDownStyle 注入）
    var controlIconPressed: Bool {
        get { self[ControlIconPressedKey.self] }
        set { self[ControlIconPressedKey.self] = newValue }
    }
}

// MARK: - 条件玻璃

private extension View {
    /// 需要时套上液态玻璃，否则原样返回。
    ///
    /// `.glassEffect` 会叠加一层材质，无条件调用会让禁用态也带通透感，
    /// 因此用 `@ViewBuilder` 分支控制。
    @ViewBuilder
    func glassSurface(isGlass: Bool, shape: some Shape) -> some View {
        if isGlass {
            // 车控按钮需要触摸实时形变（规格 §4.3）
            self.glassEffect(.regular.interactive(), in: shape)
        } else {
            self
        }
    }
}
