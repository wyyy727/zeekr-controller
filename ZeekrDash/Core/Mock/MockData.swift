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

    // MARK: - 当地气温
    //
    // 对应 preview/index.html → MOCK 里的演示天气。
    // 演示模式不联网，所以给固定值 —— 真机上是按车辆位置查腾讯天气。

    static let weather = WeatherInfo(
        available: true,
        temperature: 22,
        weather: "多云",
        humidity: 55,
        windDirection: "东北风",
        windPower: "1-2级",
        city: "演示市",
        district: "演示区",
        updateTime: nil
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
        /* 近 24 个月，不是近 6 个月。
           官方里程服务支持约两年（见 `live_client.py` 的 ENERGY_MONTHLY_PATH 注释），
           演示数据却只造了 5 个历史月 —— 结果是 iPhone 上「年份只能选今年、
           月份最旧只到 5 月」（10 月启动 = 10−5）。用户已实机确认过这个现象。 */
        for i in 1...23 {
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
        var totalDynamic = 0.0

        /* 与网页 `mockEnergy()`（index-v2.html 2687–2730）**逐公式对齐**：
           7 天用设计稿那组固定值；30 天（及其他天数）用确定性伪随机，避免循环出花纹。
           以前这里是 `12 + i%7*5.5` 的自造曲线，和网页并排一看就不一样。 */
        let base7: [Double] = [24.8, 41.2, 18.6, 33.5, 12.4, 56.0, 27.3]
        func jitter(_ k: Int) -> Double {
            let x = sin(Double(k) * 12.9898) * 43758.5453
            return x - floor(x)
        }

        for (index, date) in dates.enumerated() {
            let distance: Double
            if dates.count == 7 {
                distance = base7[(dates.count - 1 - index) % base7.count]
            } else {
                distance = ((9 + jitter(index + 1) * 47) * 10).rounded() / 10
            }
            let energy = (distance * 0.2 * 100).rounded() / 100
            // 静态占每天每度电的 8%~14%，随天微抖 —— 否则第二色会是一条死板的平行条
            let dynPart = ((energy * (0.92 - jitter(index + 7) * 0.06)) * 100).rounded() / 100
            let statPart = ((energy - dynPart) * 100).rounded() / 100
            totalKm += distance
            totalKwh += energy
            totalDynamic += dynPart
            series.append(DailyEnergyPoint(
                date: formatter.string(from: date),
                distanceKm: (distance * 10).rounded() / 10,
                energyKwh: energy,
                minutes: Int(distance * 1.35),
                consumption: 20.0,
                dynamicKwh: dynPart,
                staticKwh: statPart
            ))
        }

        // 汇总由逐日拆分相加得出，而不是再按固定比例算一遍 ——
        // 否则卡片上「动态 + 静态 ≠ 总电耗」，也会和下面两张图对不上
        let dynamicKwh = (totalDynamic * 100).rounded() / 100
        let avg = totalKm > 0 ? ((totalKwh / totalKm) * 1000).rounded() / 10 : 0
        let avgDynamic = totalKm > 0 ? ((dynamicKwh / totalKm) * 1000).rounded() / 10 : 0

        return DailyEnergy(
            days: dates.count,
            startDate: dates.first.map { display.string(from: $0) },
            endDate: dates.last.map { display.string(from: $0) },
            distanceKm: (totalKm * 10).rounded() / 10,
            energyKwh: (totalKwh * 100).rounded() / 100,
            dynamicEnergyKwh: dynamicKwh,
            staticEnergyKwh: ((totalKwh - dynamicKwh) * 100).rounded() / 100,
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

    // MARK: - 充入电量（演示流水）
    //
    // 对应 preview/index.html → mockCharge()
    //
    // **只有电量、时长、直/交流 —— 没有金额、没有站点名**，与真实接口
    // （`charge/log/queryGroupMouth`）的字段边界严格一致。
    // 演示数据要是"长得更完整"，界面就会按"有金额"的样子去做，接真数据时全露馅。

    static var chargeSessions: [ChargeSession] {
        let cal = Calendar.current
        let now = Date()

        let kwhPool = [38.5, 52.1, 44.0, 61.3, 29.8, 47.6, 55.2, 33.4, 49.9, 41.2]
        /* 演示金额与站名：真机上金额只能来自 OCR / 手工录入、站名只有补录过才有 ——
           但演示数据要有这些字段，界面样式才看得出来（页面有「演示数据」标记）。
           金额按 `度数 × 电价` 现算，保证「金额 = 电量 × 单价」自洽。 */
        let pricePool = [1.28, 1.45, 1.12, 1.62, 0.95, 1.35, 1.18, 1.55]
        let stationPool = [
            "极氪极充·世纪公园", "特来电·张江高科", "星星充电·万象城",
            "国家电网·静安寺", "小桔充电·虹桥枢纽", "云快充·南京西路",
        ]
        var out: [ChargeSession] = []

        // 从本月 1 号往前按月退，而不是拼 `DateComponents(month: thisMonth - m)` ——
        // 后者在跨年时依赖系统对 month: 0 / 负数的归一化，不如直接做日期加减稳。
        let startOfMonth = cal.date(from: cal.dateComponents([.year, .month], from: now)) ?? now

        for m in 0..<10 {
            guard let monthDate = cal.date(byAdding: .month, value: -m, to: startOfMonth) else {
                continue
            }
            let year = cal.component(.year, from: monthDate)
            let mon = cal.component(.month, from: monthDate)
            let lastDay = (cal.range(of: .day, in: .month, for: monthDate)?.upperBound ?? 29) - 1
            // 当月只回溯到「昨天」：演示数据里不该出现还没发生的充电
            let upper = m == 0 ? max(1, cal.component(.day, from: now) - 1) : lastDay
            let count = m == 0 ? max(1, min(4, cal.component(.day, from: now) / 8 + 1)) : 3 + ((m * 2) % 3)
            /* 留一个月**不补金额**：切到那个月才看得到「未补录」的样子 ——
               全都补满了，这个状态在演示里永远看不见。 */
            let priced = m != 2

            for i in 0..<count {
                let kwh = kwhPool[(m * 3 + i) % kwhPool.count]
                let isAc = (m + i) % 11 == 4
                // 直流按 ~75 kW、交流按 ~7 kW 反推时长，保证「平均功率」这一列看起来合理
                let minutes = (kwh / (isAc ? 7 : 75)) * 60
                let day = max(1, min(upper, 1 + ((m * 7 + i * 5) % upper)))
                let hour = [7, 12, 18, 21, 22][(m + i) % 5]
                let minute = [3, 15, 28, 41, 55][(m * 2 + i) % 5]
                let price = pricePool[(m + i) % pricePool.count]

                out.append(
                    ChargeSession(
                        sessionId: String(format: "mock-%04d%02d-%d", year, mon, i),
                        startTime: String(format: "%04d-%02d-%02d %02d:%02d:00", year, mon, day, hour, minute),
                        endTime: nil,
                        durationMin: minutes.rounded(),
                        energyKwh: kwh,
                        chargeType: isAc ? "ac" : "dc",
                        stationName: stationPool[(m * 2 + i) % stationPool.count],
                        amount: priced ? ((kwh * price) * 100).rounded() / 100 : nil,
                        amountSource: priced ? "ocr" : nil
                    )
                )
            }
        }

        // 倒序（最近一次在最前），与服务端 `list_sessions` 一致
        return out.sorted { ($0.startTime ?? "") > ($1.startTime ?? "") }
    }

    /// 演示用的月份清单（含每月电量与每次充电时长），当月统一叫 `currentMonth`
    static var chargeMonthOptions: [ChargeMonthOption] {
        var keys: [String] = []
        for item in chargeSessions {
            let key = String((item.startTime ?? "").prefix(7))
            guard key.count == 7, !keys.contains(key) else { continue }
            keys.append(key)
        }

        return keys.map { key in
            let stat = chargeStat(yearMonth: key)
            let isCurrent = key == currentYearMonth
            return ChargeMonthOption(
                yearMonth: isCurrent ? "currentMonth" : key,
                label: isCurrent ? "本月" : monthLabel(key),
                count: stat.count,
                kwh: stat.totalKwh,
                avgMinutes: stat.avgMinutes,
                amount: stat.amountTotal ?? 0,
                amountCount: stat.amountCount,
                dcCount: stat.dcCount,
                acCount: stat.acCount
            )
        }
    }

    /// 演示用的单月汇总（口径与后端 `_summarize_month` 一致）
    static func chargeStat(yearMonth: String) -> ChargeMonthStat {
        let ym = yearMonth == "currentMonth" ? currentYearMonth : yearMonth
        let rows = chargeSessions.filter { ($0.startTime ?? "").hasPrefix(ym) }

        var totalKwh = 0.0
        var totalMinutes = 0.0
        var dcKwh = 0.0
        var acKwh = 0.0
        var dcCount = 0
        var acCount = 0
        // 金额三口径与后端 `_summarize_month` 一致：真值 / 估算 / 未补
        var amountTotal = 0.0
        var amountCount = 0
        var pricedKwh = 0.0
        var unpricedCount = 0
        var unpricedKwh = 0.0
        var estimatedCount = 0
        var estimatedTotal = 0.0

        for row in rows {
            let kwh = row.energyKwh ?? 0
            totalKwh += kwh
            totalMinutes += row.durationMin ?? 0
            if row.isDC { dcCount += 1; dcKwh += kwh }
            if row.isAC { acCount += 1; acKwh += kwh }

            if row.amountSource == "estimate" {
                estimatedCount += 1
                estimatedTotal += row.amount ?? 0
            } else if let amount = row.amount {
                amountCount += 1
                amountTotal += amount
                pricedKwh += kwh
            } else {
                unpricedCount += 1
                unpricedKwh += kwh
            }
        }

        let count = rows.count
        return ChargeMonthStat(
            yearMonth: yearMonth,
            label: yearMonth == "currentMonth" ? "本月" : monthLabel(ym),
            count: count,
            totalKwh: round1(totalKwh),
            dcCount: dcCount,
            dcKwh: round1(dcKwh),
            acCount: acCount,
            acKwh: round1(acKwh),
            totalMinutes: totalMinutes.rounded(),
            avgKwh: count > 0 ? round1(totalKwh / Double(count)) : 0,
            avgMinutes: count > 0 ? (totalMinutes / Double(count)).rounded() : 0,
            avgPowerKw: totalMinutes > 0 ? round1(totalKwh / (totalMinutes / 60)) : nil,
            amountTotal: amountCount > 0 ? round2(amountTotal) : nil,
            amountCount: amountCount,
            // 单价分母只用**已补录金额对应的电量**：拿总电量去除会把没补录的算进去
            pricedKwh: round1(pricedKwh),
            unitPrice: pricedKwh > 0 ? round2(amountTotal / pricedKwh) : nil,
            unpricedCount: unpricedCount,
            unpricedKwh: round1(unpricedKwh),
            estimatedTotal: estimatedCount > 0 ? round2(estimatedTotal) : nil,
            estimatedCount: estimatedCount,
            pendingPayments: 0,
            unmatchedPayments: 0,
            records: rows
        )
    }

    private static var currentYearMonth: String {
        let cal = Calendar.current
        let now = Date()
        return String(format: "%04d-%02d", cal.component(.year, from: now), cal.component(.month, from: now))
    }

    /// `2026-09` → `2026年9月`
    private static func monthLabel(_ yearMonth: String) -> String {
        let parts = yearMonth.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 2 else { return yearMonth }
        return "\(parts[0])年\(parts[1])月"
    }

    private static func round1(_ value: Double) -> Double {
        (value * 10).rounded() / 10
    }

    private static func round2(_ value: Double) -> Double {
        (value * 100).rounded() / 100
    }

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

        // 以下 10 条是为"能看出折叠与分页"补的。
        // 只有 4 个站时，「默认只露 6 条」「展开全部」「列表内滚动」
        // 在界面上一个都成立不了 —— 没数据就没法验证交互。
        demoStation(5, "演示站 E · 写字楼", 0.48,
                    available: 3, total: 6, ac: 6, dc: 0, selfOperate: false,
                    price: 1.20, parkFree: true, score: 4.2),
        demoStation(6, "演示站 F · 高速服务区", 0.62,
                    available: 12, total: 16, ac: 0, dc: 16, selfOperate: true,
                    price: 1.35, parkFree: true, score: 4.5),
        demoStation(7, "演示站 G · 小区门口", 0.95,
                    available: 1, total: 4, ac: 4, dc: 0, selfOperate: false,
                    price: 0.95, parkFree: true, score: 3.9),
        demoStation(8, "演示站 H · 加油站旁", 1.15,
                    available: 5, total: 6, ac: 0, dc: 6, selfOperate: false,
                    price: 1.72, parkFree: false, score: 4.0),
        demoStation(9, "演示站 I · 医院停车场", 1.62,
                    available: 4, total: 8, ac: 8, dc: 0, selfOperate: false,
                    price: 1.58, parkFree: false, score: 4.3),
        demoStation(10, "演示站 J · 酒店地库", 1.88,
                    available: 6, total: 8, ac: 4, dc: 4, selfOperate: false,
                    price: 1.88, parkFree: false, score: 4.4),
        demoStation(11, "演示站 K · 物流园", 2.40,
                    available: 8, total: 12, ac: 0, dc: 12, selfOperate: true,
                    price: 1.12, parkFree: true, score: 4.1),
        demoStation(12, "演示站 L · 学校对面", 2.75,
                    available: 2, total: 6, ac: 6, dc: 0, selfOperate: false,
                    price: 1.05, parkFree: false, score: 3.7),
        demoStation(13, "演示站 M · 商场 B2", 3.60,
                    available: 10, total: 16, ac: 8, dc: 8, selfOperate: false,
                    price: 2.05, parkFree: false, score: 4.6),
        demoStation(14, "演示站 N · 体育馆", 5.20,
                    available: 7, total: 10, ac: 0, dc: 10, selfOperate: false,
                    price: 2.20, parkFree: false, score: 4.0),
    ]

    /// 生成一条演示站点。
    ///
    /// 取值规则与 `preview/index.html` 的 `demoStation()` 完全一致 ——
    /// 两端各写一套的话，"网页里看到的"和"App 里看到的"就会对不上，
    /// 那正是这个文件开头那条约束要防的事。
    private static func demoStation(
        _ index: Int,
        _ name: String,
        _ distanceKm: Double,
        available: Int,
        total: Int,
        ac: Int,
        dc: Int,
        selfOperate: Bool,
        price: Double,
        parkFree: Bool,
        score: Double
    ) -> ChargingStation {
        // 固定方位角：让坐标与距离大致自洽（距离仍由服务端 haversine 重算）
        let bearing = Double((index * 47) % 360) * .pi / 180
        let latOffset = (distanceKm / 111) * cos(bearing)
        let lngOffset = (distanceKm / (111 * cos(31.23 * .pi / 180))) * sin(bearing)
        let lat = ((31.2304 + latOffset) * 1_000_000).rounded() / 1_000_000
        let lng = ((121.4737 + lngOffset) * 1_000_000).rounded() / 1_000_000

        let electric = (price * 0.6 * 100).rounded() / 100
        let service = ((price - electric) * 100).rounded() / 100
        let ableDc = min(available, dc)

        return ChargingStation(
            stationId: "mock-station-\(index)",
            name: name,
            address: "演示路 \(index) 号",
            lat: lat, lng: lng,
            distanceKm: distanceKm,
            score: score,
            tags: ["演示数据"],
            selfOperate: selfOperate,
            availableCount: available, totalCount: total,
            acCount: ac, dcCount: dc,
            ableAcCount: max(0, available - ableDc), ableDcCount: ableDc,
            price: StationPrice(
                totalPrice: price, feeElectric: electric, serviceFee: service,
                currentPeriod: "00:00-23:59",
                periods: [PricePeriod(timeFrame: "00:00-23:59",
                                      electric: electric, service: service, total: price)],
                parkingFee: parkFree ? "充电期间免费" : "按停车场标准收费",
                parkFree: parkFree, holdFee: false,
                feeDesc: "演示数据：全天一口价"
            )
        )
    }

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
