//
//  RootView.swift
//  ZeekrDash
//
//  根视图：四 Tab
//

import SwiftUI

struct RootView: View {

    var body: some View {
        TabView {
            DashboardView()
                .tabItem { Label("车况", systemImage: "car.fill") }
            TripsView()
                .tabItem { Label("行程", systemImage: "point.topleft.down.curvedto.point.bottomright.up.fill") }
            ChargesView()
                .tabItem { Label("充电", systemImage: "bolt.fill") }
            SettingsView()
                .tabItem { Label("设置", systemImage: "gearshape.fill") }
        }
        .tint(Theme.accent(.light))
    }
}
