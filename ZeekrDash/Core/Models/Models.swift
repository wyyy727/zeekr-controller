//
//  Models.swift
//  ZeekrDash
//
//  领域模型 —— iOS 端与 Python 服务端的数据契约
//

import Foundation

// MARK: - 车辆状态

/// 车辆实时状态
struct VehicleStatus: Codable, Identifiable {
    var id: String { vin }

    /// 车辆识别码
    let vin: String
    /// 车辆昵称
    var nickname: String?
    /// 车牌号
    var plateNo: String?
    /// 车型显示名（如「极氪 001」）
    var modelName: String?

    // MARK: 电量与续航
    /// 动力电池电量百分比 0–100
    var soc: Double?
    /// 剩余续航 km
    var rangeKm: Double?
    /// 总里程 km
    var odometerKm: Double?
    /// 12V 电瓶电压 V
    var battery12vVoltage: Double?
    /// 12V 电瓶电量 %
    var battery12vLevel: Double?

    // MARK: 充电
    /// 是否充电中
    var isCharging: Bool?
    /// 是否已插枪
    var isPlugged: Bool?
    /// 充电功率 kW
    var chargePowerKw: Double?
    /// 充电电压 V
    var chargeVoltage: Double?
    /// 充电电流 A
    var chargeCurrent: Double?
    /// 预计充满时间（分钟）
    var minutesToFull: Double?
    /// 充电上限 %
    var chargeLimit: Double?

    // MARK: 门锁与车身
    /// 车门是否已锁
    var isLocked: Bool?
    /// 车门开启状态（按位置）
    var doors: [String: Bool]?
    /// 车窗开启状态
    var windows: [String: Bool]?
    /// 后备箱是否开启
    var trunkOpen: Bool?
    /// 前机盖是否开启
    var frunkOpen: Bool?

    // MARK: 胎压（单位 kPa）
    var tyreFrontLeft: Double?
    var tyreFrontRight: Double?
    var tyreRearLeft: Double?
    var tyreRearRight: Double?
    /// 胎压告警
    var tyreWarning: Bool?

    // MARK: 空调
    /// 空调是否开启
    var climateOn: Bool?
    /// 空调设定温度 ℃
    var climateTargetTemp: Double?
    /// 车内温度 ℃
    var interiorTemp: Double?
    /// 车外温度 ℃
    var exteriorTemp: Double?

    // MARK: 位置
    var latitude: Double?
    var longitude: Double?
    /// 定位是否可信
    var positionTrusted: Bool?

    // MARK: 其他
    /// 车速 km/h
    var speedKmh: Double?
    /// 平均能耗 kWh/100km
    var avgConsumption: Double?
    /// 保养剩余里程 km
    var serviceDistanceKm: Double?
    /// 保养剩余天数
    var serviceDays: Int?
    /// 数据更新时间
    var updatedAt: Date?

    /// 最后更新时间戳（服务端返回的 ISO8601 字符串）
    var lastUpdateTs: String?

    enum CodingKeys: String, CodingKey {
        case vin, nickname, plateNo, modelName
        case soc, rangeKm, odometerKm
        case battery12vVoltage = "battery12vVoltage"
        case battery12vLevel = "battery12vLevel"
        case isCharging, isPlugged, chargePowerKw, chargeVoltage, chargeCurrent
        case minutesToFull, chargeLimit
        case isLocked, doors, windows, trunkOpen, frunkOpen
        case tyreFrontLeft, tyreFrontRight, tyreRearLeft, tyreRearRight, tyreWarning
        case climateOn, climateTargetTemp, interiorTemp, exteriorTemp
        case latitude, longitude, positionTrusted
        case speedKmh, avgConsumption, serviceDistanceKm, serviceDays
        case updatedAt, lastUpdateTs
    }
}

// MARK: - 行程

/// 单次行程记录
struct Trip: Codable, Identifiable {
    var id: String { tripId ?? UUID().uuidString }

    var tripId: String?
    /// 开始时间
    var startTime: Date?
    /// 结束时间
    var endTime: Date?
    /// 行驶距离 km
    var distanceKm: Double?
    /// 消耗电量 kWh
    var energyKwh: Double?
    /// 平均车速 km/h
    var avgSpeedKmh: Double?
    /// 最高车速 km/h
    var maxSpeedKmh: Double?
    /// 百公里能耗 kWh/100km
    var consumption: Double?
    /// 起点描述
    var startPlace: String?
    /// 终点描述
    var endPlace: String?
    /// 行程时长（分钟）
    var durationMinutes: Double?

    enum CodingKeys: String, CodingKey {
        case tripId, startTime, endTime, distanceKm, energyKwh
        case avgSpeedKmh, maxSpeedKmh, consumption
        case startPlace, endPlace, durationMinutes
    }
}

// MARK: - 能耗趋势

/// 能耗趋势数据点
struct EnergyTrendPoint: Codable, Identifiable {
    var id: String { date }
    /// 日期 YYYY-MM-DD
    let date: String
    /// 当日行驶里程 km
    var distanceKm: Double?
    /// 当日能耗 kWh
    var energyKwh: Double?
    /// 当日百公里能耗 kWh/100km
    var consumption: Double?
    /// 当日行程次数（Chart 用）
    var tripCount: Int?
}

// MARK: - 充电消费

/// 充电服务商
enum ChargeProvider: String, Codable, CaseIterable {
    case zeekr      = "zeekr"
    case starCharge = "starCharge"
    case teld       = "teld"
    case stateGrid  = "stateGrid"
    case eCharging  = "eCharging"
    case other      = "other"

    var displayName: String {
        switch self {
        case .zeekr:      return "极氪极充"
        case .starCharge: return "星星充电"
        case .teld:       return "特来电"
        case .stateGrid:  return "国家电网"
        case .eCharging:  return "e充电"
        case .other:      return "其他"
        }
    }
}

/// 支付渠道
enum PayChannel: String, Codable {
    case alipay  = "alipay"
    case wechat  = "wechat"
    case zeekr   = "zeekr"
    case other   = "other"

    var displayName: String {
        switch self {
        case .alipay: return "支付宝"
        case .wechat: return "微信"
        case .zeekr:  return "极氪"
        case .other:  return "其他"
        }
    }
}

/// 单笔充电消费记录
struct ChargeRecord: Codable, Identifiable {
    var id: String { recordId ?? UUID().uuidString }

    var recordId: String?
    /// 发生时间
    var timestamp: Date?
    /// 金额（元）
    var amount: Double?
    /// 充电量 kWh
    var energyKwh: Double?
    /// 服务商
    var provider: ChargeProvider?
    /// 支付渠道
    var channel: PayChannel?
    /// 商户原始名称（账单里的字样）
    var merchant: String?
    /// 站点名称
    var stationName: String?
    /// 单价 元/kWh
    var unitPrice: Double?
    /// 订单号
    var orderNo: String?

    enum CodingKeys: String, CodingKey {
        case recordId, timestamp, amount, energyKwh, provider, channel
        case merchant, stationName, unitPrice, orderNo
    }
}

/// 充电消费汇总
struct ChargeSummary: Codable {
    /// 统计区间总金额（元）
    var totalAmount: Double?
    /// 统计区间总电量 kWh
    var totalEnergyKwh: Double?
    /// 总笔数
    var totalCount: Int?
    /// 平均单价 元/kWh
    var avgUnitPrice: Double?
    /// 按月汇总
    var monthly: [ChargeMonthlyStat]?
    /// 按服务商汇总
    var byProvider: [ChargeProviderStat]?

    enum CodingKeys: String, CodingKey {
        case totalAmount, totalEnergyKwh, totalCount, avgUnitPrice
        case monthly, byProvider
    }
}

/// 月度充电统计
struct ChargeMonthlyStat: Codable, Identifiable {
    var id: String { month }
    /// 月份 YYYY-MM
    let month: String
    var amount: Double?
    var energyKwh: Double?
    var count: Int?
}

/// 服务商维度统计
struct ChargeProviderStat: Codable, Identifiable {
    var id: String { provider?.rawValue ?? "other" }
    var provider: ChargeProvider?
    var amount: Double?
    var energyKwh: Double?
    var count: Int?
}

// MARK: - 车控指令

/// 车控指令类型
///
/// 命名与服务端 `/api/vehicle/command` 的 `command` 字段一一对应。
/// 前 8 项为原有指令，其余为车控面板 15 按钮所需的补全项。
enum VehicleCommand: String, Codable, CaseIterable {
    // 门锁
    case lock       = "lock"
    case unlock     = "unlock"
    // 空调
    case climateOn  = "climateOn"
    case climateOff = "climateOff"
    // 远程操作 · 原有
    case flash      = "flash"
    case honk       = "honk"
    case chargeStart = "chargeStart"
    case chargeStop  = "chargeStop"
    // 车控 · 状态开关型
    case defrost    = "defrost"
    case wheelHeat  = "wheelHeat"
    case seatHeat   = "seatHeat"
    case ventSeat   = "ventSeat"
    // 远程操作 · 补全
    case closeWindows = "closeWindows"
    case sunshade     = "sunshade"
    case sentinel     = "sentinel"
    // 场景
    case tripPlan   = "tripPlan"
    case carFinder  = "carFinder"
    case refresh    = "refresh"

    var displayName: String {
        switch self {
        case .lock:         return "锁车"
        case .unlock:       return "解锁"
        case .climateOn:    return "开空调"
        case .climateOff:   return "关空调"
        case .flash:        return "闪灯"
        case .honk:         return "鸣笛"
        case .chargeStart:  return "开始充电"
        case .chargeStop:   return "结束充电"
        case .defrost:      return "前除霜"
        case .wheelHeat:    return "方向盘加热"
        case .seatHeat:     return "座椅加热"
        case .ventSeat:     return "座椅通风"
        case .closeWindows: return "关车窗"
        case .sunshade:     return "遮阳帘"
        case .sentinel:     return "哨兵模式"
        case .tripPlan:     return "出行规划"
        case .carFinder:    return "寻车"
        case .refresh:      return "立即刷新"
        }
    }

    var systemImage: String {
        switch self {
        case .lock:         return "lock.fill"
        case .unlock:       return "lock.open.fill"
        case .climateOn:    return "snowflake"
        case .climateOff:   return "snowflake"
        case .flash:        return "headlight.high.beam"
        case .honk:         return "speaker.wave.2"
        case .chargeStart:  return "bolt.fill"
        case .chargeStop:   return "bolt.slash.fill"
        case .defrost:      return "snowflake.circle"
        case .wheelHeat:    return "steeringwheel"
        case .seatHeat:     return "car.seat.forward.and.heat.waves"
        case .ventSeat:     return "wind"
        case .closeWindows: return "car.window.left"
        case .sunshade:     return "sun.max"
        case .sentinel:     return "shield.lefthalf.filled"
        case .tripPlan:     return "point.topleft.down.to.point.bottomright.curvepath"
        case .carFinder:    return "location.circle"
        case .refresh:      return "arrow.clockwise"
        }
    }

    /// 是否为状态开关型指令（由车况回读驱动状态）
    var isToggle: Bool {
        switch self {
        case .lock, .unlock, .climateOn, .climateOff,
             .defrost, .wheelHeat, .seatHeat, .ventSeat, .sentinel:
            return true
        default:
            return false
        }
    }
}

/// 指令下发结果
struct CommandResult: Codable {
    var success: Bool
    var message: String?
    var command: String?
}

// MARK: - 通用响应包装

/// 服务端统一响应
struct APIResponse<T: Codable>: Codable {
    var success: Bool
    var data: T?
    var error: String?
}

// MARK: - 日期解析辅助

extension JSONDecoder {
    /// 支持多种日期格式的解码器（兼容 ISO8601 与常见变体）
    static var zeekr: JSONDecoder {
        let decoder = JSONDecoder()
        let iso = ISO8601DateFormatter()
        let isoFrac = ISO8601DateFormatter()
        isoFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let plain = DateFormatter()
        plain.dateFormat = "yyyy-MM-dd HH:mm:ss"
        plain.locale = Locale(identifier: "en_US_POSIX")
        plain.timeZone = TimeZone(identifier: "Asia/Shanghai")

        let plainShort = DateFormatter()
        plainShort.dateFormat = "yyyy-MM-dd"
        plainShort.locale = Locale(identifier: "en_US_POSIX")
        plainShort.timeZone = TimeZone(identifier: "Asia/Shanghai")

        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()

            if let ts = try? container.decode(Double.self) {
                // 兼容秒 / 毫秒时间戳
                let seconds = ts > 1_000_000_000_000 ? ts / 1000 : ts
                return Date(timeIntervalSince1970: seconds)
            }
            let str = try container.decode(String.self)
            if let d = iso.date(from: str) { return d }
            if let d = isoFrac.date(from: str) { return d }
            if let d = plain.date(from: str) { return d }
            if let d = plainShort.date(from: str) { return d }

            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "无法解析日期: \(str)"
            )
        }
        return decoder
    }
}
