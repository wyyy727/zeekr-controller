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
    /// 车辆所在地的实时天气。
    ///
    /// 只用来顶「当地气温」那一格：车端 `climateStatus.exteriorTemp` 实测恒为空
    /// （这版固件不上报），所以这个数**不是车外实测温度**，界面标签必须写「当地气温」。
    /// 坐标不出现在入参里 —— 服务端自己向极氪取，并复用位置接口的 60 秒缓存。
    static let vehicleWeather = "/api/vehicle/weather"

    // 行程与能耗
    static let trips          = "/api/trips"
    static let energyTrend    = "/api/energy/trend"
    /// 官方「行程与能耗」统计：`?scope=month`（本月）/ `?days=7`（近 N 天）/ `?yearMonth=2026-09`
    static let tripsEnergy    = "/api/trips/energy"
    /// 可选月份清单（官方 existingMonth）
    static let tripsEnergyMonths = "/api/trips/energy/months"

    // 充电消费（历史遗留：本地导入的支付宝 / 微信账单）
    static let chargesSummary = "/api/charges/summary"
    static let chargesRecords = "/api/charges/records"
    static let chargesImport  = "/api/charges/import"

    // 充入电量（官方「充电记录」，充电页主线）
    //
    // 与上面三个是**两套完全不同的数据**：这里是车端流水（只有电量、没有金额），
    // 上面是支付账单（有金额、实测 0 行）。接口前缀相同只是历史原因。
    /// 可查月份清单（含每月电量与每次充电时长），供选择器与趋势图使用
    static let chargeMonths   = "/api/charges/months"
    /// 单月充电流水（`?yearMonth=2026-09`，默认本月）。**只读本地库**，不打网关
    static let chargeSessions = "/api/charges/sessions"
    /// 从官方同步充电流水（幂等，服务端有 10 秒冷却）
    static let chargeSync     = "/api/charges/sync"
    /// 截图识别是否可用
    static let chargeOcrStatus = "/api/charges/receipts/status"
    /// 上传一张「补能订单」截图 → 返回待确认的金额行（不入库）
    static let chargeOcr      = "/api/charges/receipts/ocr"
    /// 把核对过的识别结果入库
    static let chargeOcrCommit = "/api/charges/receipts/commit"
    /// 手工补录一笔金额
    static let chargePaymentManual = "/api/charges/payments/manual"
    /// 金额证据列表（未配对的会附上候选）
    static let chargePayments = "/api/charges/payments"
    /// 指定 / 解除某笔金额属于哪次充电
    static func chargePaymentLink(_ paymentId: String) -> String {
        "/api/charges/payments/\(paymentId)/link"
    }

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
