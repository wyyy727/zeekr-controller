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
    /// 车门开启状态（按位置）。
    ///
    /// **字典的值必须可选**：服务端在拿不到某个车门状态时返回 `null`，
    /// 而 Swift 的 `Dictionary` 解码用的是 `decode` 而非 `decodeIfPresent`，
    /// 值类型非可选时遇到 null 会抛 valueNotFound —— 那会让**整个
    /// VehicleStatus 解码失败**，live 模式彻底不可用（会静默回落模拟数据）。
    var doors: [String: Bool?]?
    /// 车窗开启状态（按位置）。值可为 null，语义是"未知"而非"关着"。
    ///
    /// 服务端目前恒返回空（网关的车窗字段名尚未确认，见
    /// docs/真机验证清单.md），首页据此显示「未知」而不是默认成「已关」。
    var windows: [String: Bool?]?
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

    // MARK: 胎温（单位 ℃）
    //
    // 真车实报字段为 `tyreTemp{Driver,Passenger,DriverRear,PassengerRear}`
    // （2026-10-16 实测取证，见 docs/真机验证清单.md）。服务端已归一化输出，
    // 此前 iOS 模型里根本没有这四个键 —— 真车胎温数据被静默丢弃。
    var tyreTempFrontLeft: Double?
    var tyreTempFrontRight: Double?
    var tyreTempRearLeft: Double?
    var tyreTempRearRight: Double?

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
        case tyreTempFrontLeft, tyreTempFrontRight, tyreTempRearLeft, tyreTempRearRight
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

// MARK: - 官方行程与能耗统计

/// 官方「行程与能耗」统计（`GET /api/trips/energy`，与 App「行程统计」页同源）。
///
/// 口径（服务端算法，改动前先确认）：
///   · **总电耗 = 动态 + 静态**（静态是空调、待机等非行驶消耗）；
///   · **平均动态电耗 = 动态 ÷ 里程**，只有它能和「动态电耗」相互验算；
///     只摆「总电耗 + 平均动态电耗」会让人一除就对不上。
struct DailyEnergy: Codable {
    var days: Int?
    var startDate: String?
    var endDate: String?
    var distanceKm: Double?
    var energyKwh: Double?
    var dynamicEnergyKwh: Double?
    /// 静态电耗（空调 / 待机等非行驶消耗）。**总电耗 = 动态 + 静态**，
    /// v2 汇总卡第 5 格要用它；服务端已返回，早期 iOS 模型漏了这个字段。
    var staticEnergyKwh: Double?
    var avgConsumption: Double?
    var avgDynamicConsumption: Double?
    var fastChargeCount: Int?
    var slowChargeCount: Int?
    var series: [DailyEnergyPoint]?
}

/// 逐日一项（服务端只返回有数据的日期，X 轴是不连续的）
struct DailyEnergyPoint: Codable, Identifiable {
    var id: String { date }
    var date: String
    var distanceKm: Double?
    var energyKwh: Double?
    var minutes: Int?
    var consumption: Double?
    /// 当日动态电耗（行驶）。与 `staticKwh` 相加等于 `energyKwh`，
    /// 供电耗柱「动态在下、静态在上」两段式渲染（HTML `v2BarBody()`）。
    var dynamicKwh: Double?
    /// 当日静态电耗（空调 / 待机 / 哨兵等）
    var staticKwh: Double?

    /// 图表 X 轴用的短标签：`2026-10-09` → `10-09`（与网页 `date.slice(5)` 一致）。
    ///
    /// Swift Charts 把 x 当**字符串类目**处理，传什么就原样标什么 ——
    /// 传全量日期，30 天的图每个刻度都挤着 `2026-xx-xx`，读不出哪天是哪天。
    /// 图表窗口最长 31 天，跨年时（12-28 … 01-05）MM-DD 依然唯一，不需要带年份。
    var shortDate: String {
        date.count >= 5 ? String(date.suffix(5)) : date
    }
}

/// 可选月份（官方 `mileageBaseInfo.existingMonth`）
struct EnergyMonth: Codable, Identifiable {
    var id: String { yearMonth }
    /// `currentMonth` 表示本月，其余形如 `2026-09`
    var yearMonth: String
    var label: String
}

struct EnergyMonths: Codable {
    var months: [EnergyMonth]?
    var monthMileageKm: Double?
    var monthEnergyKwh: Double?
}

/// 月份选择器的通用选项（行程页与充电页共用同一个滚轮弹窗）。
///
/// 只有两个字段：`yearMonth`（`currentMonth` 或 `2026-09`）与展示用的 `label`。
/// 两个页面的月份来源不同（行程来自官方接口、充电来自本地库），
/// 但"选哪个月"这件事完全一样，没必要各写一套滚轮。
struct MonthOption: Codable, Hashable, Identifiable {
    var id: String { yearMonth }
    var yearMonth: String
    var label: String
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
    /// 上述所有统计量共同的统计窗口（月数）。
    ///
    /// 服务端保证总额/笔数/月度/服务商分布都在**同一范围内**（最近 N 个月），
    /// 这个字段让界面能明确标注范围，而不是把"累计"和"近 N 月"混在一起。
    var windowMonths: Int?
    /// 按月汇总
    var monthly: [ChargeMonthlyStat]?
    /// 按服务商汇总
    var byProvider: [ChargeProviderStat]?

    enum CodingKeys: String, CodingKey {
        case totalAmount, totalEnergyKwh, totalCount, avgUnitPrice
        case windowMonths
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

    /// 图表 X 轴用的短标签：`2026-03` → `3 月`（与预览 spec 的 fmtMonth 一致）
    var shortMonth: String {
        let parts = month.split(separator: "-")
        guard parts.count == 2, let m = Int(parts[1]) else { return month }
        return "\(m) 月"
    }
}

/// 服务商维度统计
struct ChargeProviderStat: Codable, Identifiable {
    var id: String { provider?.rawValue ?? "other" }
    var provider: ChargeProvider?
    var amount: Double?
    var energyKwh: Double?
    var count: Int?

    /// 图表 Y 轴用的展示名，回落到「其他」
    var displayName: String { provider?.displayName ?? "其他" }
}

// MARK: - 充入电量（charge_sessions）

/// 一条充电流水（官方「充电记录」）。
///
/// `startTime` 用字符串而不是 `Date`：服务端按本地时间字符串存储与分组，
/// 转 `Date` 再转回来会引入时区偏移，月份切分就对不上了。
/// 界面只需要"哪天几点"，格式化交给 `ChargeSession` 自己的展示属性。
struct ChargeSession: Codable, Identifiable {
    /// ⚠️ 不要用 `UUID().uuidString` 兜底：`id` 每次求值都是新值，
    /// SwiftUI 会认为"每帧都是另一行"，动画抖动、@State 丢失、分隔线恒真。
    /// 用已有字段拼一个稳定键即可。
    var id: String { sessionId ?? "\(startTime ?? "")|\(energyKwh ?? 0)" }

    var sessionId: String?
    var startTime: String?
    var endTime: String?
    var durationMin: Double?
    var energyKwh: Double?
    /// `dc` / `ac` / `unknown`；上游有时给空名，别猜
    var chargeType: String?
    var stationName: String?
    var amount: Double?
    var amountSource: String?

    var isDC: Bool { chargeType == "dc" }
    var isAC: Bool { chargeType == "ac" }

    /// 官方记录里没有站点名，所以标题位写「直流快充 / 交流慢充」；
    /// 将来 OCR 补上站点名后这里会自动换成站点名。
    var kindText: String {
        if isDC { return "直流快充" }
        if isAC { return "交流慢充" }
        return "充电"
    }

    var titleText: String {
        if let stationName, !stationName.isEmpty { return "\(stationName) · \(kindText)" }
        return kindText
    }

    /// 单笔平均功率（kW）：总电量 ÷ 时长。
    /// 比"充了多久"更能说明桩的快慢 —— 同样 50 度，20 分钟和 3 小时是两个世界。
    var powerKw: Double? {
        guard let energyKwh, let durationMin, durationMin > 0 else { return nil }
        return energyKwh / (durationMin / 60)
    }

    /// 展示用时间：`2026-10-16 22:12:00` → `10-16 22:12`
    var shortTimeText: String {
        guard let startTime else { return "--" }
        let parts = startTime.split(separator: " ")
        guard parts.count >= 2 else { return startTime }
        let date = parts[0].split(separator: "-")
        let clock = parts[1].split(separator: ":")
        if date.count >= 3, clock.count >= 2 {
            return "\(date[1])-\(date[2]) \(clock[0]):\(clock[1])"
        }
        return startTime
    }
}

/// 单月汇总（与后端 `_summarize_month` 同一口径）。
///
/// 全部可选：真实侧任何一项都可能缺失（电量缺失、时长缺失、功率算不出来），
/// 做成非可选会让整页解码失败 —— 那不是"少一个数字"，而是整页空白。
struct ChargeMonthStat: Codable {
    var yearMonth: String?
    var label: String?
    /// 笔数，**含电量缺失的记录**（充了几次和充了多少度是两件事）
    var count: Int?
    var totalKwh: Double?
    var dcCount: Int?
    var dcKwh: Double?
    var acCount: Int?
    var acKwh: Double?
    var totalMinutes: Double?
    var avgKwh: Double?
    var avgMinutes: Double?
    var avgPowerKw: Double?

    // ── 金额：只统计有来源的真值，估算单独记，绝不混算 ──
    var amountTotal: Double?
    var amountCount: Int?
    var pricedKwh: Double?
    var unitPrice: Double?
    var unpricedCount: Int?
    var unpricedKwh: Double?
    var estimatedTotal: Double?
    var estimatedCount: Int?
    /// 配不上流水 / 有多条候选的金额笔数（待确认队列）
    var pendingPayments: Int?
    var unmatchedPayments: Int?

    var records: [ChargeSession]?
}

/// 月份清单里的一项（`GET /api/charges/months`）。
///
/// `avgMinutes` 是趋势图的第二根轴；没有流水的月份为 nil，
/// 折线在那里断开 —— 画成 0 会读成"这个月充得特别快"。
struct ChargeMonthOption: Codable, Identifiable {
    var id: String { yearMonth ?? UUID().uuidString }
    var yearMonth: String?
    var label: String?
    var count: Int?
    var kwh: Double?
    var avgMinutes: Double?
    /// 当月**已补录**金额（估算不计入）。前端把各月加起来就是「累计金额」。
    var amount: Double?
    var amountCount: Int?
    var dcCount: Int?
    var acCount: Int?
}

struct ChargeMonthsPayload: Codable {
    var months: [ChargeMonthOption]?
    var totalCount: Int?
    var totalKwh: Double?
    /// 所有可查月份的金额之和（服务端算好，前端不再遍历）
    var totalAmount: Double?
    var hasData: Bool?
}

struct ChargeSyncResult: Codable {
    var fetched: Int?
    var inserted: Int?
    var updated: Int?
    var total: Int?
    /// 模拟数据源下为 false：演示数据不落库（落了会污染真实数据）
    var persisted: Bool?
}

// MARK: - 充电金额补录（截图识别 / 手工）

/// 截图识别是否可用（服务端有没有配 DEEPSEEK_API_KEY）。
struct OcrStatus: Codable {
    var configured: Bool?
    var model: String?
}

/// 识别出来的一行金额。**不直接入库** —— 先给用户核对。
struct OcrRow: Codable, Identifiable {
    /// 稳定的行标识：时间 + 金额 + 电量 + 站点。
    ///
    /// **不要用 `UUID()`** —— 那样每次访问 `id` 都得到新值，`ForEach` 会把整行当新元素，
    /// 重建、丢状态、动画乱跳。用内容本身能区分小票的字段拼一个就够。
    var id: String {
        [
            startAt ?? "",
            amount.map { String(format: "%.2f", $0) } ?? "",
            energyKwh.map { String(format: "%.3f", $0) } ?? "",
            stationName ?? "",
        ].joined(separator: "|")
    }

    var amount: Double?
    var energyKwh: Double?
    var startAt: String?
    var endAt: String?
    var durationMin: Double?
    var stationName: String?
    var confidence: Double?
    /// 本地防幻觉校验没过（金额离谱、时间倒挂等）
    var needsReview: Bool?
    var reviewNote: String?
    var candidates: [OcrCandidate]?
}

/// 一笔金额可能对应的充电流水。
struct OcrCandidate: Codable, Identifiable {
    var id: String { sessionId ?? UUID().uuidString }
    var sessionId: String?
    var startTime: String?
    var energyKwh: Double?
    /// `strong`（电量 ±5% 且时间 ±10 分钟）/ `weak`（时间落在窗口内）
    var kind: String?
    var confidence: String?
    var deltaMin: Double?

    var kindText: String {
        switch kind {
        case "strong": return "电量与时间都对得上"
        case "weak":   return "时间接近"
        default:       return "候选"
        }
    }
}

struct OcrPayload: Codable {
    var type: String?
    var imageSha8: String?
    var rows: [OcrRow]?
}

/// 一笔金额证据（截图识别或手工录入的产物）。
struct ChargePayment: Codable, Identifiable {
    var id: String { paymentId ?? UUID().uuidString }
    var paymentId: String?
    var source: String?
    var paidAt: String?
    var amount: Double?
    var energyKwh: Double?
    var stationName: String?
    var status: String?          // matched / pending / unmatched
    /// 已绑定的充电流水（store 侧 LEFT JOIN 带出，界面据此给「解绑」入口）
    var sessionId: String?
    var candidates: [OcrCandidate]?

    var isMatched: Bool { status == "matched" }
}

struct ChargePaymentsPayload: Codable {
    var payments: [ChargePayment]?
    var counts: [String: Int]?
}

// MARK: - 附近充电站

/// 附近充电站列表（`GET /api/stations/nearby` 的 `data`）
///
/// 数据由服务端**两跳合并**而来：极氪网关给坐标与枪数，第三方（浩汉）网关
/// 给站名、地址与电价。iOS 侧既不接触签名也不接触渠道号 —— 那些都在服务端，
/// 而且**用户坐标只发给极氪自己的网关**，服务端转给第三方的只有 `stationId`。
///
/// 除 `stationId` 外的字段一律可选：真实侧的站点**可能没有站名、没有价格**
/// （第三方网关没补上），把它们做成非可选会让解码直接失败 —— 那不是"少一个
/// 字段"，而是这一批站点整体消失。
struct NearbyStations: Codable {
    /// 视野内的站点总数（可能大于 `stations.count` —— 后者是取过价的前 N 个）
    var total: Int? = nil
    var count: Int? = nil
    /// 下一页该从哪个游标开始。
    ///
    /// **必须用服务端给的值**，不能用 `stations.count` 推算：带价格类筛选时，
    /// 中间被扫描掉、不符合条件的候选不返回，游标会大于已加载条数，
    /// 自己推算就会重复请求同一段。
    var nextOffset: Int? = nil
    /// 服务端明确告知还有没有下一页（比 `count < total` 可靠）
    var hasMore: Bool? = nil
    /// 用了"必须先取价才能判断"的筛选（停车免费）—— 此时 `total` 只是候选数，
    /// 不是匹配总数，界面不能拿它当分母。
    var priceFilterApplied: Bool? = nil
    /// 第三方价格服务是否可用
    var priceAvailable: Bool? = nil
    var stations: [ChargingStation]? = nil

    /// 显式判 `!= false`：后端不返回该字段时按"可用"处理。
    ///
    /// 这与「单个站点没有价格」是两件事，别混 —— 前者要提示"价格服务不可用"，
    /// 后者只显示「价格 --」。
    var isPriceAvailable: Bool { priceAvailable != false }
}

// MARK: - 当地气温

/// 车辆所在地的实时天气（`GET /api/vehicle/weather`）。
///
/// ⚠️ 界面上的标签是**「当地气温」**，不是「车外温度」：
/// 车端 `climateStatus.exteriorTemp` 实测非空率 0/15（这版固件不上报），
/// 所以这个数是按车辆位置查来的天气。暴晒 / 地下车库时两者能差十几度 ——
/// 标成"车外温度"就是谎报。
///
/// 取不到时 `available` 为 false（服务端不会把它当错误抛），界面显示 `--`，
/// **不要用 0℃ 顶替**（0℃ 是具体气温，会被当成真的）。
struct WeatherInfo: Codable {
    var available: Bool? = nil
    /// 气温 ℃。用 `Double` 而不是 `Int`：上游文档是 number，
    /// 一旦给 `22.5` 或字符串，`Int?` 会让**整个** `WeatherInfo` 解码失败
    /// （连 available 一起丢），界面永远显示 `--`。
    var temperature: Double? = nil
    /// 天气现象，如「多云」「小雨」
    var weather: String? = nil
    var humidity: Double? = nil
    var windDirection: String? = nil
    var windPower: String? = nil
    /// 行政区，界面上不展示，排障时看
    var city: String? = nil
    var district: String? = nil
    /// 上游观测时间
    var updateTime: String? = nil
}

// MARK: - 车辆位置

/// 车辆位置（`GET /api/vehicle/location`）。
///
/// **这不是实时位置**：车静止时网关不更新坐标，`reportedAt` 可能滞后几十分钟。
/// 界面上必须把上报时间显示出来，否则会被当成"车现在就在这"。
///
/// 坐标已经是 **GCJ-02**（服务端按网关的 `marsCoordinates` 标志转好了），
/// 可以直接给地图用 —— **客户端不要再做任何坐标转换**。
struct VehicleLocation: Codable {
    /// 网关有没有给出坐标。false 时看 `reason`
    var available: Bool? = nil
    var lat: Double? = nil
    var lng: Double? = nil
    /// 车上报时间（服务端原样透传的字符串，可能形如 `2026-10-19 10:48:21`）
    var reportedAt: String? = nil
    /// 没有坐标时的原因（如「车辆尚未上报位置」）
    var reason: String? = nil
    /// 服务端配了腾讯地图 key，前端才可以去请求缩略图
    var mapAvailable: Bool? = nil
    /// 地址是否来自本地缓存（true = 这次没有把坐标发给第三方）
    var addressFromCache: Bool? = nil
    var address: LocationAddress? = nil

    var hasCoordinate: Bool { available == true && lat != nil && lng != nil }

    // 曾有 `coordinateText`（"30.123456, 120.123456"）供位置卡展示，已删除：
    // 经纬度对人没有信息量，判断"车在哪"只能靠地址与地图，
    // 把精确坐标摆在屏幕上属于多余暴露。坐标本身仍由 lat/lng 提供给地图。

    /// 卡片主文案：优先「好认的地名」，再退回标准地址。
    ///
    /// 与网页一致（`address.recommend || address.address`）——
    /// `recommend` 是「XX 广场」这种描述，比「省市区路门牌」更好读。
    var displayAddress: String? {
        guard let address else { return nil }
        let recommend = address.recommend?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let recommend, !recommend.isEmpty { return recommend }
        let standard = address.address?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (standard?.isEmpty == false) ? standard : nil
    }

    /// 补充用的标准地址（与主文案重复时不显示）
    var secondaryAddress: String? {
        guard let address, let title = displayAddress else { return nil }
        let standard = address.address?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let standard, !standard.isEmpty, standard != title else { return nil }
        return standard
    }
}

/// 逆地理编码结果（服务端精简后的字段）
struct LocationAddress: Codable {
    var address: String? = nil
    var recommend: String? = nil
    var province: String? = nil
    var city: String? = nil
    var district: String? = nil
    var street: String? = nil
}

/// 单个充电站
struct ChargingStation: Codable, Identifiable {
    var id: String { stationId }
    var stationId: String
    /// 站名由第三方网关补；取不到时为 nil（界面显示「未命名站点」）
    var name: String? = nil
    var address: String? = nil
    var lat: Double? = nil
    var lng: Double? = nil
    /// 距当前位置 km（服务端算，气泡接口本身不给距离也不按距离排序）
    var distanceKm: Double? = nil
    var score: Double? = nil
    var tags: [String]? = nil
    /// 极氪自营
    var selfOperate: Bool? = nil
    var marketingPrice: Bool? = nil
    /// 可用枪 / 总枪
    var availableCount: Int? = nil
    var totalCount: Int? = nil
    /// 交流（慢充）/ 直流（快充）枪总数
    var acCount: Int? = nil
    var dcCount: Int? = nil
    /// 分功率的可用数（上游拼法就是 `ableXxx`）
    var ableAcCount: Int? = nil
    var ableDcCount: Int? = nil
    var stationStatus: Int? = nil
    var price: StationPrice? = nil
}

/// 站点电价
struct StationPrice: Codable {
    /// 当前时段总价（元/度）—— 界面上那个大数字
    var totalPrice: Double? = nil
    var feeElectric: Double? = nil
    var serviceFee: Double? = nil
    /// 当前所处时段，如 "00:00-06:00"；分时电价靠它指认"现在"
    var currentPeriod: String? = nil
    /// 分时电价表（单一时段站点长度为 1，尖峰平谷站点会有多段）
    var periods: [PricePeriod]? = nil
    var parkingFee: String? = nil
    var parkFree: Bool? = nil
    var holdFee: Bool? = nil
    var feeDesc: String? = nil

    enum CodingKeys: String, CodingKey {
        case totalPrice, feeElectric, serviceFee, currentPeriod, periods
        case parkingFee, parkFree, holdFee, feeDesc
    }

    /// 手写这个成员构造器是为了**让演示数据能只写关心的字段** ——
    /// 一旦有了下面的 `init(from:)`，编译器就不再合成成员构造器了。
    init(
        totalPrice: Double? = nil,
        feeElectric: Double? = nil,
        serviceFee: Double? = nil,
        currentPeriod: String? = nil,
        periods: [PricePeriod]? = nil,
        parkingFee: String? = nil,
        parkFree: Bool? = nil,
        holdFee: Bool? = nil,
        feeDesc: String? = nil
    ) {
        self.totalPrice = totalPrice
        self.feeElectric = feeElectric
        self.serviceFee = serviceFee
        self.currentPeriod = currentPeriod
        self.periods = periods
        self.parkingFee = parkingFee
        self.parkFree = parkFree
        self.holdFee = holdFee
        self.feeDesc = feeDesc
    }

    /// 手写解码只有一处理由：`parkingFee` 是服务端**原样透传**的上游字段，
    /// 类型是字符串还是数字并不固定。若按 `String` 硬解，上游给数字时会让
    /// 整个 `StationPrice` 解码失败 —— 那不是"少一个字段"，而是**这个站连
    /// 价格一起没了**，最后表现为整页都没有价格。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        totalPrice = try c.decodeIfPresent(Double.self, forKey: .totalPrice)
        feeElectric = try c.decodeIfPresent(Double.self, forKey: .feeElectric)
        serviceFee = try c.decodeIfPresent(Double.self, forKey: .serviceFee)
        currentPeriod = try c.decodeIfPresent(String.self, forKey: .currentPeriod)
        periods = try c.decodeIfPresent([PricePeriod].self, forKey: .periods)
        parkFree = try c.decodeIfPresent(Bool.self, forKey: .parkFree)
        holdFee = try c.decodeIfPresent(Bool.self, forKey: .holdFee)
        feeDesc = try c.decodeIfPresent(String.self, forKey: .feeDesc)

        if let text = try? c.decodeIfPresent(String.self, forKey: .parkingFee) {
            parkingFee = text
        } else if let number = try? c.decodeIfPresent(Double.self, forKey: .parkingFee) {
            // 数字型停车费不带单位 —— 上游没给单位，这里不替它编一个
            parkingFee = String(format: "%g", number)
        } else {
            parkingFee = nil
        }
    }
}

/// 分时电价的一行
struct PricePeriod: Codable {
    var timeFrame: String? = nil
    var electric: Double? = nil
    var service: Double? = nil
    var total: Double? = nil

    /// 是否为"当前所处时段"。
    ///
    /// **必须指认出来** —— 用户看这张卡就是为了知道"现在充多少钱"，
    /// 把多段电价平铺而不标出当前段，等于让他自己算。
    func isCurrent(_ currentPeriod: String?) -> Bool {
        guard let currentPeriod, !currentPeriod.isEmpty,
              let timeFrame, !timeFrame.isEmpty else { return false }
        return timeFrame == currentPeriod
    }
}

// MARK: - 附近充电站的展示派生值

extension ChargingStation {

    var displayName: String {
        if let name, !name.isEmpty { return name }
        return "未命名站点"
    }

    /// 是否有可用的当前价格。
    ///
    /// 与「免费」无关：没有价格就是没有价格，界面显示「价格 --」，
    /// **绝不显示 0** —— 把"查不到"画成"不要钱"是会被当成真事的。
    var hasPrice: Bool { price?.totalPrice != nil }

    var distanceText: String {
        guard let distanceKm else { return "--" }
        return String(format: "%.2f km", distanceKm)
    }

    /// 枪数摘要，按快充分开展示。
    ///
    /// 上游没给总枪数时**不显示 0/x** ——「0 个可用」和「不知道几个可用」
    /// 是两回事，前者会让人白白放弃一个站。
    var gunTexts: [String] {
        var items: [String] = []
        if let dc = dcCount, dc > 0 {
            items.append("快充 \(text(ableDcCount))/\(dc)")
        }
        if let ac = acCount, ac > 0 {
            items.append("慢充 \(text(ableAcCount))/\(ac)")
        }
        if items.isEmpty, let total = totalCount, total > 0 {
            items.append("可用 \(text(availableCount))/\(total)")
        }
        return items
    }

    /// 有枪但全满（用于把枪数标成警示色）
    var isFull: Bool {
        guard let total = totalCount, total > 0 else { return false }
        return (availableCount ?? 0) == 0
    }

    var scoreText: String? {
        guard let score, score > 0 else { return nil }
        return String(format: "%.1f", score)
    }

    private func text(_ value: Int?) -> String {
        guard let value else { return "--" }
        return String(value)
    }
}

extension StationPrice {

    var parkingText: String? {
        guard let parkingFee, !parkingFee.isEmpty else { return nil }
        return parkFree == true ? "\(parkingFee)（免费）" : parkingFee
    }
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

/// 车辆权限包 + 能力集（`GET /api/vehicle/capability`）。
///
/// 服务端的数据来自官方 `/ms-app-bff/api/1.0/permissions`（2026-10-16 真车实测），
/// 它归约成两层：
///   · `permissions` —— 原始权限包 ID（如 `charge-manage` / `vehicle-defence`），
///     设置页据此如实展示「这台车开通了什么」；
///   · `capabilities` —— 「功能 → 是否可用」的结论，供车控面板裁剪按钮。
///
/// `capabilities` 为 nil 表示**服务端没拿到**（网关没回或解析失败）——
/// 此时界面按「全部支持」显示，绝不隐藏按钮；只有明确 `false` 的能力才隐藏。
/// 这与 `preview/index.html` 的 `cap()` 规则一致。
///
/// 注意：服务端**只对「服务类」功能下判断**（充电管理 / 车辆守卫 / 行程…）。
/// 硬件能力（胎压 / 空调 / 车窗 / 门锁）不会出现在 `capabilities` 里 ——
/// 权限接口不回答硬件问题，拿它隐藏硬件按钮就是臆测。
/// 预约充电计划（`/api/vehicle/capability` 的 `chargePlan` 字段）。
///
/// **为什么手写解码**：后端是把上游字段原样透传的（`pick("targetSoc", "socLimit",
/// "chargeLimit", ...)`），`targetSoc` 可能是数字 `90` 也可能是字符串 `"90"`。
/// 如果按 `Double` 硬解，遇到字符串会让**整个 `VehicleCapabilities` 解码失败** ——
/// 不是少一个字段，而是能力集全丢、按钮全部回到"全显示"。
/// 所以这里逐字段用 `try?`：解不出来就是 nil，绝不让它抛出去。
struct ChargePlan: Codable {
    var enabled: Bool?
    var startTime: String?
    var endTime: String?
    var targetSoc: Double?
    var mode: String?

    enum CodingKeys: String, CodingKey {
        case enabled, startTime, endTime, targetSoc, mode
    }

    init(
        enabled: Bool? = nil,
        startTime: String? = nil,
        endTime: String? = nil,
        targetSoc: Double? = nil,
        mode: String? = nil
    ) {
        self.enabled = enabled
        self.startTime = startTime
        self.endTime = endTime
        self.targetSoc = targetSoc
        self.mode = mode
    }

    init(from decoder: Decoder) throws {
        // container 取不到（不是 JSON 对象）也不抛：整块当"没有计划"处理，
        // 因为这张卡是附加信息，不值得让它连累能力集。
        let container = try? decoder.container(keyedBy: CodingKeys.self)

        enabled = Self.decode(Bool.self, container, .enabled)
        startTime = Self.decode(String.self, container, .startTime)
        endTime = Self.decode(String.self, container, .endTime)
        mode = Self.decode(String.self, container, .mode)

        // targetSoc 上游可能给 90 也可能给 "90"，两种都试；都不成就是 nil
        if let number = Self.decode(Double.self, container, .targetSoc) {
            targetSoc = number
        } else if let text = Self.decode(String.self, container, .targetSoc) {
            targetSoc = Double(text)
        } else {
            targetSoc = nil
        }
    }

    /// 逐字段"尽力解码"：取不到或类型不符就返回 nil，绝不抛。
    ///
    /// 不能直接写 `try? container?.decodeIfPresent(...)` —— 可选链 + `try?`
    /// 会把结果包成 `T???`，赋值给 `T?` 编译不过。这里把展平逻辑收在一处。
    private static func decode<T: Decodable>(
        _ type: T.Type,
        _ container: KeyedDecodingContainer<CodingKeys>?,
        _ key: CodingKeys
    ) -> T? {
        guard let container else { return nil }
        return (try? container.decodeIfPresent(type, forKey: key)) ?? nil
    }

    /// 有没有可展示的内容（全空时不渲染这张卡）
    var hasContent: Bool {
        enabled != nil || startTime != nil || endTime != nil || targetSoc != nil
    }
}

/// 车辆能力集（`GET /api/vehicle/capability`）
struct VehicleCapabilities: Codable {
    /// 原始权限包 ID。为空数组 = 服务端确认该车无权限（与 nil「没取到」不同）。
    var permissions: [String]?
    var capabilities: [String: Bool]?
    var verified: Bool?
    /// 预约充电计划。取不到时为 nil，界面不渲染该卡。
    var chargePlan: ChargePlan?
}

/// 车控指令的**车端执行结果**（`GET /api/vehicle/command/result`）
struct CommandExecutionResult: Codable {
    /// `pending` / `done` / `failed`
    var status: String?
    var message: String?

    var isPending: Bool { (status ?? "pending") == "pending" }
    var isDone: Bool { status == "done" }
    var isFailed: Bool { status == "failed" }
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
    /// 支持多种日期格式的解码器（兼容 ISO8601 与常见变体）。
    ///
    /// ⚠️ **每次访问都返回一个新实例** —— 这不是浪费，是必须的：
    /// `JSONDecoder` 本身不是线程安全的，而 `APIClient` 会被多个并发请求共用。
    /// 若把它存成 `let` 共享，两件事同时出错：
    /// ① 解码器被并发 `decode` 撞车；② 它闭包里捕获的 `DateFormatter`
    /// 同样不是线程安全的（内部有可变缓存）。
    /// 因此 `APIClient` 必须在**每次解码时**现取一个，不能缓存。
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
