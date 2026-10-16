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
    /// 车辆能力集 —— 先问车支持什么，再决定显示哪些车控按钮。
    /// 服务端取不到时返回 `capabilities: null`，前端据此**全部显示**（不隐藏）。
    static let vehicleCapability = "/api/vehicle/capability"
    /// 车控指令的**车端执行结果**查询（`?id=<commandId>`）。
    /// 网关回「已提交」只代表它收下了，不代表车动了 —— 不查结果会出现
    /// 「以为锁了车其实没锁」的假成功。
    static let commandResult  = "/api/vehicle/command/result"

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
