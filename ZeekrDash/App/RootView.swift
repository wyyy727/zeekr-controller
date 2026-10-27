//
//  RootView.swift
//  ZeekrDash
//
//  根视图：五 Tab + 液态玻璃
//
//  设计对齐确认版预览页（preview/index.html）：
//  - 底部导航为「悬浮玻璃胶囊」，两侧留 14pt 间隙，而非通栏
//  - 胶囊由原生 `safeAreaBar(edge: .bottom)` 承载，下沿距屏幕物理底 22pt
//    （实测系统电话 app 为 21.7pt）—— 会压进底部安全区，但避开 Home Indicator 白条
//  - 背景有一层氛围光斑（4 组径向渐变）—— 玻璃必须有可折射的内容才看得出效果
//  - 卡片保持实心（密集文字上盖玻璃是可读性灾难，Apple HIG 明确反对）
//  - 不使用 .clipped()，它会让玻璃采样不到背景从而静默失效
//

import SwiftUI

struct RootView: View {

    @Environment(AppStore.self) private var store

    /// 进出前后台统一在这里处理。不能下放到页面：页面随 tab 重建，
    /// 用户停在别的 tab 时车况页不在树里，它的监听根本不会触发。
    @Environment(\.scenePhase) private var scenePhase

    /// 当前 Tab 由 AppStore 持有 —— 车况页的登录引导要能把用户送到「设置」页
    private var selectedTab: AppTab { store.selectedTab }

    /// 悬浮胶囊下沿距**屏幕物理底边**的留白。
    ///
    /// **22 是量出来的，不是估的**：iPhone 16 Pro（402×874pt @3x）的系统电话 app
    /// 截图逐像素测量 —— 胶囊下沿距屏幕底 65px / 3 = 21.7pt，取 22；
    /// 同一张图里侧边距 61px / 3 = 20.3pt（我们取 21）、胶囊高 180px / 3 = 60pt
    /// （我们取 62，差 2pt 来自 v2 规格，未改）。
    ///
    /// 注意 22 < 底部安全区 34：即 Apple 自己的悬浮底栏**就是压进安全区里的**。
    /// Home Indicator 的视觉条大约占距底 8–13pt，所以 22 仍然落在它上方约 9pt 处，
    /// 不会盖住。真正要避开的不是「34pt 安全区」，而是那条 5pt 高的白条本身。
    /// （第 11 轮我曾按「必须待在安全区之上」推到 48，属判断失误。）
    private static let tabBarBottomGap: CGFloat = 22

    /// Toast 距**屏幕物理底边**的间距（与胶囊同一基准，见上）。
    ///
    /// 需紧贴底部导航胶囊上方，而不是让 Toast 落在内容区 ——
    /// 车控面板是车况页最后一张卡片，若 Toast 浮在屏幕中部偏下的位置，
    /// 滚到底部时两者会占据同一区域而互相遮挡。
    ///
    /// 数值 = 下留白 22 + 胶囊 62 = 84（胶囊上沿），再留 8 的间隙 = 92。
    private static let toastBottomInset: CGFloat = 92

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
                        .padding(.horizontal, V2Metrics.screenPadding)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .allowsHitTesting(false)
                }
            }
            .animation(.easeInOut(duration: 0.22), value: store.toast)
        }
        /* 越过底部安全区，让下一行的 `safeAreaBar` 把 bar 锚在**屏幕物理底边**上。
           不能只靠 bar 自身：它锚的是父视图的边界，不越过安全区就锚在安全区上沿，
           胶囊会被顶高 34pt（第 11 轮就是这么来的）。 */
        .ignoresSafeArea(.container, edges: .bottom)
        /* 底部胶囊走原生 `safeAreaBar`（iOS 26）：
           · 它与 `safeAreaInset` 同构 —— **只内缩安全区、不裁剪内容**，
             滚动时页面从胶囊底下穿过，玻璃才有可折射的动内容；
           · 文档原文「extends the edge effect of any scroll views affected by the
             inset safe area」，胶囊上方那条边缘淡出由系统负责，不必手写。
           早期这里是「整层 ignoresSafeArea + 内容自带 105pt 留白」—— 那是网页
           （`position:fixed` + `.wrap` padding）的机制，iOS 有原生 API 不该照抄。 */
        .safeAreaBar(edge: .bottom, spacing: V2Metrics.tabBarContentGap) {
            tabBar
        }
        .tint(V2Color.accent)
        // 全局请求指示条（对应网页顶部的 #netBar）。
        //
        // 挂在最外层的 `.overlay(alignment: .top)` 而不是塞进 ZStack：
        // ZStack 的对齐是 `.bottom`（给底部胶囊和 Toast 用的），
        // 放进去会贴着屏幕底边。
        // 对齐基准是**安全区上沿**，所以它正好落在状态栏下方，
        // 不会压到灵动岛。
        .overlay(alignment: .top) {
            if NetworkActivity.shared.isBusy {
                NetworkProgressBar()
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
        }
        .animation(.easeInOut(duration: 0.18), value: NetworkActivity.shared.isBusy)
        /* 充电结束的**全局**标记：监听不能只挂在充电页上 ——
           切 tab 会销毁 ChargesView，用户充完电去看车况，那次同步就丢了，
           而"当天已同步"又会拦住后续补同步，于是新流水要到第二天才出现。
           这里只记一个待办（不联网），下次进充电页由 `load()` 消费。 */
        .onChange(of: store.isCharging) { wasCharging, isCharging in
            if wasCharging && !isCharging {
                ChargeSyncStamp.markCharged()
            }
        }
        /* 进出前后台：只有从 .background 回到 .active 才算「重新打开」，
           .inactive（下拉通知中心 / 来电）之后回前台不补刷。 */
        .onChange(of: scenePhase) { previous, phase in
            switch phase {
            case .active:
                store.appDidBecomeActive(fromBackground: previous == .background)
            case .background:
                store.appDidEnterBackground()
            default:
                break
            }
        }
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
        case .controls:
            ControlsView()
        case .settings:
            SettingsView()
        }
    }

    // MARK: - 背景：v2 渐变 + 两处光斑

    /// 照抄 `index-v2.html` 1631–1656 的 `.screen`：
    /// 180deg 三停渐变（#F7F8FC → #EEF2FA → #E8EEF7）+ BlobViolet + BlobCyan。
    ///
    /// 旧的四团青/橙光斑整体删除：v2 只有两团，且位置与半径都是量出来的定值，
    /// 不是按屏幕比例估的 —— 换成比例会把紫团挪错位置（HTML 注释专门警告过）。
    private var backgroundLayer: some View {
        V2Background()
            .ignoresSafeArea()
    }

    // MARK: - 底部悬浮玻璃胶囊

    private var tabBar: some View {
        /* 规格（index-v2.html `.tabbar-inner`，实测 getBoundingClientRect）：
           高 62 / 圆角 36 / 内距 0 10 / 项间距 4.5 / 5 项各 62×54
           → 5×62 + 4×4.5 + 20 = 348，正好是胶囊宽度。 */
        HStack(spacing: V2Metrics.tabItemGap) {
            ForEach(AppTab.allCases) { tab in
                tabItem(tab)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: V2Metrics.tabBarHeight)
        // 底栏是浮层 → 真玻璃（任务书 1.2）。不用 .capsule：胶囊半径是高度的一半(31)，
        // 而设计是 36，肉眼能看出差别。
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: V2Metrics.tabBarRadius, style: .continuous))
        .padding(.horizontal, V2Metrics.tabBarSideInset)
        // 两侧留白 21（实测电话 app 20.3）、下沿距屏幕底 22（实测 21.7）。
        .padding(.bottom, Self.tabBarBottomGap)
    }

    private func tabItem(_ tab: AppTab) -> some View {
        let isOn = tab == selectedTab

        return Button {
            guard !isOn else { return }
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                store.selectedTab = tab
            }
        } label: {
            /* HTML `.tab`：gap 4、字号 11、字重 **500（选中也是 500）**、
               `transform: none` —— 规格里明确写了「不做选中胶囊 / 底色 / 放大动画」。 */
            VStack(spacing: 4) {
                Image(tab.assetName)
                    .renderingMode(.template)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: V2Metrics.tabIconSize, height: V2Metrics.tabIconSize)

                Text(tab.title)
                    .v2Text(.label11, color: isOn ? V2Color.accent : V2Color.text2)
            }
            .foregroundStyle(isOn ? V2Color.accent : V2Color.text2)
            .frame(width: V2Metrics.tabItemWidth, height: V2Metrics.tabItemHeight)
            .contentShape(Rectangle())
        }
        // 按下整项 opacity .72（HTML `.tab:active`）
        .buttonStyle(TabPressStyle())
        .accessibilityLabel(tab.title)
        .accessibilityAddTraits(isOn ? [.isSelected] : [])
    }
}

/// 底栏按下反馈：整项 opacity .72（HTML `.tab:active{opacity:.72}`）
private struct TabPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.72 : 1)
    }
}

// MARK: - 四个 Tab

enum AppTab: String, CaseIterable, Identifiable {
    // 车控单开一页：车况页太长，而车控是高频操作（见 ControlsView 顶部注释）
    case dashboard, trips, charges, controls, settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dashboard: return "车况"
        case .trips:     return "行程"
        case .charges:   return "充电"
        case .controls:  return "车控"
        case .settings:  return "设置"
        }
    }

    /// 底栏图标资产（`Icons.xcassets` 的 `tab-*`，24×24 线稿，stroke 1.7）。
    /// HTML 用 `<use href="#tab-dashboard">` 引同一批 SVG —— 不许再用 SF Symbols 顶替。
    var assetName: String {
        switch self {
        case .dashboard: return "tab-dashboard"
        case .trips:     return "tab-trips"
        case .charges:   return "tab-charging"
        case .controls:  return "tab-controls"
        case .settings:  return "tab-settings"
        }
    }
}

// MARK: - 页面统一容器

/// 页面层统一容器
///
/// 顶部只保留右上角一枚玻璃胶囊徽标 —— 页面大标题与底部导航重复，已全部移除。
/// 背景保持透明，交给 `RootView` 的氛围光斑层，让玻璃有东西可折射。
struct ScreenContainer<Content: View, Accessory: View>: View {

    /// 数据来源胶囊；nil 不展示（真实数据无需标识）
    var modePill: ModePill?
    /// 胶囊**右侧**的附加文字（车况屏的「更新于 HH:MM」）。
    /// HTML 把它和来源胶囊放在同一行 `.v2-head--end` 里，不是内容区的另一行。
    var tailText: String?
    /// 屏内卡片纵向间距：默认 16，车况屏是唯一例外（12）
    var sectionGap: CGFloat
    /// 胶囊左侧的附加操作（如充电页的月份胶囊），默认无
    @ViewBuilder var trailingAccessory: () -> Accessory
    @ViewBuilder let content: () -> Content

    /// 显式 init：`@ViewBuilder` 标在存储属性上时，成员初始化器的参数推导
    /// 在不同 Swift 版本里表现不完全一致；显式写出来更稳（本机没有 Xcode 可验证）。
    init(
        modePill: ModePill?,
        tailText: String? = nil,
        sectionGap: CGFloat = V2Metrics.screenGap,
        @ViewBuilder trailingAccessory: @escaping () -> Accessory,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.modePill = modePill
        self.tailText = tailText
        self.sectionGap = sectionGap
        self.trailingAccessory = trailingAccessory
        self.content = content
    }

    var body: some View {
        /* 底部不写任何留白：外层 `safeAreaBar(edge: .bottom, spacing: 29)`
           已经把「胶囊高度 + 29」算进安全区 —— 内容滚到底时停在胶囊上方，
           滚动途中则从胶囊下面穿过（安全区只内缩、不裁剪）。 */
        ScrollView {
            VStack(spacing: sectionGap) {
                content()
            }
            .padding(.horizontal, V2Metrics.screenPadding)
        }
        .background(Color.clear)
        .safeAreaInset(edge: .top, spacing: 0) {
            topBar
        }
        .scrollIndicators(.hidden)
    }

    private var topBar: some View {
        HStack(spacing: 8) {
            Spacer()

            trailingAccessory()

            if let modePill {
                // `.v2-pill-src`：11/500/14、padding 4 8、r999、最大宽 140
                Text(modePill.text)
                    .v2Text(.label11, color: Color(hex: modePill.foregroundHex))
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .frame(maxWidth: 140)
                    .background(Color(hex: modePill.backgroundHex))
                    .clipShape(Capsule())
                    .transition(.opacity.combined(with: .scale(scale: 0.92)))
            }

            if let tailText {
                // `.v2-updated`：11/500/16 text-3，与胶囊间距 8（`.v2-head-r{gap:8}`）
                Text(tailText)
                    .v2Text(.note11, color: V2Color.text3)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, V2Metrics.screenPadding)
        // 定高：不管这一行放的是 22pt 的胶囊还是 32pt 的月份 chip，四屏首卡都对齐
        .frame(height: V2Metrics.topBarHeight)
        .animation(.easeInOut(duration: 0.2), value: modePill)
        .animation(.easeInOut(duration: 0.2), value: tailText)
    }
}

extension ScreenContainer where Accessory == EmptyView {
    /// 无附加操作的常规页面
    init(
        modePill: ModePill?,
        tailText: String? = nil,
        sectionGap: CGFloat = V2Metrics.screenGap,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.init(
            modePill: modePill,
            tailText: tailText,
            sectionGap: sectionGap,
            trailingAccessory: { EmptyView() },
            content: content
        )
    }
}
