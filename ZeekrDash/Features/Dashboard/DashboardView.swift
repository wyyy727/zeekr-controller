//
//  DashboardView.swift
//  ZeekrDash
//
//  车况屏（v2）
//
//  真源：`preview/index-v2.html` 的 `renderDashboard()`（4335–4479）
//  与车况屏样式块（1725–1794）。每个数值都能在那两处指到出处。
//

import SwiftUI
import UIKit

/// 车况屏：SOC、充电中、四项指标、胎压、车身状态、位置
struct DashboardView: View {

    @Environment(AppStore.self) private var store

    var body: some View {
        NavigationStack {
            // 车况屏是唯一 gap 12 的屏（`.v2-screen.v2-dash`）
            ScreenContainer(
                modePill: store.modePill,
                tailText: updatedTailText,
                sectionGap: V2Metrics.dashGap
            ) {
                if store.needsLogin {
                    // 已连上服务端但还没登录 —— 停在登录引导，不碰任何数据接口
                    loginWall
                } else if let status = store.vehicleStatus {
                    /* 注意：「更新于」不在这里，它通过 `tailText` 渲染在顶栏、
                       与来源胶囊同一行 —— 这是 HTML `.v2-head--end` 的结构。
                       以前是内容区单独一行，首卡因此比网页低约 22pt。 */

                    /* 有旧数据但本轮失败：保留旧数据，明确告知「不是刚拿的」。
                       这是 v2 的 `.v2-stale`（4365–4369），不要退化成静默的旧数字。 */
                    if let message = store.errorMessage {
                        V2StaleBanner(
                            text: "这一轮没读到最新车况，下面是上次读到的数据",
                            detail: message
                        ) { Task { await store.refresh() } }
                    }

                    socCard(status)

                    // 充电中卡**条件渲染**：未充电时整张消失（HTML 4372）
                    if status.isCharging == true {
                        chargingCard(status)
                    }

                    metricsCard(status)
                    if cap("tyrePressure") {
                        tyreCard(status)
                    }
                    statusCard(status)
                    locationCard(store.vehicleLocation)
                    footNote
                } else if store.isLoading {
                    skeleton
                } else {
                    emptyState
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .refreshable { await store.refresh() }
        }
        // 进后台停轮询、回前台补刷，统一由 RootView 处理（页面随 tab 重建，
        // 自己监听在「不在这页」时会失效）。这里只管切回本页时把轮询接上。
        .onAppear { store.startPolling() }
    }

    // MARK: - 能力门控

    /// 与网页 `cap(key)` 同语义：明确 false 才隐藏，**取不到一律显示**。
    ///
    /// 刻意不做「拿不到就隐藏」：网络抖动不该让整块功能凭空消失。
    private func cap(_ key: String) -> Bool {
        guard let caps = store.capabilities else { return true }
        return caps[key] != false
    }

    // MARK: - 页头右对齐行（HTML 4411–4419）

    /// 顶栏右侧的「更新于」—— 与来源胶囊**同一行**（HTML `.v2-head--end` 里的 `.v2-updated`）
    private var updatedTailText: String? {
        store.lastRefresh.map { "更新于 \(updatedText($0))" }
    }

    private func updatedText(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }


    // MARK: - SOC 卡（HTML 4425–4432）

    private func socCard(_ status: VehicleStatus) -> some View {
        HStack(spacing: 20) {
            // v2 环是 100×100 / 线宽 8（HTML `v2Ring()` 默认值）
            SOCRing(
                soc: status.soc,
                isCharging: status.isCharging == true,
                size: 100,
                lineWidth: 8
            )

            VStack(alignment: .leading, spacing: 10) {
                if let plate = status.plateNo, !plate.isEmpty {
                    Text(plate)
                        .v2Text(.chip11, color: V2Color.accent)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(V2Color.accent.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                }

                // `.v2-kv`：15 / 600 / 22，单位 11 / 500 / text-2
                kvRow("续航", value: status.rangeKm.map { "\(Int($0.rounded()))" }, unit: "km")

                // `.v2-kv.sub`：14 / 400 / 20，整行 text-2
                kvRow(
                    "总里程",
                    value: status.odometerKm.map { formatDistance($0) },
                    unit: "km",
                    secondary: true
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .v2Card()
    }

    private func kvRow(
        _ title: String,
        value: String?,
        unit: String,
        secondary: Bool = false
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(title)
                .v2Text(secondary ? .body14 : .body15, color: secondary ? V2Color.text2 : V2Color.text1)
            if let value {
                Text(value)
                    .v2Text(secondary ? .body14 : .body15, color: secondary ? V2Color.text2 : V2Color.text1)
                    .v2Numeric()
                Text(unit)
                    .v2Text(.label11, color: V2Color.text2)
            } else {
                Text("--")
                    .v2Text(secondary ? .body14 : .body15, color: V2Color.text2)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - 充电中卡（HTML 4372–4381）

    private func chargingCard(_ status: VehicleStatus) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("充电中")
                .v2Text(.title14, color: V2Color.info)

            HStack {
                chargeValue(status.chargePowerKw, unit: "kW", decimals: 1)
                Spacer(minLength: 0)
                chargeValue(status.chargeVoltage, unit: "V", decimals: 0)
                Spacer(minLength: 0)
                chargeValue(status.chargeCurrent, unit: "A", decimals: 0)
            }

            if let minutes = status.minutesToFull, minutes > 0 {
                Text("预计 \(formatDuration(minutes))充满")
                    .v2Text(.text12, color: V2Color.text2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .v2Card()
    }

    private func chargeValue(_ value: Double?, unit: String, decimals: Int) -> some View {
        HStack(spacing: 3) {
            Text(value.map { String(format: "%.\(decimals)f", $0) } ?? "--")
                .v2Text(.num16)
                .v2Numeric()
            Text(unit)
                .v2Text(.label11, color: V2Color.text2)
        }
    }

    // MARK: - 四项指标（HTML 4436–4447）

    private func metricsCard(_ status: VehicleStatus) -> some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                metric("车内温度", value: status.interiorTemp.map { String(format: "%.1f", $0) }, unit: "°C")
                metric("当地气温", value: weatherTempText, unit: "°C")
            }
            HStack(spacing: 12) {
                metric("平均能耗", value: status.avgConsumption.map { String(format: "%.1f", $0) }, unit: "kWh/100km")
                metric("12V 电瓶", value: status.battery12vVoltage.map { String(format: "%.1f", $0) }, unit: "V")
            }
        }
        .v2Card()
    }

    /// 格子：标签 11/500/14 text-3，数值 16/600/22，单位 11/500/14 text-3
    private func metric(_ title: String, value: String?, unit: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .v2Text(.label11, color: V2Color.text3)
            HStack(spacing: 2) {
                Text(value ?? "--")
                    .v2Text(.num16)
                    .v2Numeric()
                if value != nil, !unit.isEmpty {
                    Text(unit)
                        .v2Text(.label11, color: V2Color.text3)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 「当地气温」而不是「车外温度」：车端 `exteriorTemp` 实测恒为空（这版固件不上报），
    /// 这个数是按车辆位置查来的天气。暴晒 / 地库时两者能差十几度，标成"车外温度"就是谎报。
    ///
    /// ⚠️ HTML 的 `weatherTemp()`（`index-v2.html:4499`）是 `Math.round` —— **取整**。
    /// 这里**故意偏离真源**：仓库既定口径是「气温保留一位小数」（10-23 定，勿取整），
    /// 且车内温度 / 平均能耗 / 12V 都是 `%.1f`，同一张卡里取整会让气温显得突兀。
    /// 这是经用户确认的第三处例外，不是漏改；要回真源只改这一行。
    private var weatherTempText: String? {
        guard let w = store.weather, w.available == true, let t = w.temperature else { return nil }
        return String(format: "%.1f", t)
    }

    // MARK: - 胎压（HTML 4449–4458）

    private func tyreCard(_ status: VehicleStatus) -> some View {
        VStack(spacing: 8) {
            HStack(spacing: 4) {
                Text("胎压")
                    .v2Text(.title14)
                Text("kPa")
                    .v2Text(.label11, color: V2Color.text3)
                Spacer(minLength: 0)
            }

            HStack(spacing: 8) {
                tyreColumn("左前", status.tyreFrontLeft, status.tyreTempFrontLeft)
                tyreColumn("右前", status.tyreFrontRight, status.tyreTempFrontRight)
                tyreColumn("左后", status.tyreRearLeft, status.tyreTempRearLeft)
                tyreColumn("右后", status.tyreRearRight, status.tyreTempRearRight)
            }
        }
        .v2Card()
    }

    /// 正常区间 240–320 kPa：本车四轮约 299–305，旧的 220–280 会把四个正常值全判成异常。
    private func tyreColumn(_ label: String, _ value: Double?, _ temp: Double?) -> some View {
        let abnormal = value.map { $0 < 240 || $0 > 320 } ?? false
        return VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .v2Text(.label11, color: V2Color.text3)
            Text(value.map { String(format: "%.0f", $0) } ?? "--")
                .v2Text(.num16, color: abnormal ? V2Color.bad : V2Color.text1)
                .v2Numeric()
            /* 胎温是 v2 没有的副行：只在真有值时才渲染，取不到时不占位 ——
               常态下与 HTML 完全一致，避免出现无意义的 "----"。 */
            if let temp {
                Text("\(Int(temp.rounded()))°")
                    .v2Text(.label11, color: V2Color.text3)
                    .v2Numeric()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 车身状态（HTML 4460–4474）

    private func statusCard(_ status: VehicleStatus) -> some View {
        VStack(spacing: 8) {
            HStack {
                Text("车身状态")
                    .v2Text(.title14)
                Spacer(minLength: 0)
            }

            VStack(spacing: 9) {
                HStack(spacing: 0) {
                    // 「锁车」与「车门」是两件事：把锁车状态挂在「车门」下会让人以为车门已关好
                    statusItem("锁车", capKey: "doorLock", value: status.isLocked, on: "已锁", off: "未锁", onTone: .good, offTone: .bad)
                    statusItem("车门", capKey: "doorLock", value: anyOpen(status.doors), on: "有门未关", off: "全部关闭", onTone: .bad, offTone: .good)
                    statusItem("空调", capKey: "climate", value: status.climateOn, on: "开启", off: "关闭", onTone: .info, offTone: .plain)
                }
                HStack(spacing: 0) {
                    statusItem("车窗", capKey: "window", value: anyOpen(status.windows), on: "有窗未关", off: "全部关闭", onTone: .bad, offTone: .good)
                    statusItem("后备箱", capKey: "trunk", value: status.trunkOpen, on: "开启", off: "已关", onTone: .bad, offTone: .good)
                    statusItem("前备箱", capKey: "frunk", value: status.frunkOpen, on: "开启", off: "已关", onTone: .bad, offTone: .good)
                }
            }
        }
        .v2Card()
    }

    private enum Tone {
        case good, bad, info, plain

        var color: Color {
            switch self {
            case .good:  return V2Color.good
            case .bad:   return V2Color.bad
            case .info:  return V2Color.info
            case .plain: return V2Color.text2
            }
        }
    }

    /// `.v2-status-item`：占 1/3 宽，12/500/15，名称与状态同色（状态色由 tone 决定）。
    /// `value == nil` 时显示「—」且不带色调 —— 「不知道」不能画成「没问题」。
    @ViewBuilder
    private func statusItem(
        _ name: String,
        capKey: String,
        value: Bool?,
        on onText: String,
        off offText: String,
        onTone: Tone,
        offTone: Tone
    ) -> some View {
        if cap(capKey) {
            HStack(spacing: 0) {
                Text("\(name) · ")
                    .v2Text(.item12, color: V2Color.text2)
                if let value {
                    Text(value ? onText : offText)
                        .v2Text(.item12, color: value ? onTone.color : offTone.color)
                } else {
                    Text("—")
                        .v2Text(.item12, color: V2Color.text2)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .lineLimit(1)
        }
    }

    /// 任一扇开即开。整体 nil 表示网关没给 —— 由调用处判为「—」。
    private func anyOpen(_ dict: [String: Bool]?) -> Bool? {
        guard let dict else { return nil }
        return dict.values.contains { $0 == true }
    }

    // MARK: - 车辆位置（HTML `v2LocCard()` 4044–4073）

    /// 四种形态：A 正常 / B 有坐标但没取到地址 / C 没配 key 或非实时 / D 地图图加载不出来。
    private func locationCard(_ location: VehicleLocation?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("车辆位置")
                    .v2Text(.title14)
                if let raw = location?.reportedAt, !raw.isEmpty {
                    Text("最后上报 \(formatReportedAt(raw))")
                        .v2Text(.label11, color: V2Color.text3)
                }
                Spacer(minLength: 0)
            }

            locationBody(location)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .v2Card()
    }

    @ViewBuilder
    private func locationBody(_ location: VehicleLocation?) -> some View {
        if let location, location.available == true {
            locationDetail(location)
        } else if let location {
            Text(location.reason ?? "车辆尚未上报位置")
                .v2Text(.text13, color: V2Color.text2)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text("正在获取位置…")
                .v2Text(.text13, color: V2Color.text2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func locationDetail(_ location: VehicleLocation) -> some View {
        let showMap = location.mapAvailable == true && store.dataMode == .live
        let address = location.address?.recommend ?? location.address?.address

        if showMap {
            if let data = store.locationMapData, let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(600.0 / 260.0, contentMode: .fill)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            } else {
                // 形态 D：地图这张图没加载出来 —— 地址照常可读，不整块消失
                Text("地图暂时加载不出来")
                    .v2Text(.text13, color: V2Color.text3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }

        if let address {
            Text(address)
                .v2Text(.text13, color: V2Color.text2)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text(location.mapAvailable == true ? "地址暂时取不到" : "未配置地图服务")
                .v2Text(.text13, color: V2Color.text3)
                .frame(maxWidth: .infinity, alignment: .leading)
        }

        if let recommend = location.address?.recommend,
           let full = location.address?.address,
           recommend != full {
            Text(full)
                .v2Text(.label11, color: V2Color.text3)
                .fixedSize(horizontal: false, vertical: true)
        }

        Text(address == nil ? mapUnavailableHint(location) : "位置取自车辆最后一次上报，车辆移动后可能不会立即更新。")
            .v2Text(.label11, color: V2Color.text3)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// 必须区分两种情况 —— 处理方式完全不同：
    /// · 没配 key → 去 `.env` 填 `TENCENT_MAP_KEY`
    /// · 配了但取不到 → 多半是第三方额度用完 / 网络问题，改配置没用
    private func mapUnavailableHint(_ location: VehicleLocation) -> String {
        if location.mapAvailable == true {
            return "地图服务已配置，但这次没取到地址（可能是第三方额度用完或网络问题）。稍后会自动重试。"
        }
        return "尚未配置腾讯地图 key，只显示「最后上报」时间。在服务端 .env 填入 TENCENT_MAP_KEY 并重启，即可显示地址与地图图。"
    }

    // MARK: - 页脚（`.v2-foot`）

    private var footNote: some View {
        Text("数据来自非官方接口，仅供参考")
            .v2Text(.foot11, color: V2Color.text3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 8)
    }

    // MARK: - 加载骨架（HTML 4339–4343）

    private var skeleton: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("车辆状态")
                .v2Text(.title14)
            Text("加载中")
                .v2Text(.label11, color: V2Color.text3)
            ForEach(0..<3, id: \.self) { _ in
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.white.opacity(0.55))
                    .frame(height: 14)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .v2Card()
    }

    // MARK: - 未登录引导（五屏共用 `V2LoginWall`）

    private var loginWall: some View {
        V2LoginWall { store.selectedTab = .settings }
    }

    // MARK: - 空态 / 读失败（HTML 4345–4359）

    private var emptyState: some View {
        VStack(spacing: 14) {
            // `.v2-empty-ico svg`（1997 行）：28×28，色 #666F7E
            Image("ic-car")
                .renderingMode(.template)
                .resizable()
                .frame(width: 28, height: 28)
                .foregroundStyle(V2Color.text3)

            Text(store.errorMessage == nil ? "尚未获取到车辆数据" : "车辆数据没有读到")
                .v2Text(.body15, color: V2Color.text2)

            Text(store.errorMessage == nil
                 ? "请确认服务已启动，且地址配置正确"
                 : "后端可能正在重启，或登录状态已失效")
                .v2Text(.text12, color: V2Color.text3)
                .multilineTextAlignment(.center)

            Button("重试") { Task { await store.refresh() } }
                .v2Text(.title14, color: .white)
                .padding(.horizontal, 22)
                .padding(.vertical, 10)
                .background(V2Color.accent)
                .clipShape(Capsule())
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .v2Card()
    }

    // MARK: - 格式化

    /// 里程一律显示原始公里数 —— 不做「万」换算：既有精度损失，
    /// 也无法与官方 App 的读数直接比对。
    private func formatDistance(_ km: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        formatter.groupingSeparator = ","
        formatter.maximumFractionDigits = 0
        formatter.roundingMode = .halfUp
        return formatter.string(from: NSNumber(value: km)) ?? String(format: "%.0f", km)
    }

    private func formatDuration(_ minutes: Double) -> String {
        let total = Int(minutes)
        if total < 60 { return "\(total) 分钟" }
        let hours = total / 60
        let mins = total % 60
        return mins == 0 ? "\(hours) 小时" : "\(hours) 小时 \(mins) 分"
    }

    /// `yyyy-MM-dd HH:mm:ss` → 「今天 10:48」/「10月19日 10:48」。
    /// 解析失败就原样显示 —— 宁可难看，也不要把时间吞掉。
    private func formatReportedAt(_ raw: String) -> String {
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.timeZone = TimeZone(identifier: "Asia/Shanghai")
        parser.dateFormat = "yyyy-MM-dd HH:mm:ss"

        guard let date = parser.date(from: raw) else { return raw }

        let output = DateFormatter()
        output.locale = Locale(identifier: "zh_CN")
        output.timeZone = TimeZone(identifier: "Asia/Shanghai")
        let isToday = Calendar.current.isDateInToday(date)
        output.dateFormat = isToday ? "HH:mm" : "M月d日 HH:mm"
        let text = output.string(from: date)
        return isToday ? "今天 \(text)" : text
    }
}
