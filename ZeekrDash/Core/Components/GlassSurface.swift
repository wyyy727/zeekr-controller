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
///
/// ### 与网页的两处刻意偏离（方案 B，2026-10-28 用户拍板）
///
/// 用户反馈「iOS 的卡片跟背景对比不够，一眼看不出是卡片」。用无头浏览器
/// 渲染 v2 HTML 逐像素实测后定位到根因，并做了两处调整：
///
/// 1. **描边**：网页用 `rgba(255,255,255,.90)` —— 白描边画在浅色背景上
///    对比度只有 **1.055**，等于没画。它在网页上之所以立得住，靠的是
///    `backdrop-filter` 把背景的紫揉进卡内形成的质感差；
///    iOS 内容卡不做真模糊，这条质感差没了，只剩一条看不见的白边。
///    → 改为 `V2Color.cardStroke`（冷灰蓝 .22，实测对比度 1.160，
///    接近网页原版描边的 1.166）。
/// 2. **阴影**：网页 `rgba(74,87,120,.12)` 在 CSS 的 24px 模糊下才够柔；
///    SwiftUI 的 shadow 衰减更快，同样的 .12 几乎看不出「浮起」。
///    → 改为 `V2Color.cardShadow`（.18）。
///
/// ⚠️ 填充仍是网页原样的**白 .55** —— 实测把它提到 .78 只会让卡片更「实」、
/// 更像普通白卡片，反而不像玻璃（明度对比 1.033 → 1.056，收益极小）。
/// 玻璃感靠的是通透，不是白度。
///
/// 这两个新值是**内容卡专用**，不复用 `glassEdge`/`glassShadow` ——
/// 后者被真玻璃浮层与图表复用，那些元素本身立得住，不该跟着变重。
struct CardSurface: ViewModifier {

    var radius: CGFloat = V2Metrics.cardRadius
    /// 卡片内距。默认 16；少数卡片（如登录墙 `.v2-wall{padding:36px 20px}`）自带更大的内距，
    /// 这时要传 0，否则两层内距叠起来会把内容挤扁。
    var padding: CGFloat = V2Metrics.cardPadding

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(cardShape.fill(V2Color.glassFill))
            .overlay(cardShape.strokeBorder(V2Color.cardStroke, lineWidth: 1))
            .overlay(innerHighlight)
            .shadow(
                color: V2Color.cardShadow,
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
///
/// ### 光斑的位置为什么按屏宽比例而不是绝对值
///
/// 网页的 `.screen` 是**固定 390 宽的手机壳**（`width:390px; margin:0 auto`），
/// 设计稿的 `left:170px` 就是相对这个 390 宽壳量的。
/// iOS 侧没有这层壳 —— 背景直接铺满**物理屏**（375~430pt 随机型变）。
/// 若照抄绝对值 170，紫团圆心在屏宽的占比会随机型漂移：
///
/// | 机型 | 屏宽 | 绝对 170 的占比 | 比例定位的占比 |
/// |---|---|---|---|
/// | iPhone SE | 375 | 45.3% | 43.6% |
/// | iPhone 16 Pro | 402 | 42.3% | 43.6% |
/// | Pro Max | 430 | 39.5% | 43.6% |
///
/// 也就是宽屏上紫团会偏左、窄屏上偏右 —— 而 HTML 的观感是固定的。
/// 所以这里把 390 当作**设计稿基准宽度**，光斑的横向落点按 `屏宽/390` 等比换算，
/// 各机型的「左白右紫」比例与网页一致。
///
/// 纵向（top = -70 / 540）**不缩放**：它对应的是状态栏与内容区的固定高度关系，
/// 跟屏宽无关，缩放会让紫团在不同机型上高低不一。
struct V2Background: View {

    /// 临时诊断开关（2026-10-28）。
    ///
    /// 为 true 时把整块背景漆成纯红，用来判断这一层到底有没有被画出来、
    /// 又被哪一层盖住（真机现象：切 Tab 瞬间闪现一下白紫，随后被覆盖）。
    /// 诊断结束必须删掉这个开关与调用点。
    var diagnosticRed: Bool = false

    /// 设计稿基准宽度（网页 `.screen` 的固定宽度）。
    static let designWidth: CGFloat = 390

    /// 宽度不到它时**不按比例换算**，退回 390 设计稿的绝对偏移（2026-10-28 补）。
    ///
    /// 比例换算的前提是「这块背景就是整屏」。`SOCRing.swift:210`、`ToastBubble.swift:41`
    /// 这类 200pt 级的小容器也复用了 `V2Background()`，按比例落点会把光斑整体推进可视区，
    /// 观感与改动前不同。小容器沿用旧行为，整屏背景仍与网页一致。
    static let ratioMinWidth: CGFloat = 260

    /// 光斑横向落点：宽容器 `设计稿偏移 × 屏宽 / 390`，窄容器退回设计稿绝对值。
    ///
    /// `design` 直接传 HTML 里的像素值（BlobViolet 170、BlobCyan -90）。
    static func blobOffset(width: CGFloat, design: CGFloat) -> CGFloat {
        width >= ratioMinWidth ? width * (design / designWidth) : design
    }

    var body: some View {
        // 屏宽用 GeometryReader 取：背景要铺满物理屏，比例才准。
        //
        // 结构刻意保持「渐变 + 两个 overlay」而不是 ZStack：
        // ZStack 会被 300×300 的光斑撑大尺寸，在小尺寸预览下渐变就不再铺满；
        // overlay 不参与父级尺寸计算，行为与改动前完全一致（只是 x 变成按比例算的）。
        GeometryReader { proxy in
            LinearGradient(
                stops: [
                    .init(color: diagnosticRed ? Color.red : V2Color.bgTop, location: 0),
                    .init(color: diagnosticRed ? Color.red : V2Color.bgMiddle, location: 0.5),
                    .init(color: diagnosticRed ? Color.red : V2Color.bgBottom, location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .overlay(alignment: .topLeading) {
                violetBlob(x: Self.blobOffset(width: proxy.size.width, design: 170))
            }
            .overlay(alignment: .topLeading) {
                cyanBlob(x: Self.blobOffset(width: proxy.size.width, design: -90))
            }
        }
    }

    /// BlobViolet：300×300，横向 @(屏宽×43.6%)、纵向 -70，四停 .40 / .18 / .04 / 0
    private func violetBlob(x: CGFloat) -> some View {
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
        .offset(x: x, y: -70)
        .allowsHitTesting(false)
    }

    /// BlobCyan：260×260，横向 @(屏宽×-23.1%)、纵向 540，四停 .35 / .157 / .035 / 0
    private func cyanBlob(x: CGFloat) -> some View {
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
        .offset(x: x, y: 540)
        .allowsHitTesting(false)
    }
}
