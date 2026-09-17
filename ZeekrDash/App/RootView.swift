//
//  RootView.swift
//  ZeekrDash
//
//  根视图：四 Tab
//

import SwiftUI

struct RootView: View {

    @Environment(\.colorScheme) private var scheme
    @Environment(AppStore.self) private var store

    var body: some View {
        TabView {
            DashboardView()
                .tabItem { Label("车况", systemImage: "car.fill") }

            TripsView()
                .tabItem { Label("行程", systemImage: "chart.xyaxis.line") }

            ChargesView()
                .tabItem { Label("充电", systemImage: "bolt.fill") }

            SettingsView()
                .tabItem { Label("设置", systemImage: "gearshape.fill") }
        }
        // 主色跟随明暗模式，避免深色下对比度不足
        .tint(Theme.accent(scheme))
    }
}
