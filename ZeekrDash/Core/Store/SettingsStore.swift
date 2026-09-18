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
        static let apiToken       = "settings.apiToken"
    }

    // MARK: - 服务端地址

    var baseURL: String {
        didSet {
            UserDefaults.standard.set(baseURL, forKey: Key.baseURL)
            APIClient.shared.baseURL = baseURL
        }
    }

    /// 当前地址的形态：未配置 / 回环地址 / 真实地址
    ///
    /// 这是「数据从哪来」的唯一判定入口 —— 地址为空或指向 localhost 时
    /// 展示本地模拟数据，否则走真实服务端。视图依赖它做响应式重算。
    var endpointMode: EndpointMode {
        EndpointResolver.resolve(baseURL)
    }

    /// 是否应当直接使用本地模拟数据（不需要发起任何网络请求）
    var prefersMockData: Bool {
        endpointMode.preferredSourceIsMock
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

    // MARK: - 服务端 API 令牌

    /// 服务端启用 `API_TOKEN` 鉴权时填这里。
    ///
    /// 留空（默认）表示服务端未启用鉴权 —— 此时 App 不发送 Authorization 头。
    /// 服务端监听 0.0.0.0，开启车控后没有令牌等于局域网内谁都能解锁车辆，
    /// 所以两边的这个开关是一对。
    var apiToken: String {
        didSet {
            UserDefaults.standard.set(apiToken, forKey: Key.apiToken)
            APIClient.shared.authToken = apiToken
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
        apiToken = d.string(forKey: Key.apiToken) ?? ""

        APIClient.shared.baseURL = baseURL
        // didSet 在 init 期间不会触发，这里显式同步一次
        APIClient.shared.authToken = apiToken
    }
}
