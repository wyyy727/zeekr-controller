//
//  NetworkActivity.swift
//  ZeekrDash
//
//  全局请求计数：有几条请求在飞。
//
//  对应网页 `preview/index.html` 的 `NET_INFLIGHT` + `#netBar` ——
//  弱网下如果没有跨页面的统一反馈，用户很难分清"正在转圈"和"已经卡死"。
//
//  为什么不用 `@MainActor`：请求是从任意上下文发出的，
//  而 `APIClient.run()` 里要在 `defer` 中收尾（`defer` 不能 `await`）。
//  这里用锁保护计数，只把最终结果切回主线程写 —— 简单，且不会因为
//  线程隔离规则把每个请求都拖去跳一次 actor。
//

import SwiftUI   // `@Observable` 来自 Observation，SwiftUI 会一并带进来（与项目其它 Store 一致）

@Observable
final class NetworkActivity: @unchecked Sendable {

    static let shared = NetworkActivity()

    private let lock = NSLock()

    /// **必须 `@ObservationIgnored`**：这个计数是在锁里、从任意线程读写的，
    /// 而 `@Observable` 会给存储属性套一层观察登记（写入即改内部状态）。
    /// 让它在后台线程被登记，等于把非线程安全的结构拿去并发用。
    /// 外面只需要 `isBusy` 这一个布尔量参与观察。
    @ObservationIgnored private var inflight = 0

    /// 供 SwiftUI 读取的布尔量。**只在主线程写**，否则 Observation 的
    /// 通知会落在非主线程上，界面可能不刷新（也可能刷出难查的警告）。
    private(set) var isBusy = false

    private init() {}

    func begin() { mutate(by: 1) }
    func end() { mutate(by: -1) }

    /// 计数变化后把 `isBusy` 同步到主线程。
    ///
    /// 负号兜底：`end()` 多调一次就会把计数打到负数，之后所有请求都不再点亮
    /// 进度条，且极难排查 —— 这里直接夹到 0。
    ///
    /// **一律走 `DispatchQueue.main.async`，即使在主线程也排队**：
    /// 若主线程直写、后台走异步，两条路径会乱序 ——
    /// 比如 begin（后台，排队 true）之后 end（主线程，立即 false），
    /// 那条排在后面的 true 一到，光带就永远停不下来。
    /// 全部排队到同一个串行队列，顺序才和计数变化一致。
    private func mutate(by delta: Int) {
        lock.lock()
        inflight = max(0, inflight + delta)
        let busy = inflight > 0
        lock.unlock()

        DispatchQueue.main.async { [weak self] in
            self?.isBusy = busy
        }
    }
}
