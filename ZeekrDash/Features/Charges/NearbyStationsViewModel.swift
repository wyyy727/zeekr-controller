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

    func currentLocation() async throws -> CLLocation {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CLLocation, Error>) in
            self.continuation = continuation
            manager.delegate = self
            // 百米精度足够选充电站，且比最高精度省电、出结果更快
            manager.desiredAccuracy = kCLLocationAccuracyHundredMeters

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

    /// 收口：授权回调与定位回调可能先后都来，而 continuation **只能 resume 一次**
    private func finish(_ result: Result<CLLocation, Error>) {
        guard let continuation else { return }
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
    /// 视野内站点总数（可能大于 `stations.count`）
    var total: Int = 0
    /// 还有下一页（`stations.count < total`）
    var hasMore = false
    /// 正在取下一页，防止滑动时重复触发
    var isLoadingMore = false
    /// 第三方价格服务是否可用
    var isPriceAvailable = true

    /// 每页条数。
    ///
    /// 为什么是 10 而不是 20：取价格是**按站请求**第三方网关的（后端并发 6），
    /// 首屏 10 个只要 2 轮，20 个要 4 轮 —— 这是"充电桩加载慢"的主因。
    /// 用户通常只看最前面几个，剩下的滑到再取。
    private let pageSize = 10
    var sort: Sort = .distance
    /// 当前展开（看分时电价）的站点 ID
    var expanded: String?

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
            stations = MockData.stations
            total = stations.count
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
        state = .loadingStations

        do {
            let data: NearbyStations = try await APIClient.shared.get(
                APIRoutes.stationsNearby,
                query: [
                    "lat": String(lat),
                    "lng": String(lng),
                    "limit": String(pageSize),
                    "offset": "0",
                ]
            )
            stations = data.stations ?? []
            total = data.total ?? stations.count
            hasMore = stations.count < total
            // 显式判 `!= false`：后端不返回该字段时按"可用"处理，避免误报不可用
            isPriceAvailable = data.isPriceAvailable
            state = .loaded
        } catch {
            stations = []
            total = 0
            hasMore = false
            isPriceAvailable = false
            state = .failed(
                (error as? ApiError)?.errorDescription ?? error.localizedDescription
            )
        }
    }

    /// 滑到列表末尾时取下一页。
    ///
    /// 用"是不是最后一个"来触发，而不是给列表加"加载更多"按钮 ——
    /// 用户要的就是继续滑，不该多一次点击。
    func loadMoreIfNeeded(current: ChargingStation) async {
        guard let last = sortedStations.last, last.id == current.id else { return }
        await loadMore()
    }

    func loadMore() async {
        guard hasMore, !isLoadingMore, let coordinate else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }

        do {
            let data: NearbyStations = try await APIClient.shared.get(
                APIRoutes.stationsNearby,
                query: [
                    "lat": String(coordinate.latitude),
                    "lng": String(coordinate.longitude),
                    "limit": String(pageSize),
                    "offset": String(stations.count),
                ]
            )
            let more = data.stations ?? []
            // 按 stationId 去重：正常切片不会重复，但距离相同的站点排序可能抖动
            let seen = Set(stations.map(\.id))
            stations.append(contentsOf: more.filter { !seen.contains($0.id) })

            total = data.total ?? stations.count
            hasMore = !more.isEmpty && stations.count < total
            isPriceAvailable = isPriceAvailable && data.isPriceAvailable
        } catch {
            // 失败就停在当前页，别让 onAppear 反复重试打接口
            hasMore = false
        }
    }

    /// 登出时清空：坐标不该跨会话留存
    func clear() {
        coordinate = nil
        stations = []
        total = 0
        hasMore = false
        isLoadingMore = false
        expanded = nil
        // 手动坐标标记也要清 —— 否则下一位登录者会看到"当前用的是手填坐标"的提示
        usedManualCoordinate = false
        state = .idle
    }

    /// 当前位置是否来自手动输入（界面据此提示"用的是手填坐标"）
    var isUsingManualCoordinate: Bool { usedManualCoordinate }

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
