//
//  SettingsViewModel.swift
//  ZeekrDash
//
//  设置页状态管理：连接诊断与账号登录
//

import Foundation
import SwiftUI

@Observable
@MainActor
final class SettingsViewModel {

    // MARK: - 服务端诊断

    var isChecking = false
    var isReachable = false
    var isLiveConfigured = false
    var missingKeys: [String] = []
    /// 服务端是否允许下发车控指令（`.env` 的 `ALLOW_COMMANDS`）。
    ///
    /// 与「设置」里那个本地总开关是**两把锁**：本开关只管"这个界面允不允许发"，
    /// 服务端那个管"收不收"。取不到时为 nil，界面显示 `--` ——
    /// 不猜，免得把"没问到"说成"已开启"。
    var serverAllowCommands: Bool?
    /// 地址形态（未配置 / 回环 / 真实）
    var endpointMode: EndpointMode = .unset
    /// 当前界面实际展示的数据来源
    var dataMode: DataMode = .mock

    /// 地址未配置或指向 localhost —— 此时走本地模拟数据，不联网
    var isLocalEndpoint: Bool { endpointMode.preferredSourceIsMock }

    // MARK: - 账号

    var phone: String = ""
    var pendingPhone: String = ""
    var isSending = false
    var isVerifying = false
    var isLoggingOut = false
    var isAuthenticated = false
    var accountMessage: String?
    var loginError: String?

    // MARK: - 健康检查

    func checkHealth(baseURL: String) async {
        isChecking = true
        defer { isChecking = false }

        endpointMode = EndpointResolver.resolve(baseURL)

        // 未配置 / localhost：按约定直接使用模拟数据，不做网络探测，
        // 也就没有「连不连得上」的问题，状态直接按模拟数据呈现。
        guard !endpointMode.preferredSourceIsMock else {
            isReachable = false
            isLiveConfigured = false
            missingKeys = []
            serverAllowCommands = nil
            dataMode = .mock
            return
        }

        APIClient.shared.baseURL = baseURL

        do {
            let health: HealthInfo = try await APIClient.shared.get(APIRoutes.health)
            isReachable = true
            isLiveConfigured = health.configured
            missingKeys = health.missingKeys ?? []
            serverAllowCommands = health.allowCommands
            // 服务端自己也处于 mock 态时，界面拿到的仍是模拟数据
            dataMode = (health.mode == "mock") ? .offline : .live
        } catch {
            isReachable = false
            isLiveConfigured = false
            missingKeys = []
            serverAllowCommands = nil
            // 配置了真实地址却连不上 —— 与首页一致，已回落模拟数据
            dataMode = .offline
        }

        // 顺带刷新登录状态
        if isReachable {
            await refreshAuthStatus()
        }
    }

    private func refreshAuthStatus() async {
        do {
            let status: AuthStatus = try await APIClient.shared.get(APIRoutes.authStatus)
            isAuthenticated = status.authenticated
        } catch {
            isAuthenticated = false
        }
    }

    // MARK: - 发送验证码

    func sendCode() async -> Bool {
        guard !isSending else { return false }
        isSending = true
        accountMessage = nil
        loginError = nil
        defer { isSending = false }

        do {
            let result: AuthActionResult = try await APIClient.shared.post(
                APIRoutes.authSendCode,
                body: ["phone": phone]
            )
            pendingPhone = phone
            accountMessage = result.message
            return result.success
        } catch let error as ApiError {
            accountMessage = error.errorDescription
            return false
        } catch {
            accountMessage = error.localizedDescription
            return false
        }
    }

    // MARK: - 校验验证码

    func verifyCode(_ code: String) async -> Bool {
        guard !isVerifying else { return false }
        isVerifying = true
        loginError = nil
        defer { isVerifying = false }

        do {
            let result: AuthActionResult = try await APIClient.shared.post(
                APIRoutes.authVerifyCode,
                body: ["phone": pendingPhone, "code": code]
            )

            if result.success {
                isAuthenticated = true
                accountMessage = result.message
                return true
            }

            loginError = result.message
            return false
        } catch let error as ApiError {
            loginError = error.errorDescription
            return false
        } catch {
            loginError = error.localizedDescription
            return false
        }
    }

    // MARK: - 退出登录

    /// 退出登录。
    ///
    /// 服务端会清掉本地会话文件；客户端这边只需要把登录态置回未登录，
    /// 再由调用方 `store.refresh()` 触发一次「需要登录」的门禁 ——
    /// 车况、权限包、车辆位置都会在那一轮里被清空（见 AppStore 的 needsLogin 分支）。
    ///
    /// **不自己清 AppStore**：那些字段的清理规则集中在 AppStore 里，
    /// 设置页再清一遍容易漏（漏的就是隐私），也容易和轮询打架。
    func logout() async -> Bool {
        guard !isLoggingOut else { return false }
        isLoggingOut = true
        defer { isLoggingOut = false }

        do {
            let _: LogoutResult = try await APIClient.shared.post(APIRoutes.authLogout)
            isAuthenticated = false
            accountMessage = "已退出登录"
            loginError = nil
            return true
        } catch let error as ApiError {
            accountMessage = "退出失败：\(error.errorDescription ?? "未知错误")"
            return false
        } catch {
            accountMessage = "退出失败：\(error.localizedDescription)"
            return false
        }
    }
}

// MARK: - 接口响应模型

/// 服务端健康信息
struct HealthInfo: Codable {
    var status: String?
    var mode: String?
    var configured: Bool
    var missingKeys: [String]?
    var allowCommands: Bool?
}

/// 登录状态
struct AuthStatus: Codable {
    var authenticated: Bool
    var mock: Bool?
    var configured: Bool?
    var missingKeys: [String]?
}

/// 认证操作结果
struct AuthActionResult: Codable {
    var success: Bool
    var message: String?
    var vehicleCount: Int?
}

/// 退出登录的响应。
///
/// 后端返回的是 `{"success": true, "data": {"message": "已登出"}}` ——
/// `data` 里**只有 message**，没有 `success` 字段，所以不能复用
/// `AuthActionResult`（它的 `success` 是必填，会解码失败）。
struct LogoutResult: Codable {
    var message: String?
}
