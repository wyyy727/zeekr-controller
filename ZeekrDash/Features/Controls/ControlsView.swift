//
//  ControlsView.swift
//  ZeekrDash
//
//  车控
//

import SwiftUI

/// 车控页：只放快捷车控面板。
///
/// 从车况页拆出来的理由 —— 车况页已经有电量 / 胎压 / 车身状态 / 位置四块，
/// 而车控是**高频操作**，每次都要滑到最底才能按；给它一个独立入口更直接。
///
/// 卡片本身（`ControlsPanel`）一行没改：拆的是"入口"，不是"实现"。
/// 这样两处若同时存在也不会漂移 —— 现在只有这一处。
struct ControlsView: View {

    @Environment(\.colorScheme) private var scheme
    @Environment(AppStore.self) private var store

    var body: some View {
        NavigationStack {
            ScreenContainer(modeText: store.modeBadgeText) {
                if store.needsLogin {
                    // 未登录：指令一律发不出去，与其摆一排必然失败的按钮，
                    // 不如给一条明确的去登录路径
                    loginHint
                } else if store.vehicleStatus != nil {
                    ControlsPanel()
                    footerNote
                } else if store.isLoading {
                    LoadingView(text: "正在获取车辆状态")
                        .padding(.top, 60)
                } else {
                    emptyState
                }

                if let message = store.errorMessage, store.hasData {
                    ErrorBanner(message: message, onRetry: { store.errorMessage = nil })
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .refreshable { await store.refresh() }
        }
        // `startPolling()` 内部对「已在轮询」有 guard，重复调用无副作用；
        // 这里再来一次是为了"直接落在车控页"的情况 —— 否则上锁/空调状态会一直不刷新。
        .onAppear { store.startPolling() }
    }

    // MARK: - 脚注

    private var footerNote: some View {
        VStack(spacing: 4) {
            if let lastRefresh = store.lastRefresh {
                Text("更新于 \(lastRefresh.formatted(date: .omitted, time: .standard))")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary(scheme))
            }
            Text("车控指令需在「设置」中开启总开关")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textTertiary(scheme))
        }
        .frame(maxWidth: .infinity)
        .multilineTextAlignment(.center)
        .padding(.top, 4)
    }

    // MARK: - 未登录

    private var loginHint: some View {
        VStack(spacing: 14) {
            Image(systemName: "lock.shield")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(Theme.textTertiary(scheme))

            Text("登录后才能下发车控指令")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Theme.textSecondary(scheme))

            Button {
                store.selectedTab = .settings
            } label: {
                Text("去设置登录")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(ChineseColor.xiangYaBai)
                    .padding(.horizontal, 22)
                    .frame(minHeight: Metrics.minTouchTarget)
                    .background(Theme.accent(scheme))
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }

    // MARK: - 空态

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "steeringwheel")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(Theme.textTertiary(scheme))
            Text("尚未获取到车辆数据")
                .font(.system(size: 13))
                .foregroundStyle(Theme.textSecondary(scheme))
            Text("连上服务端后即可下发车控指令")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textTertiary(scheme))
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }
}
