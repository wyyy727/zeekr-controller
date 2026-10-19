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
    /// 第三方价格服务是否可用
    var priceAvailable: Bool? = nil
    var stations: [ChargingStation]? = nil

    /// 显式判 `!= false`：后端不返回该字段时按"可用"处理。
    ///
    /// 这与「单个站点没有价格」是两件事，别混 —— 前者要提示"价格服务不可用"，
    /// 后者只显示「价格 --」。
    var isPriceAvailable: Bool { priceAvailable != false }
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

    /// 坐标文本，如 `30.123456, 120.123456`
    var coordinateText: String? {
        guard let lat, let lng else { return nil }
        return String(format: "%.6f, %.6f", lat, lng)
    }

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
struct VehicleCapabilities: Codable {
    /// 原始权限包 ID。为空数组 = 服务端确认该车无权限（与 nil「没取到」不同）。
    var permissions: [String]?
    var capabilities: [String: Bool]?
    var verified: Bool?
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
