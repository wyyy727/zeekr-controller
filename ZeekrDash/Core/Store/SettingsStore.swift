//
//  SettingsStore.swift
//  ZeekrDash
//
//  设置持久化：UserDefaults 存储（与 @AppStorage 同源），@Observable 驱动视图刷新
//

import SwiftUI

@Observable
final class SettingsStore {

    static let shared = SettingsStore()

    // MARK: - 存储 Key（与 @AppStorage 同一 UserDefaults 域）

    private enum Key {
        static let baseURL        = "settings.baseURL"
        static let pollMinutes    = "settings.pollMinutes"
        static let commandsEnabled = "settings.commandsEnabled"
    }

    // MARK: - 服务端地址

    var baseURL: String {
        didSet {
            UserDefaults.standard.set(baseURL, forKey: Key.baseURL)
            APIClient.shared.baseURL = baseURL
        }
    }

    // MARK: - 轮询间隔（分钟，默认 5；充电中自动缩短为 60 秒）

    var pollIntervalMinutes: Double {
        didSet {
            UserDefaults.standard.set(pollIntervalMinutes, forKey: Key.pollMinutes)
        }
    }

    // MARK: - 车控指令总开关（默认关）

    var commandsEnabled: Bool {
        didSet {
            UserDefaults.standard.set(commandsEnabled, forKey: Key.commandsEnabled)
        }
    }

    // MARK: - 极氪账号（预留，仅本地记录手机号）

    var zeekrPhone: String {
        get { UserDefaults.standard.string(forKey: "settings.zeekrPhone") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "settings.zeekrPhone") }
    }

    private init() {
        let d = UserDefaults.standard
        baseURL = d.string(forKey: Key.baseURL) ?? APIClient.defaultBaseURL
        let storedMinutes = d.double(forKey: Key.pollMinutes)
        pollIntervalMinutes = storedMinutes > 0 ? storedMinutes : 5
        commandsEnabled = d.bool(forKey: Key.commandsEnabled)

        APIClient.shared.baseURL = baseURL
    }
}
