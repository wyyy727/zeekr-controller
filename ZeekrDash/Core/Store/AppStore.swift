//
//  AppStore.swift
//  ZeekrDash
//
//  全局状态：车辆状态、加载、错误、上次刷新；轮询固定 5 分钟（充电中 60 秒，与网页一致）
//
//  数据来源（DataMode）：
//
//    mock    —— 地址未配置或指向 localhost，直接用本地模拟数据，不联网
//    live    —— 配置了真实地址且请求成功
//    offline —— 配置了真实地址但连不上，已回落模拟数据并提示用户
//
//  回落策略：只有当用户真的填了远程地址、却请求失败时才回落，
//  并且会弹框告知一次（避免用户误以为看到的是真车数据）。
//

import SwiftUI

/// 当前页面数据的实际来源
enum DataMode: Equatable {
    /// 本地模拟数据（地址未配置 / 指向 localhost）
    case mock
    /// 真实服务端数据
    case live
    /// 配置了真实地址但连不上，已回落模拟数据
    case offline

    /// 顶栏徽标文案；返回 nil 表示不展示徽标（真实数据无需标识）
    var badgeText: String? {
        switch self {
        case .mock:    return "模拟数据"
        case .offline: return "模拟数据 · 后端不可达"
        case .live:    return nil
        }
    }
}

@Observable
@MainActor
final class AppStore {

    static let shared = AppStore(settings: SettingsStore.shared)

    // MARK: - 状态

    var vehicleStatus: VehicleStatus?
    var isLoading = false
    var errorMessage: String?
    var lastRefresh: Date?

    /// 车辆位置（坐标 + 地址 + 上报时间）。
    ///
    /// **它不是实时位置**：车静止时网关不更新坐标，`reportedAt` 可能滞后几十分钟，
    /// 界面上必须显示上报时间。坐标已由服务端转成 GCJ-02，客户端不要再转。
    var vehicleLocation: VehicleLocation?

    /// 位置卡的地图缩略图字节（服务端代取腾讯，key 不落客户端）。
    /// 取不到就是 nil —— 卡片退回纯文字，不显示破图。
    var locationMapData: Data?

    /// 位置接口本身失败时的提示。
    ///
    /// 为什么要单独一个字段：`vehicleLocation == nil` 既可能是「还没加载」，
    /// 也可能是「加载失败」。两者在界面上必须区分 —— 否则请求一直失败时，
    /// 卡片会永远停在「正在获取位置…」，看起来像卡死。
    var locationError: String?

    /// 车辆所在地的天气（只用来顶「当地气温」那一格）。
    ///
    /// 车端 `climateStatus.exteriorTemp` 实测恒为空，这版固件不上报 ——
    /// 所以这个数是按位置查来的，**不是车外实测温度**。
    /// 取不到就是 nil，界面显示 `--`，绝不用 0℃ 顶替。
    /// 失败**不影响** `dataMode`：少一个数字不该把整页打成"离线"。
    var weather: WeatherInfo?

    /// 全局 Toast 文案（车控指令回执等），由 RootView 统一呈现
    var toast: String?

    /// 当前数据来源；真实地址连不上时会停留在 .offline
    var dataMode: DataMode = .mock

    /// 车辆能力集。
    ///
    /// nil = 服务端没拿到（网关没回或解析失败）。此时 `isCapabilityAvailable`
    /// 一律返回 true —— 宁可多显示，也不隐藏这台车其实支持的按钮。
    var capabilities: [String: Bool]?

    /// 权限包原始 ID 列表（与 `capabilities` 同一次请求返回）。
    /// 设置页用它如实展示「这台车开通了什么」—— 没有它，
    /// 「某个按钮为什么不见了」就没法解释。
    var permissions: [String]?

    /// 预约充电计划（`/api/vehicle/capability` 的 `chargePlan`）。
    /// 取不到就是 nil，充电页不渲染这张卡 —— 不编造"已启用"。
    var chargePlan: ChargePlan?

    /// 后端可达、但尚未登录 —— 此时**一个数据接口都不调**。
    ///
    /// 对齐 `preview/index.html` 的 `needLogin` 态：live 模式下服务端要求登录，
    /// 未登录时调车况 / 行程 / 充电只会失败，还会把服务端日志刷满无意义的报错。
    /// 更糟的是旧实现会把这种失败当成「后端不可达」从而**回落模拟数据** ——
    /// 那等于把「没登录」伪装成「网络故障」，还给用户看了一份假车况。
    var needsLogin = false

    /// 附近充电站的视图模型。
    ///
    /// 为什么放在这里而不是让 `NearbyStationsCard` 自己 `@State` 一个：
    /// 底部 Tab 是 `switch` 切页（见 `RootView.activeScreen`），切走时整个
    /// `ChargesView` 会被销毁 —— 卡片里的 `@State` 模型随之消失，
    /// 再切回来就得**重新定位一次**（重新弹权限、重新等 GPS、重新拉一遍站）。
    /// 用户抱怨的"每次进充电页都重新定位"就是这么来的。
    ///
    /// 放在这里就跨 tab 存活了：切走再回来，看到的还是上次的站，
    /// 想换位置点「重新定位」即可。
    ///
    /// 隐私：坐标只在内存里，登出时随 `needsLogin` 分支一起清掉（见下）。
    var nearbyStations = NearbyStationsViewModel()

    /// 当前选中的底部 Tab。
    ///
    /// 放在这里而不是 RootView 的 `@State`，是为了让车况页的登录引导能直接
    /// 把用户送到「设置」页（登录入口在那里）。
    var selectedTab: AppTab = .dashboard

    /// 需要在界面上弹框告知的数据源变化（由 RootView 消费后置回 nil）
    var pendingDataSourceNotice: String?

    private var toastTask: Task<Void, Never>?
    /// 已经为「当前这个地址」提示过回落，避免每次轮询都弹一次
    private var didNotifyFallback = false

    /// 是否已成功拿到过数据
    var hasData: Bool { vehicleStatus != nil }

    /// 充电中（决定轮询节奏）
    var isCharging: Bool { vehicleStatus?.isCharging == true }

    /// 顶栏徽标文案（nil 表示不显示）
    var modeBadgeText: String? { dataMode.badgeText }

    private let settings: SettingsStore
    private var pollTask: Task<Void, Never>?
    /// 上一次取地图图用的坐标键。
    ///
    /// 服务端已按坐标缓存，但客户端每轮轮询都重下 ~100KB 是白费流量 ——
    /// 坐标没变就不重复下载。失败时清空，让下一轮能再试。
    private var lastMapKey: String?

    init(settings: SettingsStore) {
        self.settings = settings
        // 首次进入按地址形态定基线；真实地址要等第一次请求才知道通不通
        dataMode = settings.prefersMockData ? .mock : .live
    }

    // MARK: - 手动刷新

    func refresh() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        // ① 地址未配置 / 指向 localhost：直接用模拟数据，不发起请求
        guard !settings.prefersMockData else {
            needsLogin = false
            applyMockData()
            return
        }

        // ② 先确认登录态 —— 唯一无条件允许的请求就是 /api/auth/status，
        //    不查它就无法判断该显示登录引导还是数据。
        do {
            let auth: AuthStatus = try await APIClient.shared.get(APIRoutes.authStatus)
            // 服务端自己处于 mock 态时不做登录门禁（它没有真实账号可登）
            if auth.authenticated != true && auth.mock != true {
                needsLogin = true
                vehicleStatus = nil
                // 没登录就没有权限包可言 —— 留着上一轮的会让设置页显示别人的清单
                capabilities = nil
                permissions = nil
                chargePlan = nil
                // 位置是更敏感的个人数据：上一会话的车停在哪，绝不能留给下一位
                vehicleLocation = nil
                locationMapData = nil
                locationError = nil
                // 气温是按定位查的，同属"车在哪"的衍生信息，换人登录不该沿用
                weather = nil
                // 附近站点带着用户的实时坐标 —— 同属位置隐私，换人登录必须清空
                nearbyStations.clear()
                // 充电流水的「同步于 XX:XX」也不该沿用上一位的时间，
                // 而且不清会让"跨天才同步"误以为今天已经同步过了
                ChargeSyncStamp.clear()
                dataMode = .live
                return
            }
            needsLogin = false
        } catch let error as ApiError {
            fallbackToMock(reason: error.errorDescription)
            return
        } catch {
            fallbackToMock(reason: error.localizedDescription)
            return
        }

        // ③ 已登录：正常取数，失败则回落模拟数据并提示
        do {
            let status: VehicleStatus = try await APIClient.shared.get(APIRoutes.vehicleStatus)
            vehicleStatus = status
            lastRefresh = Date()
            dataMode = .live
            didNotifyFallback = false
        } catch let error as ApiError {
            fallbackToMock(reason: error.errorDescription)
            return
        } catch {
            fallbackToMock(reason: error.localizedDescription)
            return
        }

        await loadCapabilities()
        await loadLocation()
        await loadWeather()
    }

    /// 拉「当地气温」。
    ///
    /// 与 `loadLocation` 同一条原则：**失败只影响那一格**，不把整页打成模拟数据。
    /// 服务端按坐标缓存 5 分钟，所以轮询再密也不会把腾讯额度打穿。
    private func loadWeather() async {
        do {
            let info: WeatherInfo = try await APIClient.shared.get(APIRoutes.vehicleWeather)
            weather = info.available == true ? info : nil
        } catch {
            weather = nil
        }
    }

    /// 拉车辆位置与地图缩略图。
    ///
    /// **失败只影响这张卡片**：位置是附加信息，不该因为它把整页打成模拟数据。
    /// 位置接口在服务端按坐标缓存，坐标不变时不会重复向腾讯请求。
    private func loadLocation() async {
        do {
            let location: VehicleLocation = try await APIClient.shared.get(APIRoutes.vehicleLocation)
            vehicleLocation = location
            locationError = nil

            // 有坐标、且服务端确认配了地图 key，才去要图。
            // 取不到就保持 nil，界面只显示地址与坐标。
            guard location.hasCoordinate, location.mapAvailable == true else {
                locationMapData = nil
                lastMapKey = nil
                return
            }

            let key = "\(location.lat ?? 0),\(location.lng ?? 0)"
            if key == lastMapKey, locationMapData != nil {
                return   // 车没挪窝，图也不会变
            }

            let data = await APIClient.shared.imageData(
                APIRoutes.vehicleLocationMap,
                query: ["width": "600", "height": "260", "zoom": "16"]
            )
            if let data {
                locationMapData = data
                lastMapKey = key
            } else if locationMapData == nil {
                // 这种情况（首次就失败）保留 nil，下一轮继续尝试
                lastMapKey = nil
            }
        } catch {
            vehicleLocation = nil
            locationMapData = nil
            lastMapKey = nil
            // 明确标成"失败"，卡片才不会一直显示「正在获取位置…」
            locationError = "车辆位置暂时取不到"
        }
    }

    /// 指令 → 能力键。
    ///
    /// 键名与 `preview/index.html` 的 `capBtn(key, …)` **必须同一套** ——
    /// 否则同一台车在两个客户端上会出现「网页上按钮没了、App 上还在」这种
    /// 没法解释的差异。典型坑：后端能力键是 `seatVent`，而指令 rawValue 是
    /// `ventSeat`，按 rawValue 查表**永远查不到**，裁剪就静默失效了。
    ///
    /// 没列出的指令（闪灯 / 鸣笛 / 充电启停 / 寻车 / 刷新）本就不做能力门控 ——
    /// 与网页端一致：它们没有对应的权限包，谁也答不了「这台车支不支持」。
    private static let capabilityKey: [VehicleCommand: String] = [
        .lock: "doorLock", .unlock: "doorLock",
        .climateOn: "climate", .climateOff: "climate",
        .defrost: "defrost",
        .wheelHeat: "wheelHeat",
        .seatHeat: "seatHeat",
        .ventSeat: "seatVent",
        .closeWindows: "window",
        .sunshade: "sunshade",
        .sentinel: "sentinel",
        .tripPlan: "travelPlan",
    ]

    /// 某项车控能力是否可用。
    ///
    /// 只有服务端**明确**返回 false 才隐藏；取不到能力集、或该指令本就不受
    /// 能力集管辖时一律 true。
    func isCapabilityAvailable(_ command: VehicleCommand) -> Bool {
        guard let caps = capabilities else { return true }
        guard let key = Self.capabilityKey[command] else { return true }
        return caps[key] != false
    }

    /// 拉取车辆权限包 / 能力集。失败不影响页面可用性 —— 能力集缺失只是「不知道」，
    /// 不是「不支持」，据此隐藏按钮反而会砍掉本来能用的功能。
    private func loadCapabilities() async {
        do {
            let caps: VehicleCapabilities = try await APIClient.shared.get(APIRoutes.vehicleCapability)
            capabilities = caps.capabilities
            permissions = caps.permissions
            // 与能力集同一次请求返回，没必要为它单开一个接口
            chargePlan = caps.chargePlan
        } catch {
            capabilities = nil
            permissions = nil
            chargePlan = nil
        }
    }

    // MARK: - 模拟数据

    /// 直接用本地模拟数据填充状态
    private func applyMockData() {
        vehicleStatus = MockData.vehicleStatus
        /* ⚠️ **不要**动 `lastRefresh`。
           它的语义是"上次成功读到真实数据的时间"。这里填的是演示值，
           一旦把时间戳也刷新成"刚刚"，界面就会显示
           「更新于 刚刚」配一份编出来的电量/里程 —— 用户会当成自己车的实时值。
           演示模式下宁可不显示更新时间，也不显示假的时间。 */
        dataMode = .mock
        // 权限包也一并给上 —— 否则模拟模式下设置页只能显示"尚未取到"，
        // 而这恰恰是网页预览里能看到的东西（两边演示要对得上）
        capabilities = MockData.capabilities
        permissions = MockData.permissions
        chargePlan = MockData.chargePlan
        vehicleLocation = MockData.vehicleLocation
        // 演示天气：演示模式不联网，给固定值让「当地气温」有内容
        weather = MockData.weather
        // 演示模式不联网，也就不该去请求地图图片
        locationMapData = nil
        locationError = nil
        // 数据已拿到，空态卡片的报错没有意义
        errorMessage = nil
    }

    /// 真实地址不可达时的回落：切到模拟数据，并（每个地址只弹一次）告知用户
    private func fallbackToMock(reason: String?) {
        vehicleStatus = MockData.vehicleStatus
        /* 同样不动 `lastRefresh`：回落成模拟数据不代表读到了新东西。
           保留上一次真实读取的时间，界面才说得清"这些数字是什么时候的"。 */
        dataMode = .offline
        /* ⚠️ 不要把 `errorMessage` 清空。
           它是车况页/车控页那条 `ErrorBanner` 的唯一数据源 ——
           清空等于"连接服务端失败"这个最常见的故障在页面上完全不留痕迹，
           用户只看到一份演示数据，还以为是自己的车。
           弹窗（`pendingDataSourceNotice`）只在首次回落时弹一次，
           关掉之后页面必须还留着"这是模拟数据 + 为什么 + 可重试"。
           这里给的是可重试的短文案；详细原因仍走弹窗。 */
        errorMessage = "连接服务端失败，当前展示的是模拟数据"

        // 车况已经回落成模拟数据，位置必须一起回落。
        // 否则会出现"车况是假的、位置却是真的（而且是上一次的旧位置）"这种组合 ——
        // 比两者都假更糟：用户会以为那个位置可信。
        vehicleLocation = MockData.vehicleLocation
        locationMapData = nil
        locationError = nil

        guard !didNotifyFallback else { return }
        didNotifyFallback = true
        pendingDataSourceNotice = Self.fallbackNotice(reason: reason)
    }

    private static func fallbackNotice(reason: String?) -> String {
        let detail = (reason?.isEmpty == false) ? "\n\n\(reason!)" : ""
        return """
        连接服务端失败，已暂时切换为模拟数据，当前展示的不是真实车况。\(detail)

        请检查设置中的服务端地址，或确认服务端已启动。
        """
    }

    /// 地址变更后重置提示状态，让新地址可以重新提示一次
    func resetFallbackNotification() {
        didNotifyFallback = false
    }

    // MARK: - 轮询

    /// 回前台 / 进后台的统一入口（由 `RootView` 监听 scenePhase 调用）。
    ///
    /// 为什么不交给各页面自己监听：页面由 `RootView.activeScreen` 按
    /// `selectedTab` 重建，停在别的 tab 时车况页根本不在视图树里，它的
    /// scenePhase 监听不会触发 —— 于是 `stopPolling` 没执行、轮询任务还活着，
    /// 切回车况时 `startPolling` 又被 `guard pollTask == nil` 挡掉，
    /// 只能等下一个轮询点（充电中 60 秒 / 平时 5 分钟）才有新数据。
    ///
    /// - Parameter fromBackground: 只有**真正从后台回来**才补刷一次；
    ///   `.inactive`（下拉通知中心 / 来电 / Face ID 解锁）不算，
    ///   否则每次抬起屏幕都要多打两个请求。
    func appDidBecomeActive(fromBackground: Bool) {
        // 模拟数据模式下没有可查的后端，与 `startPolling` 保持同一条边界
        guard !settings.prefersMockData else { return }
        if pollTask == nil {
            startPolling()          // 内部第一步就是 refresh，不必再补
            return
        }
        if fromBackground {
            // 轮询还活着（典型：停在别的 tab 时进的场）——
            // startPolling 会被 guard 挡住，这里单独补一次
            Task { [weak self] in await self?.refresh() }
        }
    }

    func appDidEnterBackground() {
        stopPolling()
    }

    /// 启动轮询（App 进入前台时调用；重复调用安全）
    ///
    /// 模拟数据模式下没有可轮询的后端，直接不启动 —— 既省电，也避免
    /// 每 5 分钟把同一份演示数据重新赋值一次造成的无意义重绘。
    func startPolling() {
        guard !settings.prefersMockData else { return }
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            await self?.refresh()
            while !Task.isCancelled {
                guard let interval = self?.currentInterval() else { break }
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard !Task.isCancelled else { break }
                await self?.refresh()
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// 当前轮询间隔：充电中 60 秒，否则 5 分钟。
    ///
    /// **写死、不做设置项**（原"数据刷新"那栏已去掉）：
    /// 与网页 `schedulePoll()` 的 `isCharging ? 60000 : 300000` 保持一致 ——
    /// 两端各有一套可调间隔，只会让人说不清"为什么网页 5 分钟、App 是 20 分钟"。
    private func currentInterval() -> TimeInterval {
        isCharging ? 60 : 300
    }

    /// 下发车控指令（供车控面板调用）
    ///
    /// 模拟数据模式下不发真实请求，直接返回本地回执，
    /// 让车控面板的动效链路在无后端时同样可以完整预览。
    func send(command: VehicleCommand) async -> CommandResult? {
        guard dataMode != .mock else {
            applyLocalCommand(command)
            return CommandResult(
                success: true,
                message: "模拟数据模式：指令已在本地生效",
                command: command.rawValue
            )
        }

        do {
            let result: CommandResult = try await APIClient.shared.post(
                APIRoutes.vehicleCommand,
                body: ["command": command.rawValue, "params": [:] as [String: Any]]
            )
            if result.success { await refresh() }
            return result
        } catch let error as ApiError {
            errorMessage = error.errorDescription
            return nil
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    /// 模拟数据模式下让状态随指令联动，开关类按钮才有「点得动」的真实感。
    ///
    /// 覆盖范围与 `preview/index.html` 的 `applyDemoCommand` 保持一致（7 项）。
    /// 其余纯瞬时动作（闪灯 / 鸣笛 / 寻车等）在模拟模式下本就没有状态可改，
    /// 只回执成功即可。
    private func applyLocalCommand(_ command: VehicleCommand) {
        guard var status = vehicleStatus else { return }
        switch command {
        case .lock:
            status.isLocked = true
        case .unlock:
            status.isLocked = false
        case .climateOn:
            status.climateOn = true
        case .climateOff:
            status.climateOn = false
        case .closeWindows:
            // 键名与服务端 live 侧保持一致（`frontLeft` 系列）
            status.windows = ["frontLeft": false, "frontRight": false,
                              "rearLeft": false, "rearRight": false]
        case .chargeStart:
            status.isCharging = true
        case .chargeStop:
            status.isCharging = false
        default:
            // 瞬时动作 / 场景类：无状态可联动
            break
        }
        vehicleStatus = status
        lastRefresh = Date()
    }

    // MARK: - 全局提示

    /// 展示一条底部 Toast，2.4 秒后自动消失。
    ///
    /// **全 App 只有这一处 Toast**：以前充电页自己有一套（位置还不一样），
    /// 同一个提示在两个位置飘，用户以为是两条消息。现在统一由 RootView 呈现，
    /// 位置、动效、停留时长全都一致。
    func showToast(_ message: String) {
        toast = message
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_400_000_000)
            guard !Task.isCancelled else { return }
            // 只有"仍然是这条消息"时才清除，避免误清掉更新后的那条
            if self?.toast == message { self?.toast = nil }
        }
    }
}
