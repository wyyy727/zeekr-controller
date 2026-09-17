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

    var body: some View {
        // 玻璃形状合并为一份采样，避免相邻玻璃之间出现接缝
        GlassEffectContainer(spacing: Metrics.sectionSpacing) {
            ZStack(alignment: .bottom) {
                backgroundLayer

                activeScreen

                tabBar

                // 全局 Toast（车控指令回执等），浮在胶囊之上
                if let toast = store.toast {
                    ToastBubble(text: toast)
                        .padding(.bottom, 96)
                        .padding(.horizontal, Metrics.screenPadding)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .allowsHitTesting(false)
                }
            }
            .animation(.easeInOut(duration: 0.22), value: store.toast)
        }
        .tint(Theme.accent(scheme))
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

    /// 数据来源徽标文案：模拟数据 / 真实数据
    var modeText: String = "模拟数据"
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
        .scrollIndicators(.hidden)
    }

    private var topBar: some View {
        HStack(spacing: 8) {
            Spacer()

            trailingAccessory()

            Text(modeText)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(scheme == .dark ? ChineseColor.tianQing : ChineseColor.tianQingDeep)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .glassEffect(.regular, in: .capsule)
        }
        .padding(.horizontal, Metrics.screenPadding)
        .padding(.vertical, 8)
    }
}

extension ScreenContainer where Accessory == EmptyView {
    /// 无附加操作的常规页面
    init(modeText: String = "模拟数据", @ViewBuilder content: @escaping () -> Content) {
        self.init(
            modeText: modeText,
            trailingAccessory: { EmptyView() },
            content: content
        )
    }
}
