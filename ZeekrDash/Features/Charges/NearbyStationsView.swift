//
//  NearbyStationsView.swift
//  ZeekrDash
//
//  附近充电站卡片（充电页，v2）
//
//  真源：`preview/index-v2.html` 的 `nearbyStationsCard()`（5759–5820）、
//  `stationPickRows()`（5718–5730）、`v2StationRich/Line`（5652–5700）、
//  `v2StationSheet()`（5734–5757）。样式块 2021–2050。
//
//  数据全部来自服务端 `/api/stations/nearby`：App 既不接触极氪签名，也不接触
//  第三方渠道号 —— 更不会把用户坐标发给第三方（服务端只转 stationId）。
//

import SwiftUI

/// 附近充电站
///
/// 收起态是**三行推荐位**，每行回答一个问题：
///   最近自营（品牌与权益）/ 最便宜快充（省钱）/ 空闲最多（不用排队）。
/// 点某一行 → 它变成高亮行（带导航按钮），其余两行退成简行；
/// 点右上角「N 站 ›」→ 底部 Sheet 里的完整列表（筛选 / 排序 / 分页都在那里）。
struct NearbyStationsCard: View {

    @Environment(\.openURL) private var openURL
    @Environment(AppStore.self) private var store

    /// 附近站点模型由 `AppStore` 持有，**跨 tab 存活**。
    ///
    /// 为什么不放卡片自己的 `@State`：底部 Tab 是 `switch` 切页（见 `RootView.activeScreen`），
    /// 切走时整个 `ChargesView` 会被销毁 —— 卡片里的 `@State` 模型随之消失，
    /// 再切回来就得重新定位（重新弹权限、重新等 GPS、重新拉一遍站）。
    private var model: NearbyStationsViewModel { store.nearbyStations }

    @State private var manualText = ""
    @State private var showManualField = false
    /// 卡片内的行内提示（如坐标格式不对），不占用全局 Toast
    @State private var hint: String?
    /// 已校验通过、等待用户确认的导航目标（防误触）
    @State private var pendingNavigation: ChargingStation?
    @State private var showSheet = false
    /// 当前高亮的是哪一行：`self` / `cheap` / `idle`
    @State private var pickKey = "self"

    var body: some View {
        cardBody
            .task { await model.loadIfNeeded() }
            .modifier(navAlertOnCard)
            .fullScreenCover(isPresented: $showSheet) {
                V2BottomSheet(
                    title: "附近充电站",
                    subtitle: countText,
                    closeTitle: "收起",
                    onClose: { showSheet = false }
                ) {
                    sheetBody
                }
                // 面板是独立 presentation，页面上的自绘弹层盖不到它 —— 里面再挂一份。
                // 两处共用同一个 `pendingNavigation`，由 `isEnabled` 决定谁 present。
                .modifier(navAlertInSheet)
            }
    }

    /// 跳外部地图前的确认弹框（HTML `askNavConfirm`，样式见 `V2AlertCard`）。
    ///
    /// 两处触发点（页面里的推荐行、面板里的完整列表）共用同一个 `pendingNavigation`，
    /// 但弹框是 `fullScreenCover`，同一时刻只能由一个宿主 present ——
    /// 所以按「面板是否打开」二选一，避免两个 cover 撞车。
    private var navAlertOnCard: NavConfirmAlertModifier {
        NavConfirmAlertModifier(station: $pendingNavigation, isEnabled: !showSheet) {
            openNavigation($0)
        }
    }

    private var navAlertInSheet: NavConfirmAlertModifier {
        NavConfirmAlertModifier(station: $pendingNavigation, isEnabled: showSheet) {
            openNavigation($0)
        }
    }

    // MARK: - 卡片

    @ViewBuilder
    private var cardBody: some View {
        if model.state == .idle, model.stations.isEmpty {
            promptCard(
                badge: "待定位",
                note: "查找充电站需要手机定位。位置只用于本次查询 —— 不落盘，也不会发给第三方。",
                action: "获取附近充电站"
            )
        } else if case .failed(let reason) = model.state, model.stations.isEmpty {
            failedCard(reason)
        } else if model.stations.isEmpty, model.state.isBusy {
            skeletonCard
        } else if model.stations.isEmpty {
            emptyCard
        } else {
            listCard
        }
    }

    /// 有站时：标题行 + 三行推荐位
    private var listCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("附近充电站").v2Text(V2Type.title14.bumped())
                Spacer(minLength: 0)
                Button {
                    showSheet = true
                } label: {
                    Text("\(countText) ›")
                        .v2Text(V2Type.segLabelOn.bumped(), color: V2Color.accent)
                }
                .buttonStyle(.plain)
            }

            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(picks.enumerated()), id: \.offset) { _, item in
                    if item.key == activeKey {
                        richRow(item)
                    } else {
                        lineRow(item)
                    }
                }
            }
            .padding(.top, 6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .v2Card()
    }

    private func promptCard(badge: String, note: String, action: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("附近充电站").v2Text(V2Type.title14.bumped())
                Spacer(minLength: 0)
                Text(badge)
                    .v2Text(V2Type.label11.bumped(), color: V2Color.text2)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(V2Color.tintMuted)
                    .clipShape(Capsule())
            }
            Text(note)
                .v2Text(V2Type.label12.bumped(), color: V2Color.text3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
            Button {
                Task { await model.locate() }
            } label: {
                Text(action)
                    .v2Text(V2Type.text12.bumped(), color: V2Color.accent)
                    .frame(maxWidth: .infinity, minHeight: 36)
                    .background(V2Color.tintAccent)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(.plain)
            .padding(.top, 12)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .v2Card()
    }

    private func failedCard(_ reason: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("附近充电站").v2Text(V2Type.title14.bumped())
                Spacer(minLength: 0)
                Text("需定位")
                    .v2Text(V2Type.label11.bumped(), color: V2Color.warn)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(V2Color.tintWarn)
                    .clipShape(Capsule())
            }
            Text(reason)
                .v2Text(V2Type.label12.bumped(), color: V2Color.text3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)

            Button {
                Task { await model.locate() }
            } label: {
                Text("重试定位")
                    .v2Text(V2Type.text12.bumped(), color: V2Color.accent)
                    .frame(maxWidth: .infinity, minHeight: 36)
                    .background(V2Color.tintAccent)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(.plain)
            .padding(.top, 12)

            // 定位被拒时给一条退路：手输坐标，不用去系统设置里翻
            if showManualField {
                HStack(spacing: 8) {
                    TextField("纬度, 经度", text: $manualText)
                        .v2Text(V2Type.label12.bumped())
                        .textFieldStyle(.plain)
                        .keyboardType(.numbersAndPunctuation)
                        .padding(.horizontal, 10)
                        .frame(height: 36)
                        .background(Color.white.opacity(0.55))
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    Button {
                        Task {
                            let ok = await model.applyManualCoordinate(manualText)
                            if ok { showManualField = false } else { hint = "坐标格式不对，示例：31.2304, 121.4737" }
                        }
                    } label: {
                        Text("使用")
                            .v2Text(V2Type.text12.bumped(), color: V2Color.text1)
                            .padding(.horizontal, 14)
                            .frame(height: 36)
                            .background(Color.white.opacity(0.55))
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.top, 8)
            } else {
                Button("或手动输入坐标") { showManualField = true }
                    .v2Text(V2Type.label11.bumped(), color: V2Color.text3)
                    .buttonStyle(.plain)
                    .padding(.top, 8)
            }

            if let hint {
                Text(hint)
                    .v2Text(V2Type.label11.bumped(), color: V2Color.bad)
                    .padding(.top, 6)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .v2Card()
    }

    private var skeletonCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("附近充电站").v2Text(V2Type.title14.bumped())
                Spacer(minLength: 0)
                Text("加载中")
                    .v2Text(V2Type.label11.bumped(), color: V2Color.text2)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(V2Color.tintMuted)
                    .clipShape(Capsule())
            }
            GeometryReader { proxy in
                VStack(alignment: .leading, spacing: 12) {
                    SkeletonBar(width: proxy.size.width * 0.70)
                    SkeletonBar(width: proxy.size.width * 0.35)
                    SkeletonBar(width: proxy.size.width * 0.55)
                }
                .padding(.top, 8)
            }
            .frame(height: 66 + 8)
            Text("正在查找附近充电站…")
                .v2Text(V2Type.label11.bumped(), color: V2Color.text3)
                .padding(.top, 4)
        }
        .v2Card()
    }

    /// 空结果**不能**说成「附近没有充电站」—— 有筛选时站是有的，只是不符合条件
    private var emptyCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("附近充电站").v2Text(V2Type.title14.bumped())
                Spacer(minLength: 0)
                Text(model.hasAnyFilter ? "已筛选" : "无数据")
                    .v2Text(V2Type.label11.bumped(), color: V2Color.text2)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(V2Color.tintMuted)
                    .clipShape(Capsule())
            }
            Text(model.hasAnyFilter
                 ? "附近没有符合当前筛选条件的站。放宽条件或清除筛选再看看。"
                 : (hint ?? "附近没有查到充电站。"))
                .v2Text(V2Type.label12.bumped(), color: V2Color.text3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)

            Button {
                Task {
                    if model.hasAnyFilter { await model.clearFilters() } else { await model.locate() }
                }
            } label: {
                Text(model.hasAnyFilter ? "清除筛选" : "重新定位")
                    .v2Text(V2Type.text12.bumped(), color: V2Color.accent)
                    .frame(maxWidth: .infinity, minHeight: 36)
                    .background(V2Color.tintAccent)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(.plain)
            .padding(.top, 12)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .v2Card()
    }

    // MARK: - 三行推荐位（`pickNearby()`，5690–5716）

    private struct Pick {
        let key: String
        let label: String
        let site: ChargingStation
    }

    /// 三个不同站点回答三个问题；同一站不重复出现（重复会让人以为列表坏了）
    private var picks: [Pick] {
        let sorted = model.sortedStations
        var used = Set<String>()

        func freeGuns(_ s: ChargingStation) -> Int {
            (s.ableDcCount ?? 0) + (s.ableAcCount ?? 0)
        }
        func take(_ station: ChargingStation?) -> ChargingStation? {
            guard let station else { return nil }
            used.insert(station.stationId)
            return station
        }

        /* 「最近自营」不能只从已加载的这一页里挑：首屏 10 条经常**一个自营站都没有**
           （实测附近 50 个站里才 11 个自营，最近的那个 1.6 km 排在十几位之后），
           于是第一行永远退化成「最近」，用户看到的就和 HTML 演示数据不一样了。
           这里多一次 `self_only=true&limit=1` 的单站查询（服务端已按距离升序），
           查到就用它；查不到（未登录 / 价格服务挂了）再退回本页里的自营站。 */
        let selfPick = take(sorted.first { !used.contains($0.stationId) && $0.selfOperate == true })
            ?? take(model.nearestSelf)
        /* 最便宜的快充：必须有价、必须是快充；缺价的站不能当 0 元排到第一 */
        let cheap = take(sorted
            .filter { !used.contains($0.stationId) && ($0.dcCount ?? 0) > 0 && $0.price?.totalPrice != nil }
            .sorted {
                let a = $0.price?.totalPrice ?? .infinity
                let b = $1.price?.totalPrice ?? .infinity
                if a != b { return a < b }
                return ($0.distanceKm ?? 0) < ($1.distanceKm ?? 0)
            }
            .first)
        let idle = take(sorted
            .filter { !used.contains($0.stationId) && freeGuns($0) > 0 }
            .sorted {
                if freeGuns($0) != freeGuns($1) { return freeGuns($0) > freeGuns($1) }
                return ($0.distanceKm ?? 0) < ($1.distanceKm ?? 0)
            }
            .first)

        var rows: [Pick] = []
        // 没有自营站时第一行退化为「最近的站」—— 空着比退一步更糟
        if let site = selfPick ?? sorted.first {
            rows.append(Pick(key: "self", label: selfPick == nil ? "最近" : "最近自营", site: site))
        }
        if let cheap { rows.append(Pick(key: "cheap", label: "最便宜快充", site: cheap)) }
        if let idle { rows.append(Pick(key: "idle", label: "空闲最多", site: idle)) }
        return rows
    }

    /// 高亮行可能被筛选掉了（比如筛成只有慢充），这时退回第一行
    private var activeKey: String {
        picks.contains(where: { $0.key == pickKey }) ? pickKey : "self"
    }

    /// 高亮行：名称 + 自营徽章 + 距离/枪数 + 价格 + 导航
    private func richRow(_ item: Pick) -> some View {
        let station = item.site
        let price = station.price?.totalPrice

        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    /* 推荐标签是**淡紫胶囊**，不是斜体纯文字：HTML 用 `<i class="v2-st-pick">`，
                       样式在 index-v2.html:2047-2049（10px/600、accent 字、#EEF0FE 底、
                       1px 6px 内边距、999 圆角、右侧 6px 间距）。
                       本项目曾误判成「没有样式规则、就是 <i> 的默认斜体」并照斜体实现了一遍 —— 已纠正。 */
                    Text(item.label)
                        .v2Text(V2Type.pickTag10.bumped(), color: V2Color.accent)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(V2Color.chipFill)
                        .clipShape(Capsule())
                    Text(station.displayName)
                        .v2Text(V2Type.recName13.bumped(), color: V2Color.text1)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if station.selfOperate == true, item.label != "最近自营" {
                    Text("自营")
                        .v2Text(V2Type.stTag10.bumped(), color: V2Color.warn)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(V2Color.tintWarn)
                        .clipShape(Capsule())
                }
            }

            HStack(alignment: .center, spacing: 10) {
                Text(metaText(station))
                    .v2Text(V2Type.label12.bumped(), color: V2Color.text3)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if let price {
                    HStack(alignment: .firstTextBaseline, spacing: 1) {
                        Text("¥" + String(format: "%.2f", price))
                            .v2Text(V2Type.segLabelOn.bumped(), color: V2Color.info)
                            .v2Numeric()
                        Text("/kWh")
                            .v2Text(V2Type.stUnit11.bumped(), color: V2Color.text3)
                    }
                } else {
                    // 缺价时是 `.p` 的规格换了颜色（12/600 #666F7E），不是小一号的灰字
                    Text("价格 --")
                        .v2Text(V2Type.segLabelOn.bumped(), color: V2Color.text3)
                }
                Button {
                    requestNavigation(station)
                } label: {
                    /* `.v2-btn.primary.sm`：覆盖 `.v2-btn` 的 12/18 成 11/16，内边距 4×10 */
                    Text("导航")
                        .v2Text(V2Type.navSm11.bumped(), color: .white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(V2Color.accent)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.white.opacity(0.28))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.vertical, 3)
    }

    /// 简行：点一下就变成高亮行
    private func lineRow(_ item: Pick) -> some View {
        let station = item.site
        let price = station.price?.totalPrice

        return Button {
            pickKey = item.key
        } label: {
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    // 与高亮行同一枚 `.v2-st-pick` 胶囊（10/600、accent on #EEF0FE）
                    Text(item.label)
                        .v2Text(V2Type.pickTag10.bumped(), color: V2Color.accent)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(V2Color.chipFill)
                        .clipShape(Capsule())
                    Text(station.displayName)
                        .v2Text(V2Type.label12.bumped(), color: V2Color.text1)
                        .lineLimit(1)
                    // `.v2-st-line .n em`：枪数是 11/500 #666F7E，比站名小一号、更淡
                    if let guns = gunText(station) {
                        Text(guns)
                            .v2Text(V2Type.stInfo11.bumped(), color: V2Color.text3)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                Text(distanceText(station))
                    .v2Text(V2Type.xAxis11.bumped(), color: V2Color.text3)
                    .v2Numeric()
                Text(price.map { "¥" + String(format: "%.2f", $0) } ?? "--")
                    .v2Text(V2Type.segLabelOn.bumped(), color: V2Color.info)
                    .v2Numeric()
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 底部 Sheet（完整列表）

    private var sheetBody: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text((model.isPriceAvailable
                     ? "点卡片看分时电价"
                     : "价格服务暂时不可用，以下仅显示距离与枪数。"))
                    .v2Text(V2Type.label11.bumped(), color: V2Color.text3)
                Spacer(minLength: 0)
                sortSegmented
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)

            // 筛选 chip：两组互斥，点已选中的即取消（不额外加「不限」按钮）
            HStack(spacing: 6) {
                filterChip("快充", on: model.onlyFastCharge) {
                    Task { await model.toggleFastCharge() }
                }
                filterChip("极氪自营", on: model.selfOnly) {
                    Task { await model.toggleSelfOnly() }
                }
                filterChip("停车免费", on: model.parkFree) {
                    Task { await model.toggleParkFree() }
                }
                if model.hasAnyFilter {
                    filterChip("清除", on: false) {
                        Task { await model.clearFilters() }
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)

            /* 列表固定高度自己滚：筛选改变行数时**卡片高度不能跳**。
               分页由内层滚到底触发，页面滚动不参与。 */
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(model.sortedStations) { station in
                        // 最后一行不画分隔线（`.st:last-child`），其余行自己画 1px 实色线
                        sheetRow(
                            station,
                            showsDivider: station.stationId != model.sortedStations.last?.stationId
                        )
                        .task { await model.loadMoreIfNeeded(current: station) }
                    }
                    if model.isLoadingMore {
                        Text("正在加载更多…")
                            .v2Text(V2Type.label11.bumped(), color: V2Color.text3)
                            .padding(.vertical, 10)
                    } else if !model.hasMore, !model.sortedStations.isEmpty {
                        Text("已全部显示")
                            .v2Text(V2Type.label11.bumped(), color: V2Color.text3)
                            .padding(.vertical, 10)
                    }
                }
                .padding(.horizontal, 16)
            }
            .frame(maxHeight: .infinity)

            Text("位置仅用于本次查询，不落盘、不发给第三方。")
                .v2Text(V2Type.label11.bumped(), color: V2Color.text3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
        }
    }

    private var sortSegmented: some View {
        HStack(spacing: 0) {
            ForEach(NearbyStationsViewModel.Sort.allCases) { item in
                let on = model.sort == item
                Button {
                    model.sort = item
                } label: {
                    Text(item.title)
                        .v2Text((on ? V2Type.segLabelOn : V2Type.segLabel).bumped(),
                                color: on ? V2Color.text1 : V2Color.text3)
                        .frame(maxWidth: .infinity)
                        .frame(height: 24)
                        .background {
                            if on {
                                RoundedRectangle(cornerRadius: V2Metrics.segThumbRadius, style: .continuous)
                                    .fill(Color.white.opacity(0.95))
                                    .shadow(color: Color(hex: 0x4A5778).opacity(0.16), radius: 3, x: 0, y: 2)
                            }
                        }
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? AccessibilityTraits.isSelected : [])
            }
        }
        .padding(V2Metrics.segInset)
        .frame(width: V2Metrics.segWidth, height: V2Metrics.segHeight)
        .glassSurface(cornerRadius: V2Metrics.segRadius)
    }

    /// 筛选 chip（`.v2-sheet .st-chip`，index-v2.html:2152-2155）
    ///
    /// 高 28、12 号字、1px #E7EBF3 描边、999 圆角；选中态是**淡紫底 + accent 字**
    /// （`rgba(103,66,232,.12)` 底 + 字变 accent 600），不是实色紫底白字 —— 后者在这里
    /// 比 HTML 抢眼太多，而且白字配 12 号在浅底上会显得更小。
    private func filterChip(_ title: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .v2Text((on ? V2Type.segLabelOn : V2Type.segLabel).bumped(),
                        color: on ? V2Color.accent : V2Color.text2)
                .padding(.horizontal, 8)
                .frame(height: 28)
                .background(on ? V2Color.accent.opacity(0.12) : Color.white)
                .overlay(
                    Capsule().stroke(on ? V2Color.accent.opacity(0.24) : V2Color.hairline,
                                     lineWidth: 1)
                )
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 展开列表的行（`.v2-sheet-list` 覆盖块：index-v2.html 2157-2186）
    //
    // ⚠️ 这一组是**覆盖值**，不是 :649-720 那套旧的 `.st` 基础样式，也不是收起态那三行的
    // `.v2-st`：站名/价格从 15 号压到 13 号、单位 11 号，行间是 1px 实色发丝线（不是间距），
    // 行内**没有**导航按钮 —— 导航只出现在展开区里、全宽一个。
    // 早先照旧样式实现，表现正是用户说的「整体比 HTML 小一号」+「展开只剩 4 行摘要」。

    private func sheetRow(_ station: ChargingStation, showsDivider: Bool) -> some View {
        let isOpen = model.expanded == station.stationId

        return VStack(alignment: .leading, spacing: 0) {
            sheetHead(station)
            sheetMeta(station)
            if isOpen { sheetDetail(station) }
        }
        .padding(.vertical, 2)
        .frame(minHeight: 42, alignment: .top)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) {
            // `.st:last-child { border-bottom: 0 }`
            if showsDivider {
                Rectangle()
                    .fill(V2Color.hairline)
                    .frame(height: 1)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { model.toggleExpanded(station.stationId) }
    }

    /// 行头：站名 + 价格（`.st-head` / `.st-name` / `.st-price`）
    ///
    /// 价格是「¥1.90」+ 11 号「/度」拼出来的一行，右对齐、不换行；
    /// 无价时整块退成 11/500 的灰字「价格 --」（`.st-price.na`）。
    private func sheetHead(_ station: ChargingStation) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(station.displayName)
                .v2Text(V2Type.stName13.bumped(), color: V2Color.text1)
                .lineLimit(2)
            Spacer(minLength: 8)
            if let price = station.price?.totalPrice {
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    Text("¥" + String(format: "%.2f", price))
                        .v2Text(V2Type.stName13.bumped(), color: V2Color.info)
                        .v2Numeric()
                    Text("/度")
                        .v2Text(V2Type.stUnit11.bumped(), color: V2Color.info)
                }
                .fixedSize()
            } else {
                Text("价格 --")
                    .v2Text(V2Type.stUnit11.bumped(), color: V2Color.muted)
                    .fixedSize()
            }
        }
    }

    /// 元信息行：距离 · 枪数 · 评分 · 自营（`.st-meta`，11/500、项间 4pt）
    ///
    /// 上游的 tags 在这里**不显示**（`.st-tag.t { display: none }`）—— 它们是充电站的
    /// 运营商/设施标签，展开列表这么密的地方再塞会挤掉枪数。
    private func sheetMeta(_ station: ChargingStation) -> some View {
        HStack(spacing: 4) {
            Text(distanceText(station))
                .v2Text(V2Type.stMeta11.bumped(), color: V2Color.text3)
            if let guns = gunText(station) {
                // 一个可用枪都没有时压暗（`.st-meta .gone`）—— 仍然要显示，让人自己判断去不去
                Text(guns)
                    .v2Text(V2Type.stMeta11.bumped(), color: hasFreeGun(station) ? V2Color.text3 : V2Color.muted)
            }
            if let score = scoreText(station) {
                Text("评分 \(score)")
                    .v2Text(V2Type.stMeta11.bumped(), color: V2Color.text3)
            }
            if station.selfOperate == true {
                Text("自营")
                    .v2Text(V2Type.stTag10.bumped(), color: V2Color.warn)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(V2Color.tintWarn)
                    .clipShape(Capsule())
            }
            Spacer(minLength: 0)
        }
        .lineLimit(1)
        .padding(.top, 2)
    }

    /// 展开区：分时电价表 + 枪数/地址 + 备注 + 全宽「导航到这里」
    ///
    /// 出处：`stationDetail()`（index-v2.html:5601-5639）。左侧统一缩进 8pt，
    /// 这是 HTML 里 `.st-periods / .st-info / .st-note / .st-actions` 共有的 margin-left。
    private func sheetDetail(_ station: ChargingStation) -> some View {
        let price = station.price

        return VStack(alignment: .leading, spacing: 0) {
            sheetPeriods(price)

            // `.st-info`：枪数一行 + 地址一行（列表行放不下地址）
            VStack(alignment: .leading, spacing: 2) {
                if let guns = gunText(station) {
                    Text(guns)
                        .v2Text(V2Type.stInfo11.bumped(), color: V2Color.text3)
                }
                if let address = station.address, !address.isEmpty {
                    Text(address)
                        .v2Text(V2Type.stInfo11.bumped(), color: V2Color.text3)
                }
            }
            .padding(.leading, 8)
            .padding(.top, 2)

            // `.st-note`：费用说明 / 停车 / 占位费，HTML 用 <br> 连成一段
            let notes = noteLines(price)
            if !notes.isEmpty {
                Text(notes.joined(separator: "\n"))
                    .v2Text(V2Type.stNote11.bumped(), color: V2Color.muted)
                    .padding(.leading, 8)
                    .padding(.top, 4)
                    .padding(.bottom, 2)
            }

            Button {
                requestNavigation(station)
            } label: {
                Text("导航到这里")
                    .v2Text(V2Type.stBtn13.bumped(), color: .white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .background(V2Color.accent)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
            .padding(.leading, 8)
            .padding(.top, 6)
            .padding(.bottom, 4)
        }
    }

    /// 分时电价表（`.st-periods`：列间距 6、行高 22）
    private func sheetPeriods(_ price: StationPrice?) -> some View {
        let periods = price?.periods ?? []

        return VStack(alignment: .leading, spacing: 6) {
            if price == nil {
                periodRow(time: "该站点暂时取不到价格", value: "--", now: false)
            } else if periods.isEmpty {
                periodRow(time: "分时电价未提供", value: "--", now: false)
            } else {
                ForEach(periods.indices, id: \.self) { index in
                    let period = periods[index]
                    let now = period.isCurrent(price?.currentPeriod)
                    periodRow(
                        time: (period.timeFrame ?? "--") + (now ? " · 当前" : ""),
                        value: period.total.map { String(format: "%.2f", $0) + " 元/度" } ?? "--",
                        now: now
                    )
                }
            }
        }
        .padding(.leading, 8)
        .padding(.top, 6)
        .padding(.bottom, 2)
    }

    /// 电价表的一行。当前段：高 24、左右 6、淡蓝底 #E9F6FD、600、accent 字；
    /// 其余行：高 22、11/500、左灰右深。
    private func periodRow(time: String, value: String, now: Bool) -> some View {
        HStack(spacing: 8) {
            Text(time)
                .v2Text((now ? V2Type.stPeriodNow11 : V2Type.stPeriod11).bumped(),
                        color: now ? V2Color.info : V2Color.text3)
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(value)
                .v2Text((now ? V2Type.stPeriodNow11 : V2Type.stPeriod11).bumped(),
                        color: now ? V2Color.info : V2Color.text1)
                .v2Numeric()
        }
        .padding(.horizontal, now ? 6 : 0)
        .frame(height: now ? 24 : 22)
        .background {
            if now {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(V2Color.tintInfo)
            }
        }
    }

    // MARK: - 文案

    /// 头部计数：价格类筛选时不能写分母（服务端只扫固定范围，total 是候选数）
    private var countText: String {
        if model.priceFilterApplied { return "\(model.stations.count) 站 · 已筛选" }
        if model.hasMore || model.stations.count < model.total {
            return "\(model.stations.count) / \(model.total) 站"
        }
        return "\(model.total) 站"
    }

    /// 展开区备注（HTML `stationDetail()` 里 notes 的三条来源）
    private func noteLines(_ price: StationPrice?) -> [String] {
        guard let price else { return [] }
        var lines: [String] = []
        if let desc = price.feeDesc, !desc.isEmpty { lines.append(desc) }
        if let parking = price.parkingFee, !parking.isEmpty {
            lines.append("停车：\(parking)" + (price.parkFree == true ? "（免费）" : ""))
        }
        if price.holdFee == true { lines.append("超时占用另收占位费") }
        return lines
    }

    /// 评分。浩汉对所有站一律返回 3.8（实测 20 站全一样），那是上游兜底分、
    /// 不是真实评价 —— 全站同分没有信息量，3.8 不显示；真出现 4.6 这种差异化评分照常显示。
    private func scoreText(_ station: ChargingStation) -> String? {
        guard let score = station.score, score > 0, score != 3.8 else { return nil }
        return String(format: "%g", score)
    }

    /// 有没有一个可用枪（CSS `.st-meta .gone` 的判定：总枪数 > 0 且可用为 0）
    private func hasFreeGun(_ station: ChargingStation) -> Bool {
        guard let total = station.totalCount, total > 0 else { return true }
        return (station.availableCount ?? -1) != 0
    }

    private func distanceText(_ station: ChargingStation) -> String {
        guard let km = station.distanceKm else { return "--" }
        return String(format: "%.2f km", km)
    }

    /// 枪数文案（HTML `stationRow()` 5555-5560）。
    ///
    /// 两条规矩：① 快慢充分开写，各自「可用/总数」；② 上游没给快慢充分类时退回总枪数
    /// 「可用 a/t」—— 不能显示成「0/x」，那会让人白白放弃一个站。
    private func gunText(_ station: ChargingStation) -> String? {
        var parts: [String] = []
        if let dc = station.dcCount, dc > 0 {
            parts.append("快充 \(station.ableDcCount.map(String.init) ?? "--")/\(dc)")
        }
        if let ac = station.acCount, ac > 0 {
            parts.append("慢充 \(station.ableAcCount.map(String.init) ?? "--")/\(ac)")
        }
        if parts.isEmpty, let total = station.totalCount, total > 0 {
            parts.append("可用 \(station.availableCount.map(String.init) ?? "--")/\(total)")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func metaText(_ station: ChargingStation) -> String {
        [distanceText(station), gunText(station)].compactMap { $0 }.joined(separator: " · ")
    }

    // MARK: - 导航

    /// 点「导航」只走这里：校验通过后落到确认弹框，确认了才真正离开 App。
    private func requestNavigation(_ station: ChargingStation) {
        guard let lat = station.lat, let lng = station.lng else {
            hint = "该站点缺少坐标，无法导航"
            return
        }
        guard (-90...90).contains(lat), (-180...180).contains(lng), lat != 0, lng != 0 else {
            hint = "该站点坐标异常，无法导航"
            return
        }
        pendingNavigation = station
    }

    /// 导航到站点。
    ///
    /// **不用 `iosamap://navi`**：那个接口只接受一个点，没有起点、也没有终点标识。
    /// 高德收到这种"只有一个点"的请求只会把 App 拉起来 —— 不显示目的地、也不生成路线。
    /// 改用 `iosamap://path`（路线规划）：起点终点都给齐，落地页就是带终点信息的路线页。
    ///
    /// `dev=0`：传入坐标已是 GCJ-02（站点坐标来自极氪/浩汉，都是国内加密坐标），
    /// 不能再让高德转一次，否则会偏几百米。
    /// 兜底：没装高德（`accepted == false`）就退回 H5，并带 `callnative=1`。
    private func openNavigation(_ station: ChargingStation) {
        guard let lat = station.lat, let lng = station.lng else { return }

        let name = Self.escape(station.displayName)
        var scheme = "iosamap://path?sourceApplication=ZeekrDash"
            + "&did=BGVIS2&dlat=\(lat)&dlon=\(lng)&dname=\(name)"

        // 起点优先取本次查询用的坐标 —— 与服务端算距离用的是同一个点
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
            guard !accepted, let webURL else { return }
            openURL(webURL)
        }
    }

    /// 站名里可能有 `&`、空格 —— 直接拼进 URL 会截断参数
    private static func escape(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? text
    }
}

// MARK: - 导航确认框

/// 文案逐字照抄 `index-v2.html:5921–5927`：
/// 标题「用地图导航？」、说明「将打开地图 App 规划到「X」的驾车路线，会离开 ZeekrDash。」、
/// 左「取消」右「打开地图」。
///
/// 站名回退用 **`name`**（缺省「充电站」），不是 `displayName` ——
/// 后者缺省是「未命名站点」，与 HTML 不一致。
private struct NavConfirmAlertModifier: ViewModifier {

    @Binding var station: ChargingStation?
    var isEnabled: Bool = true
    let onConfirm: (ChargingStation) -> Void

    func body(content: Content) -> some View {
        content.v2Alert(
            item: $station,
            isEnabled: isEnabled,
            title: { _ in "用地图导航？" },
            message: { target in
                let name: String
                if let raw = target.name, !raw.isEmpty {
                    name = raw
                } else {
                    name = "充电站"
                }
                return "将打开地图 App 规划到「\(name)」的驾车路线，会离开 ZeekrDash。"
            },
            confirmTitle: "打开地图",
            onConfirm: onConfirm
        )
    }
}
