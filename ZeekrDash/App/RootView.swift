//
//  RootView.swift
//  ZeekrDash
//
//  根视图：四 Tab + 液态玻璃
//
//  设计对齐确认版预览页（preview/index.html）：
//  - 底部导航为「悬浮玻璃胶囊」，两侧留 14pt 间隙，而非通栏
//  - 背景有一层氛围光斑（4 组径向渐变）—— 玻璃必须有可折射的内容才看得出效果
//  - 卡片保持实心（密集文字上盖玻璃是可读性灾难，Apple HIG 明确反对）
//  - 不使用 .clipped()，它会让玻璃采样不到背景从而静默失效
//

import SwiftUI

struct RootView: View {

    @Environment(\.colorScheme) private var scheme
    @Environment(AppStore.self) private var store

    @State private var selectedTab: AppTab = .dashboard

    /// 悬浮胶囊两侧的留白，让 tab bar 从内容上「浮」起来
    private static let tabBarSideInset: CGFloat = 14

    /// Toast 距屏幕底部的间距。
    ///
    /// 需紧贴底部导航胶囊上方，而不是让 Toast 落在内容区 ——
    /// 车控面板是车况页最后一张卡片，若 Toast 浮在屏幕中部偏下的位置，
    /// 滚到底部时两者会占据同一区域而互相遮挡。
    /// 数值 = 胶囊高度（约 64pt）+ 底部留白 6pt + 安全区（约 34pt）+ 间隙 8pt。
    private static let toastBottomInset: CGFloat = 112

    var body: some View {
        // 这里刻意**不使用** `GlassEffectContainer`。
        //
        // 该容器会按「两个玻璃形状的距离小于 spacing」把它们合并成同一个形状。
        // 而本视图树里同时存在两类玻璃：
        //   · 跟着页面滚动的 —— 车控面板那 15 个按钮、卡片上的徽标；
        //   · 钉在屏幕上的   —— 顶部数据来源徽标、Toast、底部导航胶囊。
        // 容器对两者一视同仁地做距离判定，于是滚动过程中「滚动玻璃」与
        // 「固定玻璃」的相对距离一直在变，合并关系被反复建立又拆散 ——
        // 表现就是按钮的玻璃轮廓跟着滚动游动、形变，永远停不到一个固定位置。
        //
        // 预览页 preview/index.html 里每块玻璃都是各自独立的 `backdrop-filter`，
        // 本来就不存在「相邻玻璃合并」这回事，去掉容器反而更贴近设计稿。
        ZStack(alignment: .bottom) {
            backgroundLayer

            activeScreen

            // 全局 Toast（车控指令回执等），紧贴底部导航胶囊之上。
            //
            // 动画只挂在这一层，不挂在包含 ScrollView 的父层：把
            // `.animation(_:value:)` 套在滚动容器外面时，toast 一变，
            // 整棵子树（含滚动内容）都会一起进入动画，车控按钮会跟着晃。
            ZStack(alignment: .bottom) {
                if let toast = store.toast {
                    ToastBubble(text: toast)
                        .padding(.bottom, Self.toastBottomInset)
                        .padding(.horizontal, Metrics.screenPadding)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .allowsHitTesting(false)
                }
            }
            .animation(.easeInOut(duration: 0.22), value: store.toast)

            tabBar
        }
        .tint(Theme.accent(scheme))
        .alert(
            "已切换为模拟数据",
            isPresented: Binding(
                get: { store.pendingDataSourceNotice != nil },
                set: { if !$0 { store.pendingDataSourceNotice = nil } }
            )
        ) {
            Button("知道了", role: .cancel) {
                store.pendingDataSourceNotice = nil
            }
        } message: {
            Text(store.pendingDataSourceNotice ?? "")
        }
    }

    // MARK: - 屏幕容器

    /// 只承载当前 Tab 的页面；四页各自在内部持有 NavigationStack。
    /// 切 Tab 时重建页面，行为与原 TabView 一致。
    @ViewBuilder
    private var activeScreen: some View {
        switch selectedTab {
        case .dashboard:
            DashboardView()
        case .trips:
            TripsView()
        case .charges:
            ChargesView()
        case .settings:
            SettingsView()
        }
    }

    // MARK: - 背景氛围光斑

    /// 青 / 橙调光斑，模糊 6pt。
    /// 固定在底层不随内容滚动，模拟 iOS 壁纸透过玻璃的效果。
    private var backgroundLayer: some View {
        GeometryReader { geo in
            ZStack {
                Theme.background(scheme)

                aura(
                    ChineseColor.tianQing.opacity(scheme == .dark ? 0.22 : 0.16),
                    at: UnitPoint(x: 0.18, y: 0.12),
                    radius: 0.26 * min(geo.size.width, geo.size.height),
                    in: geo.size
                )

                aura(
                    ChineseColor.qingBi.opacity(scheme == .dark ? 0.16 : 0.13),
                    at: UnitPoint(x: 0.84, y: 0.22),
                    radius: 0.24 * min(geo.size.width, geo.size.height),
                    in: geo.size
                )

                aura(
                    ChineseColor.dianLan.opacity(scheme == .dark ? 0.20 : 0.14),
                    at: UnitPoint(x: 0.62, y: 0.88),
                    radius: 0.30 * min(geo.size.width, geo.size.height),
                    in: geo.size
                )

                aura(
                    ChineseColor.tiSe.opacity(scheme == .dark ? 0.12 : 0.10),
                    at: UnitPoint(x: 0.08, y: 0.76),
                    radius: 0.22 * min(geo.size.width, geo.size.height),
                    in: geo.size
                )
            }
            .blur(radius: 6)
        }
        .ignoresSafeArea()
    }

    private func aura(
        _ color: Color,
        at center: UnitPoint,
        radius: CGFloat,
        in size: CGSize
    ) -> some View {
        RadialGradient(
            colors: [color, color.opacity(0)],
            center: center,
            startRadius: 0,
            endRadius: max(radius, 1)
        )
        .frame(width: size.width, height: size.height)
    }

    // MARK: - 底部悬浮玻璃胶囊

    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(AppTab.allCases) { tab in
                tabItem(tab)
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 7)
        .glassEffect(.regular, in: .capsule)
        .padding(.horizontal, Self.tabBarSideInset)
        // 贴在安全区之上，两侧留 14pt，整体悬浮而非通栏
        .padding(.bottom, 6)
    }

    private func tabItem(_ tab: AppTab) -> some View {
        let isOn = tab == selectedTab

        return Button {
            guard !isOn else { return }
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                selectedTab = tab
            }
        } label: {
            VStack(spacing: 3) {
                Image(systemName: tab.systemImage)
                    .font(.system(size: 21))
                    .scaleEffect(isOn ? 1.06 : 1)
                    .animation(.spring(response: 0.24, dampingFraction: 0.6), value: isOn)

                Text(tab.title)
                    .font(.system(size: 10, weight: isOn ? .semibold : .regular))
            }
            .foregroundStyle(isOn ? Theme.accent(scheme) : Theme.textTertiary(scheme))
            .frame(maxWidth: .infinity, minHeight: 50)
            // 选中态：玻璃上的一层高光药丸
            .background {
                if isOn {
                    Capsule()
                        .fill(ChineseColor.xiangYaBai.opacity(scheme == .dark ? 0.12 : 0.70))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tab.title)
        .accessibilityAddTraits(isOn ? [.isSelected] : [])
    }
}

// MARK: - 四个 Tab

enum AppTab: String, CaseIterable, Identifiable {
    case dashboard, trips, charges, settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dashboard: return "车况"
        case .trips:     return "行程"
        case .charges:   return "充电"
        case .settings:  return "设置"
        }
    }

    var systemImage: String {
        switch self {
        case .dashboard: return "car"
        case .trips:     return "chart.xyaxis.line"
        case .charges:   return "bolt"
        case .settings:  return "gearshape"
        }
    }
}

// MARK: - 页面统一容器

/// 页面层统一容器
///
/// 顶部只保留右上角一枚玻璃胶囊徽标 —— 页面大标题与底部导航重复，已全部移除。
/// 背景保持透明，交给 `RootView` 的氛围光斑层，让玻璃有东西可折射。
struct ScreenContainer<Content: View, Accessory: View>: View {

    @Environment(\.colorScheme) private var scheme

    /// 数据来源徽标文案；传 nil 则不展示徽标（真实数据无需标识）
    var modeText: String?
    /// 徽标左侧的附加操作（如充电页的账单菜单），默认无
    @ViewBuilder var trailingAccessory: () -> Accessory
    @ViewBuilder let content: () -> Content

    var body: some View {
        ScrollView {
            VStack(spacing: Metrics.sectionSpacing) {
                content()
            }
            .padding(.horizontal, Metrics.screenPadding)
            .padding(.bottom, 24)
        }
        .background(Color.clear)
        .safeAreaInset(edge: .top, spacing: 0) {
            topBar
        }
        // 为底部浮动导航胶囊预留空间。
        //
        // 为什么用 safeAreaBar（iOS 26+）而不是 safeAreaInset：
        // 两者都会把滚动内容顶上来，但 safeAreaBar 额外会把**滚动边缘效果**
        // 延伸到这一侧 —— 内容滚到胶囊附近时是柔和淡出，而不是被硬生生裁在
        // 胶囊下面。胶囊本身仍是浮在内容之上的（见 RootView.tabBar），内容
        // 照旧从它底下穿过，视觉规格与 preview/index.html 一致。
        //
        // 高度只写胶囊自身占的 70pt；系统安全区由 safeAreaBar 自动叠加，
        // 不必手算 34pt。此前这里缺了这道预留 —— 胶囊占了 104pt 而内容只留
        // 24pt，导致「快捷车控」永远滚不到胶囊上方，只能在它后面来回弹。
        .safeAreaBar(edge: .bottom, spacing: 0) {
            Color.clear.frame(height: Metrics.tabBarClearance)
        }
        .scrollIndicators(.hidden)
    }

    private var topBar: some View {
        HStack(spacing: 8) {
            Spacer()

            trailingAccessory()

            if let modeText {
                Text(modeText)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(scheme == .dark ? ChineseColor.tianQing : ChineseColor.tianQingDeep)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .glassEffect(.regular, in: .capsule)
                    .transition(.opacity.combined(with: .scale(scale: 0.92)))
            }
        }
        .padding(.horizontal, Metrics.screenPadding)
        .padding(.vertical, 8)
        .animation(.easeInOut(duration: 0.2), value: modeText)
    }
}

extension ScreenContainer where Accessory == EmptyView {
    /// 无附加操作的常规页面
    init(modeText: String?, @ViewBuilder content: @escaping () -> Content) {
        self.init(
            modeText: modeText,
            trailingAccessory: { EmptyView() },
            content: content
        )
    }
}
