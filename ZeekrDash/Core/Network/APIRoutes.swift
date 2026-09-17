//
//  APIRoutes.swift
//  ZeekrDash
//
//  接口路径常量 —— 与 Python 服务端约定
//

import Foundation

enum APIRoutes {
    static let vehicleStatus  = "/api/vehicle/status"
    static let vehicleCommand = "/api/vehicle/command"
    static let trips          = "/api/trips"
    static let energyTrend    = "/api/energy/trend"
    static let chargesSummary = "/api/charges/summary"
    static let chargesRecords = "/api/charges/records"
    static let chargesImport  = "/api/charges/import"
    static let health         = "/api/health"
    static let authSendCode   = "/api/auth/sendCode"
    static let authVerifyCode = "/api/auth/verifyCode"
}
