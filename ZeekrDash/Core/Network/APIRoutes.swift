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

    /// 车辆位置（坐标 + 地址）。
    ///
    /// 坐标由服务端向极氪网关取，并已按 `marsCoordinates` 转成 **GCJ-02**；
    /// 地址由服务端转腾讯位置服务获得（key 只在服务端，客户端看不到）。
    static let vehicleLocation = "/api/vehicle/location"
    /// 位置卡的地图缩略图（PNG/JPEG）。由服务端代取，**不要**在这里拼腾讯的 URL。
    static let vehicleLocationMap = "/api/vehicle/location/map.png"

    // 行程与能耗
    static let trips          = "/api/trips"
    static let energyTrend    = "/api/energy/trend"
    /// 官方「行程与能耗」统计：`?scope=month`（本月）/ `?days=7`（近 N 天）/ `?yearMonth=2026-09`
    static let tripsEnergy    = "/api/trips/energy"
    /// 可选月份清单（官方 existingMonth）
    static let tripsEnergyMonths = "/api/trips/energy/months"

    // 充电消费
    static let chargesSummary = "/api/charges/summary"
    static let chargesRecords = "/api/charges/records"
    static let chargesImport  = "/api/charges/import"

    // 附近充电站
    //
    // 另开前缀而不是挂在 charges 下的原因：`/api/charges` 是**消费账单**域
    // （本地导入的支付宝 / 微信账单），与"附近有哪些充电站"完全是两回事。
    /// 附近充电站（站点 + 电价，服务端两跳合并）。
    ///
    /// 参数 `lat` / `lng` 来自手机定位；`limit` 取前 N 个（服务端按距离升序）。
    /// 坐标不会经由此接口转发给第三方 —— 那是服务端的隐私边界。
    static let stationsNearby = "/api/stations/nearby"

    // 认证
    static let authSendCode   = "/api/auth/sendCode"
    static let authVerifyCode = "/api/auth/verifyCode"
    static let authStatus     = "/api/auth/status"
    static let authLogout     = "/api/auth/logout"

    // 诊断
    static let health         = "/api/health"
}
