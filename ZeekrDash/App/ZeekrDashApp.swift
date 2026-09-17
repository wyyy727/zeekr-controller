//
//  ZeekrDashApp.swift
//  ZeekrDash
//
//  应用入口
//

import SwiftUI

@main
struct ZeekrDashApp: App {

    /// 使用单例，保证与内部引用的是同一实例
    /// （SettingsStore 的 init 为 private，AppStore 需注入 settings）
    @State private var settings = SettingsStore.shared
    @State private var appStore = AppStore.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(settings)
                .environment(appStore)
                .task {
                    // 启动即拉一次数据，让首屏尽快有内容
                    await appStore.refresh()
                }
        }
    }
}
