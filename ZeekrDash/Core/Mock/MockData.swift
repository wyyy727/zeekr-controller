//
//  MockData.swift
//  ZeekrDash
//
//  本地模拟数据源
//
//  用途：当「服务端地址」未配置或指向 localhost 时，App 不访问网络，
//  直接展示这里的数据，让界面在没有后端的情况下依然可完整预览。
//
//  设计约束：
//  - 数值与 preview/index.html 中的 MOCK 常量保持一致，两处同源，
//    避免「网页里看到的」和「App 里看到的」对不上。
//  - 修改本文件时，请同步修改 preview/index.html 的 MOCK 常量。
//

import Foundation

enum MockData {

    // MARK: - 车辆状态
    //
    // 对应 preview/index.html → MOCK.status

    static let vehicleStatus = VehicleStatus(
        vin: "L6TDEMOCK00000001",
        nickname: "焕新 001",
        plateNo: "沪A·D8821",
        modelName: "ZEEKR 001",

        // 电量与续航
        soc: 68,
        rangeKm: 510,
        odometerKm: 8642,
        battery12vVoltage: 13.2,
        battery12vLevel: 88,

        // 充电（静止未充电状态）
        isCharging: false,
        isPlugged: false,
        chargePowerKw: nil,
        chargeVoltage: nil,
        chargeCurrent: nil,
        minutesToFull: nil,
        chargeLimit: 90,

        // 门锁与车身
        isLocked: true,
        // 键名与服务端 live 侧一致（`frontLeft` 系列）。此前用 `driver`/`passenger`，
        // 与后端真车报文对不上 —— 一旦有界面按键名取值就会取到 nil。
        doors: [
            "frontLeft": false,
            "frontRight": false,
            "rearLeft": false,
            "rearRight": false,
        ],
        windows: [
            "frontLeft": false,
            "frontRight": false,
            "rearLeft": false,
            "rearRight": false,
        ],
        trunkOpen: false,
        frunkOpen: false,

        // 胎压（kPa）
        tyreFrontLeft: 250,
        tyreFrontRight: 248,
        tyreRearLeft: 252,
        tyreRearRight: 249,
        tyreWarning: false,
        // 胎温（℃），对应服务端 tyreTemp* 四个键
        tyreTempFrontLeft: 24,
        tyreTempFrontRight: 23,
        tyreTempRearLeft: 23,
        tyreTempRearRight: 22,

        // 空调
        climateOn: false,
        climateTargetTemp: 24,
        interiorTemp: 23.5,
        exteriorTemp: 26.5,

        // 位置（上海张江附近，仅用于展示）
        latitude: 31.2035,
        longitude: 121.5858,
        positionTrusted: true,

        // 其他
        speedKmh: 0,
        avgConsumption: 15.8,
        serviceDistanceKm: 4200
    )

    // MARK: - 车辆位置
    //
    // 对应 preview/index.html → MOCK.location，字段与 /api/vehicle/location 一致。
    // 地址一律带「演示」字样：模拟数据不该长得像真实地点。
    // `mapAvailable = false`：演示模式不联网，也就不该去请求地图图片。

    static let vehicleLocation = VehicleLocation(
        available: true,
        lat: 31.2035,
        lng: 121.5858,
        reportedAt: "2026-10-19 10:48:21",
        reason: nil,
        mapAvailable: false,
        addressFromCache: false,
        address: LocationAddress(
            address: "演示市演示区演示路 88 号",
            recommend: "演示园区 · 地下车库 B2",
            province: "演示省",
            city: "演示市",
            district: "演示区",
            street: "演示路"
        )
    )

    // MARK: - 行程记录
    //
    // 对应 preview/index.html → MOCK.trips
    // 以「今天」为基准回溯，保证列表里的日期始终贴近当前时间。

    static var trips: [Trip] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())

        /// 生成相对今天的日期（起点）
        func day(_ daysAgo: Int, hour: Int, minute: Int) -> Date {
            let d0 = cal.date(byAdding: .day, value: -daysAgo, to: today) ?? today
            return cal.date(bySettingHour: hour, minute: minute, second: 0, of: d0) ?? d0
        }

        return [
            Trip(tripId: "t-01", startTime: day(1, hour: 8, minute: 15),
                 distanceKm: 12.4, energyKwh: 2.10, consumption: 16.9,
                 startPlace: "家 · 锦绣江南", endPlace: "公司 · 张江高科",
                 durationMinutes: 28),

            Trip(tripId: "t-02", startTime: day(2, hour: 18, minute: 40),
                 distanceKm: 13.1, energyKwh: 1.90, consumption: 14.5,
                 startPlace: "公司 · 张江高科", endPlace: "家 · 锦绣江南",
                 durationMinutes: 32),

            Trip(tripId: "t-03", startTime: day(3, hour: 9, minute: 2),
                 distanceKm: 8.6, energyKwh: 1.40, consumption: 16.3,
                 startPlace: "家 · 锦绣江南", endPlace: "万象城",
                 durationMinutes: 22),

            Trip(tripId: "t-04", startTime: day(4, hour: 21, minute: 10),
                 distanceKm: 9.2, energyKwh: 1.30, consumption: 14.1,
                 startPlace: "万象城", endPlace: "家 · 锦绣江南",
                 durationMinutes: 25),

            Trip(tripId: "t-05", startTime: day(5, hour: 8, minute: 20),
                 distanceKm: 12.0, energyKwh: 2.00, consumption: 16.7,
                 startPlace: "家 · 锦绣江南", endPlace: "公司 · 张江高科",
                 durationMinutes: 30),

            Trip(tripId: "t-06", startTime: day(6, hour: 15, minute: 18),
                 distanceKm: 38.5, energyKwh: 6.10, consumption: 15.8,
                 startPlace: "家 · 锦绣江南", endPlace: "青浦奥特莱斯",
                 durationMinutes: 45),

            Trip(tripId: "t-07", startTime: day(6, hour: 19, minute: 52),
                 distanceKm: 39.2, energyKwh: 5.80, consumption: 14.8,
                 startPlace: "青浦奥特莱斯", endPlace: "家 · 锦绣江南",
                 durationMinutes: 48),

            Trip(tripId: "t-08", startTime: day(8, hour: 8, minute: 35),
                 distanceKm: 11.9, energyKwh: 2.00, consumption: 16.8,
                 startPlace: "家 · 锦绣江南", endPlace: "公司 · 张江高科",
                 durationMinutes: 27),

            Trip(tripId: "t-09", startTime: day(9, hour: 18, minute: 58),
                 distanceKm: 12.7, energyKwh: 1.80, consumption: 14.2,
                 startPlace: "公司 · 张江高科", endPlace: "家 · 锦绣江南",
                 durationMinutes: 31),

            Trip(tripId: "t-10", startTime: day(11, hour: 9, minute: 40),
                 distanceKm: 17.3, energyKwh: 2.60, consumption: 15.0,
                 startPlace: "家 · 锦绣江南", endPlace: "虹桥天地",
                 durationMinutes: 33),
        ]
    }

    // MARK: - 能耗趋势
    //
    // 对应 preview/index.html → MOCK.trend
    // 覆盖 90 天，界面按所选区间取尾部切片。

    static var energyTrend: [EnergyTrendPoint] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"

        // 基础波形：工作日通勤偏低、周末出行偏高，叠加轻微波动，贴近真实观感
        let base: [Double] = [
            16.9, 14.5, 16.3, 14.1, 16.7, 15.8, 14.8,
            16.8, 14.2, 15.0, 15.6, 14.4, 16.1, 15.3,
        ]

        return (0..<90).map { i in
            let daysAgo = 89 - i
            let d = cal.date(byAdding: .day, value: -daysAgo, to: today) ?? today
            let consumption = base[i % base.count] + Double((i % 5) - 2) * 0.13
            // 由能耗反推当日里程与电量，保证三者在界面上自洽
            let distance = 12.0 + Double(i % 7) * 2.6
            return EnergyTrendPoint(
                date: f.string(from: d),
                distanceKm: (distance * 10).rounded() / 10,
                energyKwh: ((distance * consumption / 100) * 100).rounded() / 100,
                consumption: (consumption * 100).rounded() / 100,
                tripCount: 1 + (i % 3)
            )
        }
    }

    // MARK: - 官方行程与能耗（/api/trips/energy）
    //
    // 对应 preview/index.html → mockEnergy()：数字自洽 ——
    // 总电耗 = 动态 + 静态，总÷里程 与 动态÷里程 都能对上卡片上的均耗。

    static func energyMonths() -> EnergyMonths {
        let cal = Calendar.current
        let now = Date()
        var list: [EnergyMonth] = [EnergyMonth(yearMonth: "currentMonth", label: "本月")]
        for i in 1...5 {
            guard let date = cal.date(byAdding: .month, value: -i, to: now) else { continue }
            let comps = cal.dateComponents([.year, .month], from: date)
            let year = comps.year ?? 1970
            let month = comps.month ?? 1
            list.append(EnergyMonth(
                yearMonth: String(format: "%04d-%02d", year, month),
                label: "\(year)年\(month)月"
            ))
        }
        return EnergyMonths(months: list, monthMileageKm: nil, monthEnergyKwh: nil)
    }

    /// 近 N 天
    static func dailyEnergy(days: Int) -> DailyEnergy {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let n = max(1, min(days, 31))
        let dates = (0..<n).compactMap { offset in
            cal.date(byAdding: .day, value: -(n - 1 - offset), to: today)
        }
        return buildDailyEnergy(dates: dates)
    }

    /// 历史整月（`yearMonth` 形如 `2026-09`）
    static func dailyEnergy(yearMonth: String) -> DailyEnergy {
        let cal = Calendar.current
        let parts = yearMonth.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 2,
              let first = cal.date(from: DateComponents(year: parts[0], month: parts[1], day: 1)),
              let range = cal.range(of: .day, in: .month, for: first) else {
            return dailyEnergy(days: 30)
        }
        let dates = range.compactMap { cal.date(byAdding: .day, value: $0 - 1, to: first) }
        return buildDailyEnergy(dates: dates)
    }

    private static func buildDailyEnergy(dates: [Date]) -> DailyEnergy {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let display = DateFormatter()
        display.dateFormat = "yyyy年MM月dd日"

        var series: [DailyEnergyPoint] = []
        var totalKm = 0.0
        var totalKwh = 0.0

        for (index, date) in dates.enumerated() {
            // 约五分之一的天数不动车
            if index % 5 == 3 { continue }
            let distance = 12.0 + Double(index % 7) * 5.5
            let energy = (distance * 0.2 * 100).rounded() / 100
            totalKm += distance
            totalKwh += energy
            series.append(DailyEnergyPoint(
                date: formatter.string(from: date),
                distanceKm: (distance * 10).rounded() / 10,
                energyKwh: energy,
                minutes: Int(distance * 1.35),
                consumption: 20.0
            ))
        }

        let dynamicKwh = (totalKwh * 0.9 * 100).rounded() / 100
        let avg = totalKm > 0 ? ((totalKwh / totalKm) * 1000).rounded() / 10 : 0
        let avgDynamic = totalKm > 0 ? ((dynamicKwh / totalKm) * 1000).rounded() / 10 : 0

        return DailyEnergy(
            days: dates.count,
            startDate: dates.first.map { display.string(from: $0) },
            endDate: dates.last.map { display.string(from: $0) },
            distanceKm: (totalKm * 10).rounded() / 10,
            energyKwh: (totalKwh * 100).rounded() / 100,
            dynamicEnergyKwh: dynamicKwh,
            avgConsumption: avg,
            avgDynamicConsumption: avgDynamic,
            fastChargeCount: max(1, dates.count / 5),
            slowChargeCount: 0,
            series: series
        )
    }

    // MARK: - 充电记录
    //
    // 对应 preview/index.html → MOCK.records（12 条，逐条对齐）
    // index.html 的记录只有 timestamp / amount / merchant / provider / channel，
    // 这里按「单价 ≈ 1.1~1.35 元/度」补齐 ChargeRecord 还需要的 energyKwh /
    // unitPrice / orderNo，使 App 与网页看到的是同一批账单。
    // 以「今天」为基准回溯，日期始终贴近当前时间。

    static var chargeRecords: [ChargeRecord] {
        // (距今几天, 时, 分, 金额, 服务商, 支付渠道, 站点名, 单价, 订单号尾号)
        let rows: [(Int, Int, Int, Double, ChargeProvider, PayChannel, String, Double, String)] = [
            (2,  21, 30, 38.50, .teld,       .wechat, "特来电-浦东世纪公园站", 1.20, "TD"),
            (4,  19, 42, 32.10, .zeekr,      .alipay, "极氪极充-万象城",       1.28, "ZK"),
            (6,  15, 20, 45.80, .starCharge, .wechat, "星星充电-青浦奥特莱斯", 1.12, "XC"),
            (9,  20, 15, 28.40, .eCharging,  .alipay, "小桔充电-虹桥枢纽",     1.18, "EC"),
            (11, 18, 55, 33.20, .stateGrid,  .wechat, "国家电网-e充电(静安)",  1.05, "SG"),
            (13, 22, 10, 41.60, .teld,       .alipay, "特来电-张江高科",       1.20, "TD"),
            (16, 19, 30, 36.90, .zeekr,      .wechat, "极氪极充-大宁",         1.28, "ZK"),
            (19, 20, 45, 29.70, .starCharge, .alipay, "星星充电-中山公园",     1.12, "XC"),
            (22, 21,  5, 31.20, .teld,       .wechat, "特来电-陆家嘴",         1.20, "TD"),
            (25, 18, 30, 27.40, .eCharging,  .alipay, "小桔充电-徐家汇",       1.18, "EC"),
            (28, 19, 50, 34.80, .stateGrid,  .wechat, "国家电网-e充电(浦东)",  1.05, "SG"),
            (31, 20, 20, 38.10, .zeekr,      .alipay, "极氪极充-前滩",         1.28, "ZK"),
        ]

        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let stampFmt = DateFormatter()
        stampFmt.dateFormat = "yyyyMMdd"

        return rows.enumerated().map { index, row in
            let (daysAgo, hour, minute, amount, provider, channel, station, unitPrice, prefix) = row
            let day = cal.date(byAdding: .day, value: -daysAgo, to: today) ?? today
            let ts = cal.date(bySettingHour: hour, minute: minute, second: 0, of: day) ?? day

            return ChargeRecord(
                recordId: String(format: "c-%02d", index + 1),
                timestamp: ts,
                amount: amount,
                // 按单价反推电量，保证「金额 = 电量 × 单价」自洽
                energyKwh: ((amount / unitPrice) * 10).rounded() / 10,
                provider: provider,
                channel: channel,
                merchant: station,
                stationName: station,
                unitPrice: unitPrice,
                orderNo: prefix + stampFmt.string(from: ts) + String(format: "%02d", index + 1)
            )
        }
    }

    // MARK: - 充电汇总
    //
    // 对应 preview/index.html → MOCK.summary
    // index.html 里这份汇总是「全年 47 笔」的汇总，其 records 只是最近 12 笔快照，
    // 因此这里保持同样的口径：汇总用固定值，不从 records 反推，
    // 避免 App 与网页的总额对不上。

    static let chargeSummary = ChargeSummary(
        totalAmount: 1286.50,
        totalEnergyKwh: 786.4,
        totalCount: 47,
        avgUnitPrice: 1.64,
        monthly: [
            ChargeMonthlyStat(month: "2026-04", amount: 198.30, energyKwh: 121.0, count: 7),
            ChargeMonthlyStat(month: "2026-05", amount: 226.50, energyKwh: 138.4, count: 8),
            ChargeMonthlyStat(month: "2026-06", amount: 254.10, energyKwh: 155.2, count: 9),
            ChargeMonthlyStat(month: "2026-07", amount: 201.80, energyKwh: 123.3, count: 7),
            ChargeMonthlyStat(month: "2026-08", amount: 242.60, energyKwh: 148.2, count: 9),
            ChargeMonthlyStat(month: "2026-09", amount: 163.20, energyKwh: 100.3, count: 7),
        ],
        byProvider: [
            ChargeProviderStat(provider: .teld,       amount: 354.20, energyKwh: 216.0, count: 14),
            ChargeProviderStat(provider: .zeekr,      amount: 286.40, energyKwh: 175.0, count: 8),
            ChargeProviderStat(provider: .starCharge, amount: 241.80, energyKwh: 148.0, count: 11),
            ChargeProviderStat(provider: .stateGrid,  amount: 198.50, energyKwh: 121.0, count: 7),
            ChargeProviderStat(provider: .eCharging,  amount: 132.10, energyKwh: 81.0,  count: 5),
            ChargeProviderStat(provider: .other,      amount: 73.50,  energyKwh: 45.4,  count: 2),
        ]
    )

    // MARK: - 附近充电站
    //
    // 对应 preview/index.html → MOCK.stations
    //
    // 形状与服务端模拟侧（`mock_client.get_nearby_stations`）一致 ——
    // 模拟数据只是"不上网时的演示"，字段契约不能自成一套。
    //
    // 站名一律带「演示」字样：模拟数据不该长得像真实场站。
    // 最后一站 `price: nil` 是刻意留的 —— 用来验证「取不到价格」与「免费」
    // 在界面上确实长得不一样（前者显示「价格 --」，绝不是 0）。

    static let stations: [ChargingStation] = [
        ChargingStation(
            stationId: "mock-station-1",
            name: "极氪超充·演示站 A",
            address: "演示路 1 号",
            lat: 31.2336, lng: 121.4772,
            distanceKm: 0.35,
            score: 4.6,
            tags: ["演示数据"],
            selfOperate: true,
            availableCount: 6, totalCount: 8,
            acCount: 0, dcCount: 8,
            ableAcCount: 0, ableDcCount: 6,
            price: StationPrice(
                totalPrice: 1.90, feeElectric: 1.10, serviceFee: 0.80,
                currentPeriod: "00:00-23:59",
                periods: [PricePeriod(timeFrame: "00:00-23:59", electric: 1.10, service: 0.80, total: 1.90)],
                parkingFee: "充电期间免费", parkFree: true, holdFee: false,
                feeDesc: "演示数据：全天一口价"
            )
        ),
        ChargingStation(
            stationId: "mock-station-2",
            name: "演示站 B · 商场地下层",
            address: "演示路 2 号",
            lat: 31.2376, lng: 121.4737,
            distanceKm: 0.80,
            score: 4.1,
            tags: ["演示数据"],
            selfOperate: false,
            availableCount: 2, totalCount: 12,
            acCount: 12, dcCount: 0,
            ableAcCount: 2, ableDcCount: 0,
            price: StationPrice(
                totalPrice: 1.65, feeElectric: 1.10, serviceFee: 0.55,
                currentPeriod: "11:00-22:00",
                periods: [
                    PricePeriod(timeFrame: "00:00-06:00", electric: 0.37, service: 0.98, total: 1.35),
                    PricePeriod(timeFrame: "06:00-11:00", electric: 0.72, service: 0.98, total: 1.70),
                    PricePeriod(timeFrame: "11:00-22:00", electric: 1.10, service: 0.55, total: 1.65),
                    PricePeriod(timeFrame: "22:00-23:59", electric: 0.83, service: 0.72, total: 1.55),
                ],
                parkingFee: "按停车场标准收费", parkFree: false, holdFee: false,
                feeDesc: "演示数据：尖峰平谷分时计价，谷段最划算"
            )
        ),
        ChargingStation(
            stationId: "mock-station-3",
            name: "演示站 C · 高架旁",
            address: "演示路 3 号",
            lat: 31.2430, lng: 121.4737,
            distanceKm: 1.40,
            score: 3.8,
            tags: ["演示数据"],
            selfOperate: false,
            availableCount: 0, totalCount: 16,
            acCount: 4, dcCount: 12,
            ableAcCount: 0, ableDcCount: 0,
            price: StationPrice(
                totalPrice: 1.55, feeElectric: 0.95, serviceFee: 0.60,
                currentPeriod: "00:00-23:59",
                periods: [PricePeriod(timeFrame: "00:00-23:59", electric: 0.95, service: 0.60, total: 1.55)],
                parkingFee: "按停车场标准收费", parkFree: false, holdFee: true,
                feeDesc: "演示数据：满位状态，超时占位另收费"
            )
        ),
        ChargingStation(
            stationId: "mock-station-4",
            name: "演示站 D · 客运站",
            address: "演示路 4 号",
            lat: 31.2592, lng: 121.4737,
            distanceKm: 3.20,
            score: 4.9,
            tags: ["演示数据"],
            selfOperate: false,
            availableCount: 9, totalCount: 10,
            acCount: 0, dcCount: 10,
            ableAcCount: 0, ableDcCount: 9
            // price 留空：这一站就是「取不到价格」的样本
        ),
    ]

    // MARK: - 车辆权限包
    //
    // 对应 preview/index.html → MOCK.permissions
    // 键名与后端 `/api/vehicle/capability` 的 `permissions` 一模一样 ——
    // 模拟数据只是"不上网时的演示"，字段契约不能自成一套。

    static let permissions: [String] = [
        "vehicle-share", "remote-control", "charge-manage",
        "view-vehicle-location", "owner-vehicle-trail",
    ]

    /// 能力集（对应 preview/index.html → MOCK.capabilities）
    ///
    /// **只写「服务类」键** —— 真实侧（`/ms-app-bff/api/1.0/permissions`）只回答
    /// 服务权限，不回答硬件问题。这里若补上 `tyrePressure` / `window` 这类硬件键，
    /// 模拟模式下的裁剪行为就会与真车不一致，等于拿演示数据骗自己。
    ///
    /// `seatVent: false` 是刻意留的 —— 演示"这台车没开通后排座椅通风时，
    /// 网页与 App 都会把那个按钮隐藏"。
    /// 对应 preview/index.html → MOCK.chargePlan
    static let chargePlan = ChargePlan(
        enabled: true,
        startTime: "23:30",
        endTime: "06:30",
        targetSoc: 90,
        mode: "谷电优先"
    )

    static let capabilities: [String: Bool] = [
        "sentinel": true,
        "sentinelPhoto": false,
        "chargingPlan": true,
        "travelPlan": true,
        "tripTrack": true,
        "seatVent": false,
    ]
}
