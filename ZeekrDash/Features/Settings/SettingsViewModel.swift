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
    var isMock = false
    var isLiveConfigured = false
    var missingKeys: [String] = []

    // MARK: - 账号

    var phone: String = ""
    var pendingPhone: String = ""
    var isSending = false
    var isVerifying = false
    var isAuthenticated = false
    var accountMessage: String?
    var loginError: String?

    // MARK: - 健康检查

    func checkHealth(baseURL: String) async {
        isChecking = true
        defer { isChecking = false }

        APIClient.shared.baseURL = baseURL

        do {
            let health: HealthInfo = try await APIClient.shared.get(APIRoutes.health)
            isReachable = true
            isMock = health.mode == "mock"
            isLiveConfigured = health.configured
            missingKeys = health.missingKeys ?? []
        } catch {
            isReachable = false
            isMock = false
            isLiveConfigured = false
            missingKeys = []
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
