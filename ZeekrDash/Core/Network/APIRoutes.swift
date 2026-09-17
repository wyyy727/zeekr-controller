//
//  APIRoutes.swift
//  ZeekrDash
//
//  接口路径常量 —— 与 Python 服务端约定
//

import Foundation

enum APIRoutes {
    // 车辆
    static let vehicleStatus  = "/api/vehicle/status"
    static let vehicleCommand = "/api/vehicle/command"
    static let vehicleList    = "/api/vehicle/list"
    static let vehicleSnapshots = "/api/vehicle/snapshots"

    // 行程与能耗
    static let trips          = "/api/trips"
    static let energyTrend    = "/api/energy/trend"

    // 充电消费
    static let chargesSummary = "/api/charges/summary"
    static let chargesRecords = "/api/charges/records"
    static let chargesImport  = "/api/charges/import"

    // 认证
    static let authSendCode   = "/api/auth/sendCode"
    static let authVerifyCode = "/api/auth/verifyCode"
    static let authStatus     = "/api/auth/status"
    static let authLogout     = "/api/auth/logout"

    // 诊断
    static let health         = "/api/health"
}
