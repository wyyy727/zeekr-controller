//
//  RootView.swift
//  ZeekrDash
//
//  根视图：五 Tab + 液态玻璃
//
//  设计对齐确认版预览页（preview/index.html）：
//  - 底部导航为「悬浮玻璃胶囊」，两侧留 21pt 间隙，而非通栏
//  - 胶囊由 `.overlay(alignment: .bottom)` 钉在**屏幕物理底边**，下沿留白 14pt
//    （= 网页 `.tabbar{padding-bottom:14}`）—— 会压进底部安全区，但避开 Home Indicator 白条
//  - 键盘不参与布局（`.ignoresSafeArea(.keyboard)`）：顶栏/底栏是固定 chrome
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

    /// Toast 距**屏幕物理底边**的间距（与胶囊同一基准）。
    ///
    /// 需紧贴底部导航胶囊上方，而不是让 Toast 落在内容区 ——
    /// 车控面板是车况页最后一张卡片，若 Toast 浮在屏幕中部偏下的位置，
    /// 滚到底部时两者会占据同一区域而互相遮挡。
    ///
    /// 数值 = 下留白 14 + 胶囊 62 = 76（胶囊上沿），再留 8 的间隙 = 84。
    private static let toastBottomInset: CGFloat =
        V2Metrics.tabBarBottomGap + V2Metrics.tabBarHeight + 8

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
        /* 底部胶囊钉在**屏幕物理底边**（+ `V2Metrics.tabBarBottomGap` = 14）。
           为什么不用 `safeAreaBar(edge: .bottom)`：实测它把 bar 摆在**安全区上沿**，
           外层 `.ignoresSafeArea(.container, edges: .bottom)` 对它无效 ——
           22pt 的留白在真机上被算成 22 + 34 = 56pt（iPhone 16 Pro 截图逐像素量出来的）。
           改用 overlay 后 bar 由自己定位：坐标就是物理底边，留白就是 14。
           · 内容侧的留白不再由安全区自动产生，改由 `ScreenContainer` 的
             `.contentMargins(.bottom, V2Metrics.tabBarClearance)` 精确给出（105 = 14+62+29）；
           · overlay 覆盖在 ScrollView 之上，滚动时页面照样从胶囊底下穿过，
             玻璃仍能实时折射正在动的内容。 */
        .overlay(alignment: .bottom) {
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
        /* 越过底部安全区：容器（底栏要压到 Home Indicator 上）+ 键盘（顶栏/底栏是固定
           chrome，键盘弹出时不该被顶上去、不该被压扁）。

           ⚠️ **必须一次调用**：`.ignoresSafeArea(.container, .bottom)` 之后再链一个
           `.ignoresSafeArea(.keyboard, .bottom)` 的写法**只有前一条生效** —— 实测真机
           键盘弹出时，底栏胶囊下沿落在 545pt，而键盘上沿是 559pt，差的正是 14pt 留白：
           说明布局底边被算成了键盘上沿，键盘那条 region 根本没被忽略。
           一次传两个 region 才两个都生效。

           ⚠️ 位置也有讲究：写成 `.ignoresSafeArea(…).overlay { 底栏 }` 时，overlay 拿到的是
           **没扩张**的 frame（就是这个 545pt 的来源）；把两个 overlay 放在前面、
           越过安全区放最后，底栏/请求条才会跟着扩张后的 frame 贴到物理底边。 */
        .ignoresSafeArea([.container, .keyboard], edges: .bottom)
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
        // 两侧留白 21、下沿距屏幕底 14（= 网页 `.tabbar{padding-bottom:14}`）。
        .padding(.bottom, V2Metrics.tabBarBottomGap)
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

    /// 键盘遮住屏幕底部的高度（0 = 收起）。
    ///
    /// 读 `@Observable` 单例的属性即建立依赖 —— 键盘一变，本视图的 body 就会重算，
    /// 底部的安全区与留白跟着变。
    private var keyboardInset: CGFloat { KeyboardHeight.shared.value }

    var body: some View {
        /* 底部留白由这里自己给：底栏是 overlay（见 RootView），不再内缩安全区，
           所以滚到底要留出「下留白 14 + 胶囊 62 + 间隙 29 = 105」，
           与网页 `.wrap{padding-bottom:105px}` 一致。

           键盘**不参与**这条留白（2026-10-30 改）：键盘让位交给下面那条
           `.safeAreaInset(edge: .bottom)`，靠缩小可视区触发系统的自动滚动。 */
        /* 氛围背景画在**屏内容器里面**，不能只画在 RootView 那一层。
           `NavigationStack` 在 iOS 26 会给自己的视图铺一层不透明的系统底，
           它压在 RootView 的 `V2Background` 之上 —— 真机表现就是：静止时全白、
           切 Tab 的瞬间才闪一下白紫。2026-10-28 用「整屏漆红」的诊断包确认了这点：
           转场那一帧整屏是红的，静止后红色被盖掉。
           所以这里再画一份，位置在滚动内容之下、导航视图之上；
           同时关掉 ScrollView 自带的内容底色，两条可能都被堵上。 */
        ZStack {
            V2Background()
                .ignoresSafeArea()

            ScrollView {
                VStack(spacing: sectionGap) {
                    content()
                }
                .padding(.horizontal, V2Metrics.screenPadding)
            }
            /* 底部留白：平时 105（下留白 14 + 胶囊 62 + 间隙 29，与网页一致）。
               键盘弹起时底栏被键盘整个盖住，那 105 就白留了 —— 滚到底会看到
               一大片死白压在键盘上方，所以缩到 16。
               真正的「让位」由下面那条 safeAreaInset 负责，这里只管留白。 */
            .contentMargins(
                .bottom,
                keyboardInset > 0 ? 16 : V2Metrics.tabBarClearance,
                for: .scrollContent
            )
            .scrollContentBackground(.hidden)
            .safeAreaInset(edge: .top, spacing: 0) {
                topBar
            }
            /* 键盘让位（2026-10-30 修）：
               根视图 `.ignoresSafeArea(.keyboard)` 让底栏不被顶上去，代价是**滚动视图也
               不知道键盘占了半屏** —— 它以为自己可视到屏幕底，于是「自动把焦点输入框
               滚进可视区」这件事不会触发，输入框停在键盘后面。

               以前的做法是只把 `contentMargins.bottom` 临时撑到键盘高度：那只加了
               **可滚动的余量**，不会让系统认为可视区变小，所以输入框照样不滚上来；
               而且这条 margin 突变时没有任何动画，正停在底部的内容会「瞬跳」一下。

               现在改成给滚动视图加一条**真实的底部安全区**：可视区真的缩到键盘上沿，
               系统就会自己把焦点框滚上来。留白那条在这时缩到 16（底栏已被盖住）。 */
            .safeAreaInset(edge: .bottom, spacing: 0) {
                Color.clear
                    .frame(height: keyboardInset)
                    // 纯占位，不能吃掉底部的手势（否则键盘收起那一下可能被它截住）
                    .allowsHitTesting(false)
            }
            /* 键盘升降时可视区高度在变，加个缓动，别让内容硬跳一下。 */
            .animation(.easeOut(duration: 0.25), value: keyboardInset)
            .scrollIndicators(.hidden)
            /* 键盘收起：
               · 下拉列表即交互式收起（网页里靠点空白处）；
               · 数字键盘（手机号 / API 令牌）没有 Return 键，系统不给收起入口，
                 所以在键盘上方常驻一个「完成」—— 这是 iOS 上唯一可靠的出口。 */
            .scrollDismissesKeyboard(.interactively)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("完成") { dismissKeyboard() }
                }
            }
        }
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
