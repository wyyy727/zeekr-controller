//
//  NearbyStationsView.swift
//  ZeekrDash
//
//  附近充电站卡片（充电页）
//
//  数据全部来自服务端 `/api/stations/nearby`：App 既不接触极氪签名，也不接触
//  第三方渠道号 —— 更不会把用户坐标发给第三方（服务端只转 stationId）。
//

import SwiftUI

/// 附近充电站
///
/// 样式与充电页其它卡片一致（实心卡片 + 传统色），不做玻璃：
/// 密集文字上盖玻璃是可读性灾难。
struct NearbyStationsCard: View {

    @Environment(\.colorScheme) private var scheme
    @Environment(\.openURL) private var openURL
    @Environment(AppStore.self) private var store

    @State private var model = NearbyStationsViewModel()
    @State private var manualText = ""
    @State private var showManualField = false
    /// 卡片内的行内提示（如坐标格式不对），不占用全局 Toast
    @State private var hint: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            content
        }
        .padding(Metrics.cardPadding)
        .background(Theme.surface(scheme))
        .clipShape(RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous))
        // 首次进入页面自动定位一次；被拒之后不再自动重试，交给「重试定位」
        .task { await model.loadIfNeeded() }
        .onChange(of: store.needsLogin) { _, needsLogin in
            // 登出后坐标与列表都不该留着 —— 位置是隐私，不跨会话留存
            if needsLogin { model.clear() }
        }
    }

    // MARK: - 标题

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("附近充电站")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.textPrimary(scheme))

            Spacer(minLength: 0)

            Text(statusText)
                .font(.system(size: 11))
                .foregroundStyle(Theme.textTertiary(scheme))
        }
    }

    private var statusText: String {
        switch model.state {
        case .idle:            return "待定位"
        case .locating:        return "定位中"
        case .loadingStations: return "加载中"
        case .loaded:
            // 写「已加载 / 总数」，否则「50 站」配着 10 条列表会让人以为没加载完
            return model.hasMore ? "\(model.stations.count) / \(model.total) 站" : "\(model.total) 站"
        // 失败可能是定位被拒，也可能是网络问题 —— 写「需定位」会误判后者
        case .failed:          return "失败"
        }
    }

    // MARK: - 各状态分支

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .idle:
            idleBlock
        case .locating, .loadingStations:
            busyBlock
        case .failed(let message):
            failedBlock(message)
        case .loaded:
            if model.stations.isEmpty {
                emptyBlock
            } else {
                listBlock
            }
        }
    }

    /// 还没定位过：先说清楚要拿位置干什么，再让用户点。
    /// 直接弹权限框而不解释，是最容易被拒的做法。
    private var idleBlock: some View {
        VStack(alignment: .leading, spacing: 9) {
            note("查找充电站需要手机定位。位置只用于本次查询 —— 不落盘，也不会发给第三方。")
            actionButton("获取附近充电站", filled: true) {
                Task { await model.locate() }
            }
        }
    }

    private var busyBlock: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text(model.state == .locating ? "正在获取当前位置…" : "正在查找附近充电站…")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary(scheme))
            Spacer()
        }
        .padding(.vertical, 4)
    }

    /// 定位失败 / 被拒：**给出具体原因**，否则用户只会以为页面坏了。
    /// 手动输入是必需的退路 —— 被拒之后没有它，这页就永远空着。
    private func failedBlock(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            note(message)

            actionButton("重试定位", filled: true) {
                Task { await model.locate() }
            }

            if showManualField {
                HStack(spacing: 8) {
                    TextField("纬度, 经度", text: $manualText)
                        .font(.system(size: 12))
                        .textFieldStyle(.roundedBorder)
                        .keyboardType(.numbersAndPunctuation)
                        .autocorrectionDisabled()

                    actionButton("使用", filled: false) { applyManual() }
                        .frame(width: 62)
                }

                if let hint {
                    Text(hint)
                        .font(.system(size: 11))
                        .foregroundStyle(ChineseColor.zhuSha)
                }
            } else {
                actionButton("手动输入坐标", filled: false) { showManualField = true }
            }
        }
    }

    private var emptyBlock: some View {
        VStack(alignment: .leading, spacing: 9) {
            note("附近没有查到充电站。")
            actionButton("重新定位", filled: false) {
                Task { await model.locate() }
            }
        }
    }

    // MARK: - 列表

    private var listBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 第三方价格服务不可用 ≠ 这些站免费，必须说清楚，
            // 否则一排空价格会被读成"都不要钱"。
            if !model.isPriceAvailable {
                note("价格服务暂时不可用，以下仅显示距离与枪数。")
            }

            HStack(alignment: .center, spacing: 8) {
                Text("点卡片看分时电价")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textTertiary(scheme))
                Spacer(minLength: 0)
                sortControl
            }

            VStack(alignment: .leading, spacing: 0) {
                // 用 `station.id` 而不是 `enumerated()` 的下标做身份 ——
                // Swift 的 key path **不能指向元组元素**（`\.element.id` 编不过），
                // 而按下标走会让"排序一变、行身份就跟着变"，展开态跟着乱跳。
                ForEach(model.sortedStations) { station in
                    row(station)
                        // 滑到最后一行就取下一页（没有"加载更多"按钮）
                        .onAppear {
                            Task { await model.loadMoreIfNeeded(current: station) }
                        }
                    if station.id != model.sortedStations.last?.id {
                        Divider().overlay(Theme.separator(scheme))
                    }
                }
            }

            // 分页尾部提示：加载中 / 已全部显示
            if model.isLoadingMore {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("正在加载更多…")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.textTertiary(scheme))
                    Spacer(minLength: 0)
                }
                .padding(.top, 10)
            } else if !model.hasMore {
                Text("已全部显示")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.textTertiary(scheme))
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 10)
            }

            note(
                model.isUsingManualCoordinate
                    ? "当前用的是手动输入的坐标。位置仅用于本次查询，不落盘、不发给第三方。"
                    : "位置仅用于本次查询，不落盘、不发给第三方。"
            )
        }
    }

    private var sortControl: some View {
        HStack(spacing: 4) {
            ForEach(NearbyStationsViewModel.Sort.allCases) { item in
                let isOn = model.sort == item
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) { model.sort = item }
                } label: {
                    Text(item.title)
                        .font(.system(size: 11, weight: isOn ? .semibold : .regular))
                        .foregroundStyle(isOn ? Theme.accent(scheme) : Theme.textTertiary(scheme))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            isOn ? Theme.surfaceAlt(scheme) : Color.clear,
                            in: Capsule()
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func row(_ station: ChargingStation) -> some View {
        let isOpen = model.expanded == station.stationId

        return VStack(alignment: .leading, spacing: 5) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    model.toggleExpanded(station.stationId)
                }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(station.displayName)
                        .font(.system(size: 13.5, weight: .medium))
                        .foregroundStyle(Theme.textPrimary(scheme))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    priceLabel(station)
                }
            }
            .buttonStyle(.plain)

            metaLine(station)

            if isOpen {
                detailBlock(station)
            }
        }
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func priceLabel(_ station: ChargingStation) -> some View {
        if station.hasPrice, let total = station.price?.totalPrice {
            HStack(alignment: .firstTextBaseline, spacing: 1) {
                Text(String(format: "%.2f", total))
                    .font(.system(size: 15, weight: .medium, design: .rounded))
                    .monospacedDigit()
                Text("/度")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.textTertiary(scheme))
            }
            .foregroundStyle(priceColor)
        } else {
            // 「价格 --」而不是 0：把"没查到"画成"不要钱"是会被当真的
            Text("价格 --")
                .font(.system(size: 13))
                .foregroundStyle(Theme.textTertiary(scheme))
        }
    }

    /// 充电语义色用靛青（深色模式下换成高亮的 accent，保证对比度）
    private var priceColor: Color {
        scheme == .dark ? Theme.accent(scheme) : ChineseColor.dianQing
    }

    private func metaLine(_ station: ChargingStation) -> some View {
        HStack(spacing: 6) {
            Text(station.distanceText)

            ForEach(station.gunTexts, id: \.self) { text in
                Text(text)
                    .foregroundStyle(station.isFull ? ChineseColor.zhuSha : ChineseColor.qingBi)
            }

            if let score = station.scoreText {
                Text("评分 \(score)")
            }

            if station.selfOperate == true {
                tagView("自营")
            }

            ForEach(Array((station.tags ?? []).prefix(2)), id: \.self) { tag in
                tagView(tag)
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(Theme.textTertiary(scheme))
        .lineLimit(1)
        .minimumScaleFactor(0.9)
    }

    /// 展开区：分时电价 + 停车 / 占位费 + 导航
    private func detailBlock(_ station: ChargingStation) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let price = station.price {
                let periods = price.periods ?? []
                if periods.isEmpty {
                    periodRow(title: "分时电价未提供", value: "--", isCurrent: false)
                } else {
                    // 按下标遍历：时段文案本身可能重复（上游偶尔会给出同名时段），
                    // 用它当身份会让 ForEach 里出现重复 id
                    ForEach(Array(periods.indices), id: \.self) { index in
                        let period = periods[index]
                        let isCurrent = period.isCurrent(price.currentPeriod)
                        periodRow(
                            title: (period.timeFrame ?? "--") + (isCurrent ? " · 当前" : ""),
                            value: period.total.map { String(format: "%.2f 元/度", $0) } ?? "--",
                            isCurrent: isCurrent
                        )
                    }
                }

                if let desc = price.feeDesc, !desc.isEmpty {
                    note(desc)
                }
                if let parking = price.parkingText {
                    note("停车：\(parking)")
                }
                if price.holdFee == true {
                    note("超时占用另收占位费")
                }
            } else {
                periodRow(title: "该站点暂时取不到价格", value: "--", isCurrent: false)
            }

            actionButton("导航到这里", filled: false) { openNavigation(station) }
        }
        .padding(.top, 4)
    }

    private func periodRow(title: String, value: String, isCurrent: Bool) -> some View {
        HStack(spacing: 10) {
            Text(title)
            Spacer(minLength: 0)
            Text(value)
        }
        .font(.system(size: 11.5, weight: isCurrent ? .semibold : .regular))
        .foregroundStyle(isCurrent ? priceColor : Theme.textTertiary(scheme))
    }

    private func tagView(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10))
            .foregroundStyle(Theme.accent(scheme))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Theme.surfaceAlt(scheme),
                in: RoundedRectangle(cornerRadius: 5, style: .continuous)
            )
    }

    // MARK: - 交互

    private func applyManual() {
        Task {
            let ok = await model.applyManualCoordinate(manualText)
            hint = ok ? nil : "请输入「纬度, 经度」，例如 31.2304, 121.4737"
        }
    }

    /// 一键导航交给地图 App，不在页内画地图 ——
    /// 画地图要引入瓦片、手势与坐标系纠偏，成本远高于收益。
    ///
    /// 站点名放进 URL 查询串时的安全字符集。
    ///
    /// 不能直接用 `.urlQueryAllowed` —— 它**放行 `&` `=` `#`**，
    /// 站点名里出现这些字符会把 `to=` 参数截断，导航到错误的地方。
    private static let queryValueAllowed: CharacterSet = {
        var set = CharacterSet.urlQueryAllowed
        set.remove(charactersIn: "&=?#+")
        return set
    }()

    /// 导航到站点。
    ///
    /// 两段式：先试高德 App 的原生 scheme（直接进导航页，不闪浏览器），
    /// 没装高德再退回 H5；H5 带上 `callnative=1`（高德文档里默认是 0），
    /// 否则只会停在网页版 —— 这正是此前「跳到浏览器高德」的原因。
    ///
    /// `dev=0`：传入的就是 GCJ-02 坐标，不需要高德再转换。
    private func openNavigation(_ station: ChargingStation) {
        guard let lat = station.lat, let lng = station.lng else {
            hint = "该站点缺少坐标，无法导航"
            return
        }
        let name = station.displayName
            .addingPercentEncoding(withAllowedCharacters: Self.queryValueAllowed) ?? ""

        let appURL = URL(string:
            "iosamap://navi?sourceApplication=ZeekrDash&poiname=\(name)"
            + "&lat=\(lat)&lon=\(lng)&dev=0&style=2")
        let webURL = URL(string:
            "https://uri.amap.com/navigation?to=\(lng),\(lat),\(name)"
            + "&mode=car&policy=0&coordinate=gaode&callnative=1&src=zeekrdash")

        guard let appURL else {
            if let webURL { openURL(webURL) }
            return
        }

        openURL(appURL) { accepted in
            // accepted == false：设备上没装高德（或系统拦了 scheme）
            guard !accepted, let webURL else { return }
            openURL(webURL)
        }
    }

    // MARK: - 小组件

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10.5))
            .foregroundStyle(Theme.textTertiary(scheme))
            .fixedSize(horizontal: false, vertical: true)
    }

    private func actionButton(_ title: String, filled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(
                    filled ? ChineseColor.xiangYaBai : Theme.accent(scheme)
                )
                .frame(maxWidth: .infinity, minHeight: 34)
                .background(
                    filled
                        ? Theme.accent(scheme)
                        : Theme.surfaceAlt(scheme),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                )
        }
        .buttonStyle(.plain)
    }
}
