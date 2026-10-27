//
//  ControlsView.swift
//  ZeekrDash
//
//  车控屏（v2）
//
//  真源：`preview/index-v2.html` 的 `renderControls()`（按钮定义、三态、提示）
//  与样式块 2062–2098。按钮顺序、图标、配色、门控键全部照抄。
//

import SwiftUI
import UIKit

struct ControlsView: View {

    @Environment(AppStore.self) private var store

    /// 每颗按钮的瞬时状态（进行中 / 成功 / 失败）
    @State private var phases: [String: V2ControlItem.Phase] = [:]

    var body: some View {
        NavigationStack {
            ScreenContainer(modePill: store.modePill) {
                if store.needsLogin {
                    V2LoginWall { store.selectedTab = .settings }
                } else if let status = store.vehicleStatus {
                    headRow

                    if let message = store.errorMessage, store.hasData {
                        V2StaleBanner(
                            text: "这一轮没读到最新车况，下面是上次读到的数据",
                            detail: message
                        ) { Task { await store.refresh() } }
                    }

                    V2ControlGrid(items: items(status), enabled: commandsEnabled) { item in
                        Task { await send(item) }
                    }

                    // 车辆不支持的能力：画成灰按钮，不藏
                    V2UnsupportedRow()

                    ForEach(Array(hints.enumerated()), id: \.offset) { _, hint in
                        Text(hint)
                            .v2Text(.label11, color: hint.hasPrefix("服务端") ? V2Color.warn : V2Color.text3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    footNote
                } else if store.isLoading {
                    skeleton
                } else {
                    emptyCard
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .refreshable { await store.refresh() }
        }
        // 直接落在车控页时也要把轮询接上（`startPolling` 内部有 guard，不会重复起）
        .onAppear { store.startPolling() }
        // 车控开关是配置项，进页面问一次 `/api/health` 就够（不掺进 60 秒轮询）
        .task { await store.refreshServerCommandFlag() }
    }

    // MARK: - 状态

    /// 客户端总开关（与设置页同一个 `SettingsStore.commandsEnabled`）
    private var commandsEnabled: Bool { SettingsStore.shared.commandsEnabled }

    /// HTML：`const connected = state.mode === 'live'`。
    /// **offline 属于「连不上」**，不能算已连接 —— 之前写成 `!= .mock` 是错的。
    private var connected: Bool { store.dataMode == .live }

    private var hints: [String] {
        guard store.hasData else { return [] }
        var list: [String] = []
        if !commandsEnabled {
            list.append("在「设置」中开启控制指令开关后可用")
        }
        // 服务端也关着时，即使本地开关打开，指令仍会被拒绝
        if commandsEnabled, store.serverAllowsCommands == false {
            list.append("服务端也没有开启车控，即便本开关打开，指令仍会被拒绝")
        }
        return list
    }

    /// 与网页 `cap(key)` 同语义：明确 false 才隐藏，取不到一律显示
    private func cap(_ key: String) -> Bool {
        guard let caps = store.capabilities else { return true }
        return caps[key] != false
    }

    // MARK: - 页头（`.v2-head-l`）

    private var headRow: some View {
        HStack(spacing: 12) {
            Text(connected ? "已连接" : "未连接")
                .v2Text(.badge13, color: connected ? V2Color.good : V2Color.text2)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(connected ? V2Color.tintGood : V2Color.tintMuted)
                .clipShape(Capsule())
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.90), lineWidth: 1))

            if !commandsEnabled {
                Text("已禁用")
                    .v2Text(.label11, color: V2Color.text3)
            }

            Spacer(minLength: 0)
        }
    }

    // MARK: - 按钮清单（renderControls 的 items[]）

    private func items(_ status: VehicleStatus) -> [V2ControlItem] {
        let locked = status.isLocked == true
        let climateOn = status.climateOn == true
        let charging = status.isCharging == true

        var list: [V2ControlItem] = []

        /* key 是**语义固定**的：cmd 会在 lock/unlock 之间翻转，但三态与视图身份必须跟着 key 走，
           否则刷新后按钮会「换一个人」，刚写的成功态就丢了。 */
        list.append(item(
            key: "doorLock",
            cmd: locked ? .unlock : .lock,
            label: "车锁", icon: "ctrl-lock", color: 0x6742E8,
            kind: .toggle, on: locked
        ))

        if cap("climate") {
            list.append(item(
                key: "climate",
                cmd: climateOn ? .climateOff : .climateOn,
                label: "空调", icon: "ctrl-climate", color: 0x0E96CE,
                kind: .toggle, on: climateOn
            ))
        }
        if cap("defrost") {
            list.append(item(key: "defrost", cmd: .defrost, label: "前除霜", icon: "ctrl-defrost-front", color: 0xC4862A, kind: .toggle))
        }
        if cap("wheelHeat") {
            list.append(item(key: "wheelHeat", cmd: .wheelHeat, label: "方向盘加热", icon: "ctrl-steering-heat", color: 0xE0607C, kind: .toggle))
        }
        if cap("seatHeat") {
            list.append(item(key: "seatHeat", cmd: .seatHeat, label: "座椅加热", icon: "ctrl-seat-heat", color: 0xE0607C, kind: .toggle))
        }
        if cap("seatVent") {
            list.append(item(key: "seatVent", cmd: .ventSeat, label: "座椅通风", icon: "ctrl-seat-vent", color: 0x0E96CE, kind: .toggle))
        }

        // 闪灯 / 鸣笛 / 寻车 / 刷新不受能力门控（HTML 里就是无条件渲染）
        list.append(item(key: "flash", cmd: .flash, label: "闪灯", icon: "ctrl-flash", color: 0xC4862A, kind: .action))
        list.append(item(key: "honk", cmd: .honk, label: "鸣笛", icon: "ctrl-horn", color: 0xC4862A, kind: .action))

        if cap("window") {
            list.append(item(key: "window", cmd: .closeWindows, label: "关车窗", icon: "ctrl-window-close", color: 0x0E96CE, kind: .action))
        }

        list.append(item(
            key: "charge",
            cmd: charging ? .chargeStop : .chargeStart,
            label: charging ? "结束充电" : "开始充电",
            icon: "ctrl-charge-start", color: 0x12A06B,
            kind: .action,
            disabled: !charging && status.isPlugged != true
        ))

        if cap("sentinel") {
            list.append(item(key: "sentinel", cmd: .sentinel, label: "哨兵", icon: "ctrl-sentry", color: 0xC4862A, kind: .toggle))
        }
        if cap("travelPlan") {
            list.append(item(key: "travelPlan", cmd: .tripPlan, label: "出行规划", icon: "ctrl-trip-plan", color: 0x12A06B, kind: .scene))
        }

        list.append(item(key: "carFinder", cmd: .carFinder, label: "寻车", icon: "ctrl-find-car", color: 0xC4862A, kind: .scene, wide: true))
        list.append(item(key: "refresh", cmd: .refresh, label: "立即刷新", icon: "ctrl-refresh", color: 0x6742E8, kind: .scene))

        return list
    }

    private func item(
        key: String,
        cmd: VehicleCommand,
        label: String,
        icon: String,
        color: UInt32,
        kind: V2ControlItem.Kind,
        on: Bool = false,
        wide: Bool = false,
        disabled: Bool = false
    ) -> V2ControlItem {
        V2ControlItem(
            id: key,
            cmd: cmd.rawValue,
            label: label,
            icon: icon,
            color: Color(hex: color),
            kind: kind,
            on: on,
            phase: phases[key] ?? .idle,
            wide: wide,
            disabled: disabled
        )
    }

    // MARK: - 下发

    private func send(_ item: V2ControlItem) async {
        guard let command = VehicleCommand(rawValue: item.cmd) else { return }
        // 场景类（刷新）没有"成功绿勾"的意义，直接执行
        if item.kind == .scene, command == .refresh {
            await store.refresh()
            return
        }

        // 三态一律挂在 `item.id`（语义 key）上，**不能用 item.cmd**：
        // 车锁/空调/充电的 cmd 会在成功后翻转（lock→unlock），
        // 而 `send()` 内部还会 await 一次 refresh 让状态先行更新 ——
        // 用 cmd 当键的话，刚写进去的成功态当场就读不到了。
        phases[item.id] = .pending
        let result = await store.send(command: command)
        let ok = result?.success ?? false

        // 远程操作要有触觉回执：盲操作、或眼睛在看车的时候也能知道成没成
        UINotificationFeedbackGenerator().notificationOccurred(ok ? .success : .error)

        withAnimation(.spring(response: 0.28, dampingFraction: 0.55)) {
            phases[item.id] = ok ? .done : .fail
        }

        if ok {
            // 成功态是「弹一下」：1.6 秒后退回常态（失败态常驻，等下一次点击覆盖）
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            if phases[item.id] == .done {
                withAnimation(.easeOut(duration: 0.2)) {
                    phases[item.id] = .idle
                }
            }
        }
    }

    // MARK: - 提示 / 骨架 / 空态


    private var skeleton: some View {
        VStack(alignment: .leading, spacing: 0) {
            GeometryReader { proxy in
                VStack(alignment: .leading, spacing: 12) {
                    SkeletonBar(width: proxy.size.width * 0.60)
                    SkeletonBar(width: proxy.size.width * 0.40)
                }
            }
            .frame(height: 40)
        }
        .v2Card()
        .accessibilityLabel("正在获取车辆状态")
    }

    private var emptyCard: some View {
        VStack(spacing: 0) {
            Text("车辆数据没有读到")
                .v2Text(.emptyTitle)
            /* HTML `renderControls` 的空态：
               `state.statusError ? '后端可能正在重启，或登录状态已失效' : '请确认服务已启动、地址配置正确'` */
            Text(store.errorMessage == nil
                 ? "请确认服务已启动、地址配置正确"
                 : "后端可能正在重启，或登录状态已失效")
                .v2Text(.emptyDesc, color: V2Color.text3)
                .multilineTextAlignment(.center)
                .padding(.top, 6)
            Button {
                Task { await store.refresh() }
            } label: {
                Text("重试")
                    .v2Text(.button14, color: V2Color.accent)
                    .frame(height: 32)
                    .padding(.horizontal, 20)
                    .background(V2Color.tintAccent)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .padding(.top, 16)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 22)
        .frame(maxWidth: .infinity)
        .v2Card()
    }

    /// `.v2-foot`：多行 11/400/16、行间 2、padding-top 8。
    /// 车控页在 HTML 里是 `v2Foot('')`（`withTime` 默认 true）→ **含「更新于」**；
    /// 车况屏才是 `v2Foot('', false)`。这一屏以前漏了时间行。
    private var footNote: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let last = store.lastRefresh {
                Text("更新于 \(last.formatted(date: .omitted, time: .shortened))")
                    .v2Text(.foot11, color: V2Color.text3)
            }
            Text("数据来自非官方接口，仅供参考")
                .v2Text(.foot11, color: V2Color.text3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 8)
    }
}
