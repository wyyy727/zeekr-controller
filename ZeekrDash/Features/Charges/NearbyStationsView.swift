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
            // 换筛选条件 / 重新定位时列表还在，这里只标"更新中"（对应网页的 is-busy）
            if model.isRefreshing { return "更新中" }
            // 写「已加载 / 总数」，否则「50 站」配着 10 条列表会让人以为没加载完。
            // 用价格类条件（停车免费）筛时**不写分母**：那种筛选要先取价才能判断，
            // 服务端只扫固定范围，total 是候选数而不是匹配总数。
            if model.priceFilterApplied {
                return "\(model.stations.count) 站 · 已筛选"
            }
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
            /* 有筛选时的空结果**不能说成"附近没有充电站"** —— 那是在撒谎：
               站是有的，只是不符合条件。必须留一个清除筛选的出口。 */
            note(model.hasAnyFilter
                 ? "附近没有符合当前筛选条件的站。放宽条件或清除筛选再看看。"
                 : "附近没有查到充电站。")

            if model.hasAnyFilter {
                actionButton("清除筛选", filled: true) {
                    Task { await model.clearFilters() }
                }
            } else {
                actionButton("重新定位", filled: false) {
                    Task { await model.locate() }
                }
            }
        }
    }

    // MARK: - 列表

    /// 列表高度上限。
    ///
    /// 卡片**不再折叠/展开**：一进来就是最终高度，位置不跳。
    /// 384pt ≈ 5~6 行，够判断"附近有没有能用的站"，又让下面的
    /// 「预约充电」「消费账单」留在正常翻页范围内。
    private let listMaxHeight: CGFloat = 384

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

            filterRow

            // 就地刷新时保留旧列表、压暗并暂时禁点 —— 与网页 `.st-list.is-busy` 一致。
            // 换成 spinner 会把筛选 chip 一起带走，用户点一下"快充"按钮就消失了。
            stationList
                .opacity(model.isRefreshing ? 0.45 : 1)
                .disabled(model.isRefreshing)
                .animation(.easeInOut(duration: 0.15), value: model.isRefreshing)

            note(
                model.isUsingManualCoordinate
                    ? "当前用的是手动输入的坐标。位置仅用于本次查询，不落盘、不发给第三方。"
                    : "位置仅用于本次查询，不落盘、不发给第三方。"
            )
        }
    }

    /// 站点列表：高度固定、自己滚。
    ///
    /// 三个关键点：
    /// 1. **卡片本身不动** —— 手指在列表上滑只翻站点，滑到底自动取下一页；
    ///    滑列表之外才是翻整页。两者用不同的滚动容器隔开，
    ///    就不会再出现"越滑越加载、下面两张卡永远看不到"。
    /// 2. 必须 `LazyVStack` —— 普通 `VStack` 会把所有行一次性建出来，
    ///    末行的 `onAppear` 在首屏就触发，于是不用滑也会一页页往下取。
    /// 3. 必须高度封顶 —— 否则整页还是被列表撑长，封顶后才有"内层滚动"这回事。
    private var stationList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                // 用 `station.id` 而不是 `enumerated()` 的下标做身份 ——
                // Swift 的 key path **不能指向元组元素**（`\.element.id` 编不过），
                // 而按下标走会让"排序一变、行身份就跟着变"。
                ForEach(model.sortedStations) { station in
                    row(station)
                        .onAppear {
                            Task { await model.loadMoreIfNeeded(current: station) }
                        }
                    if station.id != model.sortedStations.last?.id {
                        Divider().overlay(Theme.separator(scheme))
                    }
                }

                listFooter
            }
        }
        .frame(height: listHeight)
        .scrollIndicators(.hidden)
    }

    /// 列表高度：按行数估算，再夹到上限。
    ///
    /// 为什么不直接 `.frame(maxHeight:)`：`ScrollView` 在滚动轴上是**贪心**的，
    /// 只给上限时它照样占满 384pt —— 只剩 2 个站时，卡片下面会空出一大块。
    /// 网页是 `max-height`（内容少就收缩），这里要对齐同样的观感。
    ///
    /// 也没有用 `GeometryReader` 去量内容高度：`LazyVStack` 的尺寸要等行被
    /// 真正创建才准，量它会把"懒"变成"全建"，而那正是"一进页面就连锁翻页"的根源。
    private var listHeight: CGFloat {
        let rowEstimate: CGFloat = 64      // 站名一行 + 距离/枪数一行 ≈ 64pt
        let footerEstimate: CGFloat = 44
        let estimated = CGFloat(model.sortedStations.count) * rowEstimate + footerEstimate
        return min(max(estimated, 140), listMaxHeight)
    }

    /// 列表底部：加载中 / 加载更多 / 已全部显示。
    ///
    /// 「加载更多」是**兜底**：某一页条数很少（比如价格筛选命中不多）时，
    /// 列表压根不需要滚动，那条"滚到底触发"就永远等不到 ——
    /// 没有这个按钮用户会以为卡住了。
    @ViewBuilder
    private var listFooter: some View {
        if model.isLoadingMore {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("正在加载更多…")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.textTertiary(scheme))
                Spacer(minLength: 0)
            }
            .padding(.vertical, 10)
        } else if model.hasMore {
            // 价格类筛选时 total 是候选数，写「x / y」会把"还有这么多"夸大
            actionButton(
                model.priceFilterApplied
                    ? "加载更多"
                    : "加载更多（\(model.stations.count) / \(model.total)）",
                filled: false
            ) {
                Task { await model.loadMore() }
            }
            .padding(.top, 8)
        } else if !model.stations.isEmpty {
            Text("已全部显示")
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.textTertiary(scheme))
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 10)
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
                        // 同样把点击区补到 44pt（HIG），视觉不变
                        .frame(minHeight: Metrics.minTouchTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isOn ? [.isSelected] : [])
            }
        }
    }

    /// 筛选 chip。
    ///
    /// 与网页保持一致：只露 **快充 / 极氪自营 / 停车免费**。
    /// 电价档位（≤1.0 / 1.5 / 2.0 元）试过一版，一行铺七个 chip 太占地方，已去掉 ——
    /// 接口的 `max_price` 参数仍在，要恢复只需在这里加一个 chip。
    ///
    /// 用横向 ScrollView 而不是 `HStack` 直接铺：窄屏（SE 宽度）上四个元素
    /// 会换行，一换行卡片就变高，而这张卡下面还压着别的卡。
    private var filterRow: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                filterChip("快充", isOn: model.onlyFastCharge) {
                    Task { await model.toggleFastCharge() }
                }
                filterChip("极氪自营", isOn: model.selfOnly) {
                    Task { await model.toggleSelfOnly() }
                }
                filterChip("停车免费", isOn: model.parkFree) {
                    Task { await model.toggleParkFree() }
                }
                if model.hasAnyFilter {
                    filterChip("清除", isOn: false) {
                        Task { await model.clearFilters() }
                    }
                }
            }
            .padding(.vertical, 1)
        }
        .scrollIndicators(.hidden)
    }

    /// 一个筛选 chip。
    ///
    /// 不用 `Toggle(.button)`：它的样式在卡片里要么太大，要么和上面的排序胶囊打架。
    /// 选中态用强调色 + 淡底，未选用中性底 —— 两组互斥/开关共用一套外观，好读也好看。
    private func filterChip(
        _ title: String,
        isOn: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11.5, weight: isOn ? .semibold : .regular))
                .foregroundStyle(isOn ? Theme.accent(scheme) : Theme.textSecondary(scheme))
                .padding(.horizontal, 11)
                .padding(.vertical, 6)
                .background(
                    isOn ? Theme.accent(scheme).opacity(0.14) : Theme.surfaceAlt(scheme),
                    in: Capsule()
                )
                // 胶囊本身只有 ~28pt 高，但**点击区**要补到 HIG 的 44pt：
                // frame 放在 background 之后 ⇒ 视觉不变，只有可点范围变大。
                .frame(minHeight: Metrics.minTouchTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // 读屏要能听出"已选中"，否则一排胶囊听起来一模一样
        .accessibilityAddTraits(isOn ? [.isSelected] : [])
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

    /// 站点名 / 起点名放进 URL 查询串时的安全字符集。
    ///
    /// 不能直接用 `.urlQueryAllowed` —— 它**放行 `&` `=` `#`**，
    /// 站点名里出现这些字符会把参数截断，导航到错误的地方。
    private static let queryValueAllowed: CharacterSet = {
        var set = CharacterSet.urlQueryAllowed
        set.remove(charactersIn: "&=?#+")
        return set
    }()

    private static func escape(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: queryValueAllowed) ?? ""
    }

    /// 导航到站点。
    ///
    /// **不用 `iosamap://navi`**：那个接口只接受一个点（`lat`/`lon`），
    /// 没有起点（`sid`/`slat`/`slon`）、也没有终点标识（`did`/`dlat`/`dlon`/`dname`）。
    /// 高德收到这种"只有一个点"的请求，只会把 App 拉起来 ——
    /// 不显示目的地、也不生成路线，正是用户看到的「跳到高德，什么都没发生」。
    ///
    /// 改用 `iosamap://path`（路线规划）：起点终点都给齐，落地页就是带终点
    /// 信息的路线页，点一下开始导航即可。这也顺带满足了"显示目的地详情"。
    ///
    /// `dev=0`：传入坐标已是 GCJ-02（站点坐标来自极氪/浩汉，都是国内加密坐标），
    /// 不能再让高德转一次，否则会偏几百米。
    ///
    /// 兜底：没装高德（`accepted == false`）就退回 H5，并带 `callnative=1`
    /// ——该参数默认 0，不传只会停在网页版。
    private func openNavigation(_ station: ChargingStation) {
        guard let lat = station.lat, let lng = station.lng else {
            hint = "该站点缺少坐标，无法导航"
            return
        }
        // 超范围 / 零值坐标，高德只会静默打开首页。与其跳过去什么都不显示，
        // 不如在这里说清楚。
        guard (-90...90).contains(lat), (-180...180).contains(lng),
              lat != 0, lng != 0 else {
            hint = "该站点坐标异常，无法导航"
            return
        }

        let name = Self.escape(station.displayName)
        var scheme = "iosamap://path?sourceApplication=ZeekrDash"
            + "&did=BGVIS2&dlat=\(lat)&dlon=\(lng)&dname=\(name)"

        // 起点优先取本次查询用的坐标 —— 与服务端算距离用的是同一个点，
        // 路线才和"离我多远"对得上。拿不到就不传，高德会以"我的位置"为起点。
        if let start = model.startPoint,
           (-90...90).contains(start.lat), (-180...180).contains(start.lng) {
            scheme += "&sid=BGVIS1&slat=\(start.lat)&slon=\(start.lng)"
                + "&sname=\(Self.escape("我的位置"))"
        }
        scheme += "&dev=0&t=0"   // t=0：驾车

        let appURL = URL(string: scheme)
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
