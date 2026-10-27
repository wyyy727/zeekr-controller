//
//  V2BottomSheet.swift
//  ZeekrDash
//
//  v2 底部面板（自绘）：遮罩 + 圆角面板 + 把手 + 标题行
//
//  为什么不用系统 `.sheet`：v2 的面板是「半透明遮罩 + 圆角 + 顶部把手 + 固定高度」，
//  系统 sheet 是另一套观感，且高度会跟着内容走 —— 筛选条件一变高矮就跳。
//  这里用 `.fullScreenCover` + `.presentationBackground(.clear)` 拿到顶层图层，
//  面板与遮罩全部自己画。
//
//  两套高度模式（HTML 里本来就是两种面板）：
//  · `hugContent == false`（默认）：高度按屏高比例锁死，见 `heightRatio` —— 附近充电站用这个；
//  · `hugContent == true`：高度随内容，正文区封顶内滚 —— OCR 核对框用这个
//    （HTML `.ocr-body` 是 `max-height: min(58vh, 430px)`，面板本身 hug）。
//    ⚠️ 这个模式下 `content()` **不要再自带 ScrollView**，由面板提供并封顶。
//

import SwiftUI

struct V2BottomSheet<Content: View>: View {

    let title: String
    /// 标题右侧的次要信息（如「12 站」「已识别 2 张 · 21:34」）
    var subtitle: String?
    /// 标题字号。默认 14（`.v2-sh .t` 是 17、`.ocr-title` 是 16，按面板传）
    var titleType: V2Type = .title14
    /// 右上的次要按钮（收起 / 取消）；**传 nil 就不显示**（HTML 的 OCR 面板没有右上按钮）
    var closeTitle: String? = "关闭"
    /// 右侧的主操作（如「保存 N 笔」），放在 `closeTitle` 右边
    var trailingTitle: String?
    var trailingEnabled: Bool = true
    var onTrailing: (() -> Void)?
    /// 点遮罩或点 `closeTitle` 都走它
    var onClose: () -> Void
    /// `hugContent == false` 时：面板高度占屏高的比例（固定，不随内容变）
    var heightRatio: CGFloat = 0.78
    /// true = 高度随内容、正文区封顶内滚（HTML `.ocr-body` 的做法）
    var hugContent: Bool = false
    /// hug 模式下正文区最多占屏高的比例（HTML `58vh`）
    var bodyMaxHeightRatio: CGFloat = 0.58
    /// hug 模式下正文区的绝对上限（HTML `430px`）
    var bodyMaxHeight: CGFloat = 430
    /// 顶部把手。`.v2-sheet` 有把手，`.sheet`（OCR 面板）没有
    var showsGrip: Bool = true
    /// 标题行左右内距。`.v2-sheet` 内距 16，`.sheet` 只有 10 + `.ocr-head` 的 2 = 12
    var headerInset: CGFloat = 16
    var cornerRadius: CGFloat = 24
    var panelBackground: Color = V2Color.bgTop
    var maskColor: Color = Color(hex: 0x1B2233).opacity(0.28)
    /// 固定在面板底部、不随正文滚动的一行（HTML `.ocr-actions`）
    var footer: AnyView? = nil

    @ViewBuilder let content: () -> Content

    /// 下滑关闭的跟随位移
    @State private var dragOffset: CGFloat = 0
    /// hug 模式下量到的正文高度
    @State private var measuredBody: CGFloat = 0

    /// 键盘遮住屏幕底边的高度（收起时 0）。
    /// 在 body 里读它 → 随 `KeyboardHeight` 的 `@Observable` 自动重绘。
    private var keyboardInset: CGFloat { KeyboardHeight.shared.value }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .bottom) {
                // `.v2-mask` / `.sheet-root`：压暗背景，点一下收起
                maskColor
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { onClose() }

                VStack(spacing: 0) {
                    /* 下滑关闭只挂在把手 + 标题区：这里没有可滚内容，
                       不会和下面的 ScrollView 抢手势。面板内容区保持原样。 */
                    VStack(spacing: 0) {
                        if showsGrip { grip }
                        header
                    }
                    .contentShape(Rectangle())
                    .gesture(dismissDrag)

                    bodySection(cap: min(proxy.size.height * bodyMaxHeightRatio, bodyMaxHeight))

                    if let footer {
                        /* HTML `.sheet` 的底部内距是 `calc(10px + env(safe-area-inset-bottom))`：
                           面板本身铺到屏幕底（`ignoresSafeArea`），所以这里要把安全区补回来，
                           否则按钮会压在 Home Indicator 上。横向内距由调用方给（`.ocr-actions` 是 10）。 */
                        footer
                            .padding(.top, 8)
                            .padding(.bottom, 10 + proxy.safeAreaInsets.bottom)
                    }
                }
                // hug 模式传 nil：由子视图自己撑高
                /* 高度：常规按屏高比例锁死（最小 320，保证正文塞得下）。
                   键盘占掉下半屏时，`proxy.size.height` 已经被键盘缩过，
                   按比例算出来会矮于 320，所以下限还是 320；
                   面板上移的 keyboardInset 不参与高度计算 —— 两者相加才是屏幕占用。 */
                .frame(height: hugContent ? nil : max(320, proxy.size.height * heightRatio))
                .offset(y: dragOffset)
                .frame(maxWidth: .infinity)
                .background(panelBackground)
                .clipShape(
                    UnevenRoundedRectangle(
                        topLeadingRadius: cornerRadius,
                        bottomLeadingRadius: 0,
                        bottomTrailingRadius: 0,
                        topTrailingRadius: cornerRadius,
                        style: .continuous
                    )
                )
                .shadow(color: V2Color.glassShadow, radius: 16, x: 0, y: -4)
                /* 键盘弹起时把面板整体抬到键盘上沿。
                   面板是自绘的，不走系统避让（见 KeyboardHeight.swift 的注释），
                   不补这一段就会被键盘整块压住 —— 验证码弹窗的输入框和
                   「确认登录」全在键盘下面，只透出一条淡紫。 */
                .padding(.bottom, keyboardInset)
            }
            .ignoresSafeArea(edges: .bottom)
            // 跟手系统键盘的动画时长：键盘升起和面板上移要同时到位，不能一个先到
            .animation(.easeOut(duration: 0.24), value: keyboardInset)
        }
        // 面板本身不透明，其余区域透明 → 由系统层透出页面
        .presentationBackground(.clear)
    }

    // MARK: - 正文

    @ViewBuilder
    private func bodySection(cap: CGFloat) -> some View {
        if hugContent {
            /* 面板要 hug，就只能自己拿 ScrollView：先量内容高度，再按上限封顶。
               量不到时（第一帧）先给 1pt，避免先用整块屏高再缩回去的跳动。 */
            ScrollView {
                content()
                    .background(
                        GeometryReader { bodyProxy in
                            Color.clear.preference(
                                key: SheetBodyHeightKey.self,
                                value: bodyProxy.size.height
                            )
                        }
                    )
            }
            .frame(height: min(max(measuredBody, 1), cap))
            .onPreferenceChange(SheetBodyHeightKey.self) { measuredBody = $0 }
        } else {
            content()
        }
    }

    // MARK: - 下滑关闭

    /// 阈值取「拖过 120pt」或「松手时预测还会再滑 240pt」——两者任一成立就关，
    /// 否则弹回原位（带一点阻尼感，不硬切）。
    private var dismissDrag: some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                dragOffset = max(0, value.translation.height)
            }
            .onEnded { value in
                let shouldClose = value.translation.height > 120
                    || value.predictedEndTranslation.height > 240
                if shouldClose {
                    onClose()
                } else {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                        dragOffset = 0
                    }
                }
            }
    }

    // MARK: - 把手与标题

    /// `.v2-grip`：36–40×4 的把手，距顶 8
    private var grip: some View {
        Capsule()
            .fill(Color(hex: 0x1B2233).opacity(0.12))
            .frame(width: 40, height: 4)
            .padding(.top, 8)
            .padding(.bottom, 10)
    }

    /// `.v2-sh` / `.ocr-head`：标题在左，副标题与按钮靠右。
    private var header: some View {
        HStack(spacing: 8) {
            Text(title)
                .v2Text(titleType)
            Spacer(minLength: 8)
            if let subtitle {
                Text(subtitle)
                    .v2Text(.label11, color: V2Color.text3)
                    .lineLimit(1)
            }
            /* 两个按钮都撑到 44pt 触控高度：视觉上仍是 12/14 号文字，
               但点击区不能再是那 18pt 高的字形本身（HIG 最小 44×44）。 */
            if let closeTitle {
                Button(action: onClose) {
                    Text(closeTitle)
                        .v2Text(.label12, color: V2Color.text3)
                        .padding(.horizontal, 8)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            if let trailingTitle, let onTrailing {
                Button(action: onTrailing) {
                    Text(trailingTitle)
                        .v2Text(.title14, color: trailingEnabled ? V2Color.accent : V2Color.text3)
                        .padding(.horizontal, 8)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!trailingEnabled)
            }
        }
        .padding(.horizontal, headerInset)
        // 有把手时把手已经给了上距；没有把手的面板要自己补（HTML 4 + 14 = 18）
        .padding(.top, showsGrip ? 0 : 18)
        .padding(.bottom, 10)
    }
}

/// hug 模式下量正文高度用
private struct SheetBodyHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
