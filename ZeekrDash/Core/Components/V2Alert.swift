//
//  V2Alert.swift
//  ZeekrDash
//
//  HTML `.v2-alert`（index-v2.html 2115–2125 / 5912–5937）的原生复刻。
//
//  为什么不直接用系统 `.alert`：HTML 把它的规格写死了 ——
//  卡片 300 宽 / 白 94% / r20 / 标题 16-600 / 说明 12.5-400 / 两个按钮**并排** 40 高 r12。
//  系统 alert 是竖排按钮 + 系统蓝字 + 固定宽度，改文案也补不回这套规格。
//

import SwiftUI

/// 一次确认弹框的内容与动作。
///
/// 只做样式，不持有业务状态 —— 「谁来弹、弹完干什么」由调用方的 item 绑定决定。
struct V2AlertCard: View {

    let title: String
    let message: String
    var cancelTitle: String = "取消"
    let confirmTitle: String
    let onCancel: () -> Void
    let onConfirm: () -> Void

    /// `.v2-alert { border-radius: 20px }`
    private let radius: CGFloat = 20
    private let buttonHeight: CGFloat = 40
    private let buttonRadius: CGFloat = 12

    var body: some View {
        ZStack {
            mask
            card
        }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
    }

    // MARK: - 遮罩

    /// `.v2-alert-mask`：`rgba(15,23,41,.38)` + `blur(6px)`，点空白处取消。
    ///
    /// **不做那 6px 模糊**：弹框是用 `fullScreenCover` 呈现的，被盖住的页面可能已经
    /// 从图层树里撤掉，材质采样不到内容会变成一块死灰。38% 压暗本身已经足够，
    /// 与 `V2BottomSheet` 的遮罩用法保持一致。
    private var mask: some View {
        Rectangle()
            .fill(Color(hex: 0x0F1729).opacity(0.38))
            .ignoresSafeArea()
            .contentShape(Rectangle())
            .onTapGesture(perform: onCancel)
            .accessibilityHidden(true)
    }

    // MARK: - 卡片

    private var card: some View {
        VStack(spacing: 0) {
            Text(title)
                .v2Text(.alertTitle16)
                .multilineTextAlignment(.center)

            Text(message)
                .v2Text(.alertMsg, color: V2Color.text2)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                // `.v2-alert .m { margin-top: 8px }`
                .padding(.top, 8)

            HStack(spacing: 8) {
                Button(action: onCancel) {
                    Text(cancelTitle)
                        .v2Text(.alertBtn, color: V2Color.text1)
                        .frame(maxWidth: .infinity)
                        .frame(height: buttonHeight)
                        // `.v2-btn.ghost`：白 .50 底 + 内描边白 .90（inset box-shadow）
                        .background(Color.white.opacity(0.50))
                        .clipShape(RoundedRectangle(cornerRadius: buttonRadius, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: buttonRadius, style: .continuous)
                                .strokeBorder(Color.white.opacity(0.90), lineWidth: 1)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Button(action: onConfirm) {
                    Text(confirmTitle)
                        .v2Text(.alertBtn, color: .white)
                        .frame(maxWidth: .infinity)
                        .frame(height: buttonHeight)
                        // `.v2-btn.primary`：accent 实底
                        .background(V2Color.accent)
                        .clipShape(RoundedRectangle(cornerRadius: buttonRadius, style: .continuous))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            // `.v2-alert .acts { margin-top: 16px }`
            .padding(.top, 16)
        }
        // `.v2-alert { padding: 20px 18px 14px }` —— 上 20 右左 18 下 14
        .padding(.top, 20)
        .padding(.horizontal, 18)
        .padding(.bottom, 14)
        // `.v2-alert { width: min(300px, calc(100vw - 48px)) }`：
        // 先限宽 300，再留两侧 24 —— 窄屏上 padding 会把可用宽度压到 300 以下，
        // 文字自行换行，不会像写死 300 那样溢出。
        .frame(maxWidth: 300)
        .padding(.horizontal, 24)
        // `.v2-alert { background: rgba(255,255,255,.94) }`
        .background(Color.white.opacity(0.94))
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(Color.white.opacity(0.95), lineWidth: 1)
        )
        // `box-shadow: 0 12px 40px rgba(74,87,120,.30)` —— CSS blur 40 ≈ SwiftUI radius 20
        .shadow(color: Color(hex: 0x4A5778).opacity(0.30), radius: 20, y: 12)
    }
}

// MARK: - 挂在任意视图上的确认框

private struct V2AlertModifier<Item>: ViewModifier {

    @Binding var item: Item?
    /// 这一个宿主当前是否负责呈现。
    ///
    /// 同一份状态可能被挂在两处（页面里 + 全屏面板里），但 `fullScreenCover`
    /// 只能有一个宿主去 present —— 两个同时触发会撞车。用这个开关保证同一时刻只有一处生效。
    var isEnabled: Bool = true
    let title: (Item) -> String
    let message: (Item) -> String
    let cancelTitle: String
    let confirmTitle: String
    let onConfirm: (Item) -> Void

    /// **为什么用 `fullScreenCover` 而不是 `.overlay`**：
    /// 这个弹框的触发点在「附近充电站」卡片里，而卡片位于 `ScreenContainer` 的 ScrollView 内 ——
    /// `.overlay` 的布局尺寸等于卡片本身（还受 ScrollView 裁剪），遮罩只能盖住那张卡，
    /// 盖不住整屏。`fullScreenCover` 拿到的是窗口级图层，尺寸与屏幕一致，
    /// 与 `V2BottomSheet` 用的是同一套（`.presentationBackground(.clear)` + 自绘遮罩）。
    ///
    /// 已知差异：cover 有系统自带的上滑过场，HTML 的 alert 是原地出现。
    /// 遮罩与卡片会跟着一起上滑，观感偏「像个面板」。要完全一致需改成窗口级 overlay。
    private var presented: Binding<Bool> {
        Binding(
            get: { isEnabled && item != nil },
            set: { if !$0 { item = nil } }
        )
    }

    func body(content: Content) -> some View {
        content
            .fullScreenCover(isPresented: presented) {
                /* `presentationBackground` 挂在**稳定的根**上，不是挂在卡片上 ——
                   取消时 `item` 先变 nil、卡片瞬间消失，若背景也挂在那层，
                   退场动画会闪一下系统白底。 */
                ZStack {
                    if let value = item {
                        V2AlertCard(
                            title: title(value),
                            message: message(value),
                            cancelTitle: cancelTitle,
                            confirmTitle: confirmTitle,
                            onCancel: { item = nil },
                            onConfirm: {
                                item = nil
                                onConfirm(value)
                            }
                        )
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .presentationBackground(.clear)
            }
    }
}

extension View {
    /// 确认弹框（HTML `.v2-alert`）。`item` 非空即弹出，点取消或遮罩置空。
    ///
    /// 注意：它挂在**当前视图**上，不会自动盖住之后弹出的 modal。
    /// 若触发点既可能在页面里、又可能在 sheet 里，两处都要挂（见 `NearbyStationsView`）。
    /// - Parameter isEnabled: 同一份状态挂多处时，只有一处传 `true`，避免两个 cover 撞车。
    func v2Alert<Item>(
        item: Binding<Item?>,
        isEnabled: Bool = true,
        title: @escaping (Item) -> String,
        message: @escaping (Item) -> String,
        cancelTitle: String = "取消",
        confirmTitle: String,
        onConfirm: @escaping (Item) -> Void
    ) -> some View {
        modifier(
            V2AlertModifier(
                item: item,
                isEnabled: isEnabled,
                title: title,
                message: message,
                cancelTitle: cancelTitle,
                confirmTitle: confirmTitle,
                onConfirm: onConfirm
            )
        )
    }
}
