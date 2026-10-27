//
//  GlassSurface.swift
//  ZeekrDash
//
//  玻璃分层：真玻璃（浮层）与仿玻璃（内容卡）
//

import SwiftUI

// MARK: - 内容卡：仿玻璃（不实时模糊）

/// 内容卡外观 —— **刻意不做实时模糊**。
///
/// HTML 侧有 52 处 `backdrop-filter`。照搬成真玻璃，滚动时会掉帧到不可用；
/// 这是唯一「照搬反而更差」的地方，所以内容卡改用同色值的静态仿玻璃：
/// 肉眼几乎无差，但零模糊开销。
///
/// 规格出处 `index-v2.html` 的 `.v2-card` / `.card`（1668–1678 行）：
/// ```
/// background: rgba(255,255,255,.55);
/// border: 1px solid rgba(255,255,255,.90);
/// border-radius: 20px; padding: 16px;
/// box-shadow: inset 0 1px 2px 0 rgba(255,255,255,.60),
///             0 8px 24px 0 rgba(74,87,120,.12);
/// ```
struct CardSurface: ViewModifier {

    var radius: CGFloat = V2Metrics.cardRadius
    /// 卡片内距。默认 16；少数卡片（如登录墙 `.v2-wall{padding:36px 20px}`）自带更大的内距，
    /// 这时要传 0，否则两层内距叠起来会把内容挤扁。
    var padding: CGFloat = V2Metrics.cardPadding

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(cardShape.fill(V2Color.glassFill))
            .overlay(cardShape.strokeBorder(V2Color.glassEdge, lineWidth: 1))
            .overlay(innerHighlight)
            .shadow(
                color: V2Color.glassShadow,
                radius: V2Metrics.cardShadowRadius,
                x: 0,
                y: 8
            )
    }

    private var cardShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
    }

    /// `inset 0 1px 2px` 的近似。
    ///
    /// SwiftUI 没有 inset shadow。这里让 2pt 白描边整体下移 1pt，再按卡形裁掉溢出部分：
    /// 顶边留下一道内高光，底边被裁掉，左右只剩很淡的边 —— 与 CSS 观感一致。
    /// 不是精确复刻；真机校准时只需要改这一个方法。
    private var innerHighlight: some View {
        cardShape
            .stroke(V2Color.glassHighlight, lineWidth: 2)
            .offset(y: 1)
            .clipShape(cardShape)
    }
}

extension View {
    /// 内容卡：仿玻璃，不实时模糊。
    func v2Card(
        radius: CGFloat = V2Metrics.cardRadius,
        padding: CGFloat = V2Metrics.cardPadding
    ) -> some View {
        modifier(CardSurface(radius: radius, padding: padding))
    }
}

// MARK: - 浮层：真玻璃（实时模糊）

extension View {

    /// 真玻璃浮层（矩形圆角）—— chips、月份胶囊、sheet、弹层。
    ///
    /// 只给**浮层**用：数量少、不随内容滚动，实时模糊的开销扛得住。
    /// 描边单独叠 —— `.glassEffect` 只管玻璃材质，不管边框。
    func glassSurface(cornerRadius: CGFloat) -> some View {
        // 用 `RoundedRectangle` 而不是 `.rect(cornerRadius:)` 简写：
        // 后者是 iOS 17 才有的 Shape 简写，前者从第一天就有，写法也更明确。
        self.glassEffect(.regular, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(V2Color.glassEdge, lineWidth: 1)
            )
    }

    /// 真玻璃浮层（胶囊）—— 底栏、Toast、右上角徽标。
    func glassCapsule() -> some View {
        self.glassEffect(.regular, in: .capsule)
            .overlay(Capsule().strokeBorder(V2Color.glassEdgeStrong, lineWidth: 1))
    }
}

// MARK: - 背景：渐变 + 两处光斑

/// 屏幕底：180deg 三停渐变 + BlobViolet + BlobCyan。
///
/// 出处 `index-v2.html` 1631–1656：
/// ```
/// .screen { background: linear-gradient(180deg, #F7F8FC 0%, #EEF2FA 50%, #E8EEF7 100%); }
/// .screen::before { 300×300 @(170,-70) radial 四停 紫 }
/// .screen::after  { 260×260 @(-90,540) radial 四停 青 }
/// ```
///
/// ⚠️ 两处光斑的圆心都落在**方框的左上顶点**、半径 = 边长（HTML 注释专门警告过：
/// 按「圆心居中、半径一半」写会把紫色团缩小一半并挪错位置，白紫对比全糊掉）。
/// 所以这里是 `center: .topLeading` + `endRadius = 边长`，别改成 `.center`。
struct V2Background: View {

    var body: some View {
        LinearGradient(
            stops: [
                .init(color: V2Color.bgTop, location: 0),
                .init(color: V2Color.bgMiddle, location: 0.5),
                .init(color: V2Color.bgBottom, location: 1),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .overlay(alignment: .topLeading) { violetBlob }
        .overlay(alignment: .topLeading) { cyanBlob }
    }

    /// BlobViolet：300×300 @(170, -70)，四停 .40 / .18 / .04 / 0
    private var violetBlob: some View {
        RadialGradient(
            stops: [
                .init(color: V2Color.auraViolet.opacity(0.40), location: 0),
                .init(color: V2Color.auraViolet.opacity(0.18), location: 0.55),
                .init(color: V2Color.auraViolet.opacity(0.04), location: 0.80),
                .init(color: V2Color.auraViolet.opacity(0), location: 1),
            ],
            center: .topLeading,
            startRadius: 0,
            endRadius: 300
        )
        .frame(width: 300, height: 300)
        .clipShape(Circle())
        .offset(x: 170, y: -70)
        .allowsHitTesting(false)
    }

    /// BlobCyan：260×260 @(-90, 540)，四停 .35 / .157 / .035 / 0
    private var cyanBlob: some View {
        RadialGradient(
            stops: [
                .init(color: V2Color.auraCyan.opacity(0.35), location: 0),
                .init(color: V2Color.auraCyan.opacity(0.157), location: 0.55),
                .init(color: V2Color.auraCyan.opacity(0.035), location: 0.80),
                .init(color: V2Color.auraCyan.opacity(0), location: 1),
            ],
            center: .topLeading,
            startRadius: 0,
            endRadius: 260
        )
        .frame(width: 260, height: 260)
        .clipShape(Circle())
        .offset(x: -90, y: 540)
        .allowsHitTesting(false)
    }
}
