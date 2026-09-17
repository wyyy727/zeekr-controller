//
//  ZeekrDashApp.swift
//  ZeekrDash
//
//  应用入口
//

import SwiftUI

@main
struct ZeekrDashApp: App {
    @State private var appStore = AppStore()
    @State private var settings = SettingsStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appStore)
                .environment(settings)
                .task {
                    // 启动即拉一次数据，让首屏尽快有内容
                    await appStore.refresh()
                }
        }
    }
}
