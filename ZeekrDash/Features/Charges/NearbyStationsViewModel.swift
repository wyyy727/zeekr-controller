//
//  NearbyStationsViewModel.swift
//  ZeekrDash
//
//  附近充电站：定位 → 取站点 → 排序
//

import CoreLocation
import Foundation
import SwiftUI

// MARK: - 一次性定位

/// 取当前位置（一次）。
///
/// 单独封一层而不是写进 ViewModel：`CLLocationManager` 是 delegate 式的回调，
/// 混进 `@MainActor` 的 ViewModel 里会让"授权回调 → 发起定位"这条链显得突兀。
///
/// 只取一次而非持续更新：查附近充电站是一次性需求，开着持续定位既耗电，
/// 又会让"我在哪"这个隐私数据被反复采集 —— 没有理由这么做。
final class LocationFetcher: NSObject, CLLocationManagerDelegate {

    enum FetchError: LocalizedError {
        case denied
        case restricted
        case unavailable(String)

        var errorDescription: String? {
            switch self {
            case .denied:
                return "定位权限被拒绝。可在「设置 › 隐私与安全性 › 定位服务」中重新允许，或手动输入坐标。"
            case .restricted:
                return "定位功能受设备策略限制，无法获取位置。"
            case .unavailable(let detail):
                return "定位失败（\(detail)）。可重试，或手动输入坐标。"
            }
        }
    }

    private enum Phase {
        case idle
        /// 已弹权限框，等用户点完
        case authorizing
        /// 已授权，等定位回调
        case locating
    }

    private let manager = CLLocationManager()
    private var phase: Phase = .idle
    private var continuation: CheckedContinuation<CLLocation, Error>?

    /// 超时兜底任务。
    ///
    /// `requestLocation` 在室内 / 信号差时可能长时间不回调（不是永远不回，但可能几分钟）。
    /// 没有超时的话界面会一直停在「正在定位…」，而且这个 continuation 会一直占着 ——
    /// 用户再点一次，新的 continuation 会把旧的覆盖掉，旧那次就**永久泄漏**了。
    private var timeoutTask: Task<Void, Never>?

    /// 定位最长等待（秒）
    private static let timeout: TimeInterval = 15

    func currentLocation() async throws -> CLLocation {
        // 上一次还没回来就又点了一次：先把旧的收掉，别让它被覆盖后永远挂着
        if continuation != nil {
            finish(.failure(FetchError.unavailable("已取消上一次定位")))
        }

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CLLocation, Error>) in
            self.continuation = continuation
            manager.delegate = self
            // 百米精度足够选充电站，且比最高精度省电、出结果更快
            manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
            startTimeout()

            switch manager.authorizationStatus {
            case .authorizedWhenInUse, .authorizedAlways:
                phase = .locating
                manager.requestLocation()
            case .notDetermined:
                // 先弹权限框，结果由 locationManagerDidChangeAuthorization 接手
                phase = .authorizing
                manager.requestWhenInUseAuthorization()
            case .denied:
                finish(.failure(FetchError.denied))
            case .restricted:
                finish(.failure(FetchError.restricted))
            @unknown default:
                finish(.failure(FetchError.unavailable("定位状态未知")))
            }
        }
    }

    private func startTimeout() {
        timeoutTask?.cancel()
        // 由 MainActor 调用 → 这个 Task 继承主线程上下文
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.timeout * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.finish(.failure(FetchError.unavailable("定位超时")))
        }
    }

    /// 收口：授权回调、定位回调、超时兜底三路都会进来，而 continuation **只能 resume 一次**。
    /// `guard let continuation` 就是那个「只认第一个」的闸门。
    private func finish(_ result: Result<CLLocation, Error>) {
        guard let continuation else { return }
        timeoutTask?.cancel()
        timeoutTask = nil
        self.continuation = nil
        phase = .idle
        continuation.resume(with: result)
    }

    // MARK: CLLocationManagerDelegate

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard phase == .authorizing else { return }
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            phase = .locating
            manager.requestLocation()
        case .denied:
            finish(.failure(FetchError.denied))
        case .restricted:
            finish(.failure(FetchError.restricted))
        default:
            break   // notDetermined：继续等用户点完权限框
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        finish(.success(location))
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        finish(.failure(FetchError.unavailable(error.localizedDescription)))
    }
}

// MARK: - 视图模型

@Observable
@MainActor
final class NearbyStationsViewModel {

    enum LoadState: Equatable {
        /// 还没定位过
        case idle
        case locating
        case loadingStations
        case loaded
        case failed(String)

        var isBusy: Bool {
            switch self {
            case .locating, .loadingStations: return true
            default: return false
            }
        }
    }

    enum Sort: String, CaseIterable, Identifiable {
        case distance
        case price

        var id: String { rawValue }

        var title: String {
            switch self {
            case .distance: return "距离"
            case .price:    return "价格"
            }
        }
    }

    var state: LoadState = .idle
    var stations: [ChargingStation] = []
    /// 候选站点总数（可能大于 `stations.count` —— 后者是已取价并返回的那些）。
    ///
    /// ⚠️ 用了价格类筛选（停车免费）时它只是"候选数"，不是匹配总数，
    /// 界面不能拿它当分母 —— 见 `priceFilterApplied`。
    var total: Int = 0
    /// 还有下一页 —— 由服务端 `hasMore` 给出，不要自己用 `count < total` 猜
    var hasMore = false
    /// 正在取下一页，防止滑动时重复触发
    var isLoadingMore = false
    /// 已有数据时的"就地刷新"（筛选变化 / 重新定位）。
    ///
    /// 与首次加载的 `state == .loadingStations` 分开：首次没有内容可留，
    /// 就地刷新有旧内容可留 —— 后者保留列表、压暗表达更新中，避免闪。
    var isRefreshing = false
    /// 第三方价格服务是否可用
    var isPriceAvailable = true

    /// 每页条数。
    ///
    /// 为什么是 10 而不是 20：取价格是**按站请求**第三方网关的（后端并发 6），
    /// 首屏 10 个只要 2 轮，20 个要 4 轮 —— 这是"充电桩加载慢"的主因。
    /// 用户通常只看最前面几个，剩下的滑到再取。
    private let pageSize = 10

    /// 下一页在**服务端切片**里的起点。
    ///
    /// 不能用 `stations.count` 当 offset：去重会把重复站点滤掉，
    /// 一旦有重复，`stations.count` 就追不上服务端位置，窗口原地打转，
    /// 反复请求同一页 —— 表现就是"一直加载、停不下来"。
    private var nextOffset = 0

    /// 请求序号。
    ///
    /// 取价是**逐站**请求第三方网关的，一页经常要好几秒，所以"连点两个筛选 chip"
    /// 极易产生两个并发请求。没有序号时，"更早发出、条件更旧"的那个后到，
    /// 会把新筛选的结果覆盖掉 —— 界面上 chip 显示「快充 + 自营」，
    /// 列表却是「只有快充」的数据。
    /// 规则：`await` 之后只有"序号仍是最新"的那次才允许写状态。
    private var loadGeneration = 0
    var sort: Sort = .distance
    /// 当前展开（看分时电价）的站点 ID
    var expanded: String?

    /// 附近**最近的一个极氪自营站**，用于收起态第一行那个「最近自营」推荐位。
    ///
    /// 为什么要单独一次请求：首屏只取 10 条，而这 10 条里经常**一个自营站都没有**
    /// （实测附近 50 个站才 11 个自营，最近的那个 1.6 km 排在十几位之后）。
    /// 只从已加载页里挑，第一行就永远退化成「最近」—— 和 HTML 演示数据看到的完全不同。
    /// 服务端支持 `self_only=true` 且按距离升序，`limit=1` 拿一条就够。
    ///
    /// 与当前筛选（快充 / 自营 / 停车免费）**无关**：那一行问的永远是「最近的极氪自营站在哪」。
    var nearestSelf: ChargingStation?

    // MARK: - 筛选

    /// 只看快充（`connector=dc`）。
    ///
    /// **筛选由服务端执行**，不能在前端过滤已加载的这 10 条 ——
    /// 否则"筛出 2 个"会被说成"附近只有 2 个"，那是假信息。
    var onlyFastCharge = false
    /// 只看极氪自营。
    var selfOnly = false
    /// 只看停车免费。
    ///
    /// 这一项与上面两个不同：枪数和自营标记来自极氪气泡接口（零成本），
    /// 而停车费只有第三方电价里才有 —— 属"价格类筛选"，服务端要逐站取价，
    /// 只能扫描有限范围，`total` 因此不再等于匹配总数。
    var parkFree = false

    /// 是否有任一筛选生效
    var hasAnyFilter: Bool { onlyFastCharge || selfOnly || parkFree }

    /// 是否用了价格类筛选 ⇒ 头部不写分母、空结果文案改口径
    private(set) var priceFilterApplied = false

    /// 切换「快充」后重查第一页。
    func toggleFastCharge() async {
        onlyFastCharge.toggle()
        await reload()
    }

    func toggleSelfOnly() async {
        selfOnly.toggle()
        await reload()
    }

    func toggleParkFree() async {
        parkFree.toggle()
        await reload()
    }

    func clearFilters() async {
        guard hasAnyFilter else { return }
        onlyFastCharge = false
        selfOnly = false
        parkFree = false
        await reload()
    }

    /// 换了筛选条件后重查第一页。
    ///
    /// **不调 `locate()` 是常态路径**：条件变了不该再弹一次定位权限框，
    /// 上次的坐标还在内存里，直接拿它重查即可。
    func reload() async {
        guard let coordinate else {
            /* 没有坐标 = 演示模式（`locate()` 在那里直接返回演示数据，从不写坐标），
               或还从没定位过。`locate()` 内部会自己分情况：
               演示模式走本地过滤，真机才去要位置。 */
            await locate()
            return
        }
        await load(lat: coordinate.latitude, lng: coordinate.longitude)
    }

    /// 当前的筛选条件 → 查询参数。
    private var filterQuery: [String: String] {
        var query: [String: String] = [:]
        if onlyFastCharge { query["connector"] = "dc" }
        if selfOnly { query["self_only"] = "true" }
        if parkFree { query["park_free"] = "true" }
        return query
    }

    /// 当前坐标。
    ///
    /// **只活在内存里**：不写 UserDefaults、不进日志、登出即清 ——
    /// 与 `preview/index.html` 的约定一致（那里也是"不落盘、不发给第三方"）。
    private var coordinate: CLLocationCoordinate2D?

    /// 手动输入坐标的兜底存在意义：
    /// 定位被拒、或设备没网/没 GPS 时，没有这条退路充电页就永远是空的。
    private var usedManualCoordinate = false

    // MARK: - 加载

    /// 首次进入页面时调用：只有从未定位过才自动发起。
    ///
    /// 被拒绝之后**不反复自动重试** —— 用户已经明确拒绝过一次，
    /// 每次进页面都重新请求是在骚扰；之后交给「重试定位」按钮。
    func loadIfNeeded() async {
        guard case .idle = state else { return }
        await locate()
    }

    /// 取位置并加载附近站点（用户主动点击 / 首次进入）
    func locate() async {
        // 未登录时服务端会拒绝 /api/stations —— 此时弹权限框纯属骚扰
        guard !AppStore.shared.needsLogin else { return }

        // 模拟数据模式：不联网，也不（不该）去真定位
        guard !SettingsStore.shared.prefersMockData else {
            // 作废可能还在飞的真实请求 —— 否则它回来会把演示数据冲掉
            loadGeneration += 1
            /* 演示模式没有后端可查，筛选只能在本地对全量做。
               规则**必须与后端一致**（枪型/自营看气泡字段，停车费看 price），
               否则会出现"演示里能筛、真机筛不了"的假象。 */
            stations = MockData.stations.filter { station in
                if onlyFastCharge && !((station.dcCount ?? 0) > 0) { return false }
                if selfOnly && station.selfOperate != true { return false }
                if parkFree && station.price?.parkFree != true { return false }
                return true
            }
            total = stations.count
            // 演示数据一次给完，不做分页（也别留下"还有更多"的假动作）
            hasMore = false
            nextOffset = stations.count
            priceFilterApplied = parkFree
            isPriceAvailable = true
            state = .loaded
            return
        }

        guard !state.isBusy else { return }
        state = .locating

        // 定位超时兜底。
        //
        // 为什么需要：权限框弹出来用户一直不点、或 GPS 迟迟不回调时，
        // 上面的 `currentLocation()` 会一直挂着，界面就永远停在「定位中」，
        // 连重试按钮都不给 —— 用户只能杀 App。12 秒后落到可操作的失败态。
        let timeout = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 12_000_000_000)
            guard !Task.isCancelled, let self else { return }
            guard case .locating = self.state else { return }
            self.state = .failed("定位超时。可重试，或手动输入坐标。")
        }

        let fetcher = LocationFetcher()
        do {
            let location = try await fetcher.currentLocation()
            timeout.cancel()
            usedManualCoordinate = false
            await load(lat: location.coordinate.latitude, lng: location.coordinate.longitude)
        } catch {
            timeout.cancel()
            // 定位失败不等于页面坏了：给出具体原因，让用户能自己决定怎么办
            state = .failed(error.localizedDescription)
            stations = []
        }
    }

    /// 手动坐标兜底（"纬度, 经度"，支持中英文逗号与空格分隔）
    @discardableResult
    func applyManualCoordinate(_ text: String) async -> Bool {
        let parts = text
            .components(separatedBy: CharacterSet(charactersIn: ",， 　\t"))
            .filter { !$0.isEmpty }
            .compactMap { Double($0) }

        guard parts.count == 2 else { return false }
        let lat = parts[0]
        let lng = parts[1]
        guard lat >= -90, lat <= 90, lng >= -180, lng <= 180 else { return false }

        usedManualCoordinate = true
        await load(lat: lat, lng: lng)
        return true
    }

    private func load(lat: Double, lng: Double) async {
        coordinate = CLLocationCoordinate2D(latitude: lat, longitude: lng)

        // 每次查询占一个新序号；`await` 之后凭它判断"我还是不是最新的那次"
        loadGeneration += 1
        let generation = loadGeneration

        /* 已有数据时**不切成 `loadingStations`**。
           那个状态会把整张卡（含筛选 chip）换成一行 spinner ——
           用户点一下「快充」，按钮就消失了，回来还得重新找；
           而且列表会先清空再长回来，闪得很明显。
           改为"就地刷新"：保留旧列表，靠压暗 + 顶部进度条表达"在更新"。 */
        if stations.isEmpty {
            state = .loadingStations
        } else {
            isRefreshing = true
        }
        // 只有最新那次才有权收掉「更新中」，否则先完成的旧请求会让指示提前消失
        defer { if generation == loadGeneration { isRefreshing = false } }

        do {
            var query = [
                "lat": String(lat),
                "lng": String(lng),
                "limit": String(pageSize),
                "offset": "0",
            ]
            // 筛选条件交给服务端：它必须在切片之前生效，前端只负责传上去
            query.merge(filterQuery) { _, new in new }

            let data: NearbyStations = try await APIClient.shared.get(
                APIRoutes.stationsNearby,
                query: query
            )
            // 过期响应：期间已有更新的查询发出，这批数据属于旧条件，丢弃
            guard generation == loadGeneration else { return }

            stations = data.stations ?? []
            total = data.total ?? stations.count
            // 服务端给了明确字段就照用，老服务端才回落到推导
            nextOffset = data.nextOffset ?? stations.count
            hasMore = data.hasMore ?? (stations.count < total)
            priceFilterApplied = data.priceFilterApplied ?? false
            // 显式判 `!= false`：后端不返回该字段时按"可用"处理，避免误报不可用
            isPriceAvailable = data.isPriceAvailable
            state = .loaded

            /* 顺手把「最近自营」也查回来。放后台任务里：它有自己的一次网络往返，
               串在这里会让首屏多等一个 RTT（这页本来就慢，取价是逐站请求的）。 */
            Task { [weak self] in await self?.loadNearestSelf() }
        } catch {
            // 过期请求的失败不该清屏 —— 那会把新查询已经拿到的列表抹掉
            guard generation == loadGeneration else { return }
            stations = []
            total = 0
            hasMore = false
            nextOffset = 0
            isPriceAvailable = false
            state = .failed(
                (error as? ApiError)?.errorDescription ?? error.localizedDescription
            )
        }
    }

    /// 拉一次「附近最近的极氪自营站」（见 `nearestSelf` 的说明）。
    ///
    /// 失败一律静默：这只是一条推荐位的兜底来源，拿不到时界面会退回本页里的自营站、
    /// 再拿不到就显示「最近」—— 不该为它弹错误提示或打断正常列表。
    func loadNearestSelf() async {
        guard let coordinate, !SettingsStore.shared.prefersMockData else { return }
        // 与列表同属一次查询：期间换了坐标/筛选就不该再写回来
        let generation = loadGeneration
        let query = [
            "lat": String(coordinate.latitude),
            "lng": String(coordinate.longitude),
            "limit": "1",
            "self_only": "true",
        ]
        do {
            let data: NearbyStations = try await APIClient.shared.get(
                APIRoutes.stationsNearby,
                query: query
            )
            guard generation == loadGeneration else { return }
            nearestSelf = data.stations?.first
        } catch {
            guard generation == loadGeneration else { return }
            nearestSelf = nil
        }
    }

    /// 取下一页。
    ///
    /// 触发点是**展开态列表**滚到最后一行（见 `NearbyStationsView.expandedList`），
    /// 折叠态不触发 —— 折叠时列表底部不在视口里，挂了只会变成"一进页面就自动翻页"。
    func loadMoreIfNeeded(current: ChargingStation) async {
        guard let last = sortedStations.last, last.id == current.id else { return }
        await loadMore()
    }

    func loadMore() async {
        guard hasMore, !isLoadingMore, let coordinate else { return }
        // 记下这页属于哪次查询：翻页途中若改了筛选，这批数据就属于旧条件
        let generation = loadGeneration
        isLoadingMore = true
        defer { isLoadingMore = false }

        do {
            var query = [
                "lat": String(coordinate.latitude),
                "lng": String(coordinate.longitude),
                "limit": String(pageSize),
                "offset": String(nextOffset),
            ]
            // 翻页必须带上同一套筛选条件，否则"筛选后翻页"会混进不符合条件的站
            query.merge(filterQuery) { _, new in new }

            let data: NearbyStations = try await APIClient.shared.get(
                APIRoutes.stationsNearby,
                query: query
            )
            let more = data.stations ?? []
            // 筛选已变：这批属于旧条件，追加进去就是"筛选结果里混进不符合条件的站"
            guard generation == loadGeneration else { return }

            // 按 stationId 去重：正常切片不会重复，但距离相同的站点排序可能抖动
            let seen = Set(stations.map(\.id))
            let fresh = more.filter { !seen.contains($0.id) }
            stations.append(contentsOf: fresh)

            // 游标以服务端为准：价格类筛选时它会跳过被扫描掉的候选
            nextOffset = data.nextOffset ?? (nextOffset + more.count)

            total = data.total ?? stations.count
            priceFilterApplied = data.priceFilterApplied ?? priceFilterApplied
            /* 兜底：本页一条新的都没进来就当作到底。
               若上游忽略 offset 反复回同一页，去重会让 `stations.count` 永远不增长，
               而「已加载 < total」恒成立 ⇒ hasMore 恒真 ⇒ 无限翻页。
               这正是"一直渲染、停不下来"的直接原因。 */
            let serverHasMore = data.hasMore ?? (stations.count < total)
            hasMore = serverHasMore && !fresh.isEmpty && !more.isEmpty
            isPriceAvailable = isPriceAvailable && data.isPriceAvailable
        } catch {
            // 失败就停在当前页；但过期请求不该动新查询的状态
            guard generation == loadGeneration else { return }
            hasMore = false
        }
    }

    /// 登出时清空：坐标不该跨会话留存
    func clear() {
        // 作废在飞的请求：否则它回来会把登出后的列表重新填上
        loadGeneration += 1
        coordinate = nil
        stations = []
        total = 0
        hasMore = false
        isLoadingMore = false
        isRefreshing = false
        nextOffset = 0
        expanded = nil
        nearestSelf = nil
        // 筛选条件也要清 —— 下一位登录者不该继承别人"只看快充"的偏好
        onlyFastCharge = false
        selfOnly = false
        parkFree = false
        priceFilterApplied = false
        // 手动坐标标记也要清 —— 否则下一位登录者会看到"当前用的是手填坐标"的提示
        usedManualCoordinate = false
        state = .idle
    }

    /// 当前位置是否来自手动输入（界面据此提示"用的是手填坐标"）
    var isUsingManualCoordinate: Bool { usedManualCoordinate }

    /// 导航起点（= 本次查询用的坐标）。
    ///
    /// 为什么需要：高德的 `iosamap://navi` 只接受一个点，收不到"从哪出发"，
    /// 于是只把 App 拉起来、不生成路线。`iosamap://path` 这条路要求
    /// 起点终点都给，起点就取这里。
    /// **只读快照，仍然只在内存里** —— 位置不落盘、不进日志。
    var startPoint: (lat: Double, lng: Double)? {
        guard let coordinate else { return nil }
        return (coordinate.latitude, coordinate.longitude)
    }

    // MARK: - 排序与展开

    /// 按当前排序键排好的列表。
    ///
    /// 价格模式用 `.infinity` 把**没有价格的站点永远排最后** ——
    /// 把"没有价格"当 0 排到首位，是这里最典型也最危险的排序错误。
    var sortedStations: [ChargingStation] {
        stations.sorted { a, b in
            if sort == .price {
                let pa = a.price?.totalPrice ?? Double.infinity
                let pb = b.price?.totalPrice ?? Double.infinity
                if pa != pb { return pa < pb }
            }
            return (a.distanceKm ?? 0) < (b.distanceKm ?? 0)
        }
    }

    func toggleExpanded(_ stationId: String) {
        expanded = (expanded == stationId) ? nil : stationId
    }
}
