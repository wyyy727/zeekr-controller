//
//  SettingsView.swift
//  ZeekrDash
//
//  设置页
//
//  视觉真源：`preview/index-v2.html` 的 `renderSettings()`（6527–6660）。
//  与 v1 的区别（也是这轮重写的重点）：
//    · 区块标题从「卡外小标题」改成**卡内首行**（`.v2-set-col` 的第一行就是标题）
//    · 权限是两列等分网格 + 跨行「…」「收起」，不是弹性 chip 流
//    · 头像是 `avatar-mark` 双色件，original 渲染，不染色
//    · 未登录才显示「服务端连接」与「高级与调试」
//

import SwiftUI

/// 设置页：服务端地址、账号登录、轮询、车控开关、诊断
struct SettingsView: View {

    @Environment(SettingsStore.self) private var settings
    @Environment(AppStore.self) private var store

    @State private var model = SettingsViewModel()
    @State private var showCodeSheet = false
    /// 车辆权限是否展开全部（默认只看前 6 项，与 HTML `PERM_PREVIEW` 一致）
    @State private var showAllPermissions = false
    /// 「高级与调试」是否展开（HTML 是 `<details>`，默认收起）
    @State private var showAdvanced = false
    /// 服务端地址输入框焦点：失焦即提交，避免「改完不按回车」导致不生效
    @FocusState private var isAddressFocused: Bool
    /// API 令牌输入框焦点，同上
    @FocusState private var isTokenFocused: Bool

    var body: some View {
        // 页面标题与底部导航重复，已移除；顶部右上角为数据来源胶囊
        NavigationStack {
            ScreenContainer(modePill: store.modePill) {
                /* 顺序对齐 HTML `renderSettings()`：
                   头像 → 远程车控 → 服务端连接(未登录) → 账号登录 → 车辆权限 → 关于 → 页脚。
                   iOS 独有的三块（数据来源说明 / 待配置项 / 诊断）放在「关于」之后 ——
                   HTML 没有它们，但它们承载的是现有功能，不能因为重写而减少。 */
                heroCard
                commandSection
                if !model.isAuthenticated {
                    connectionSection
                }
                // 地址指向本机时没有可登录的后端，放出账号区只会诱导点一个必然失败的按钮
                if !model.isLocalEndpoint {
                    accountSection
                }
                capabilitySection
                aboutSection
                footNote

                /* 「高级与调试」：HTML 里是 `<details>`，位置在页脚之后、且登录后不渲染。
                   数据来源说明 / 待配置项 / 诊断三块收进来 —— 它们属于开发者视角，
                   天天摊在首页只是噪音（模拟数据状态已由顶部胶囊标注，信息不丢）。 */
                if !model.isAuthenticated {
                    advancedSection
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .task { await model.checkHealth(baseURL: settings.baseURL) }
            // 验证码弹窗也走自绘面板（与充电页的三个弹层同一套观感）
            .fullScreenCover(isPresented: $showCodeSheet) {
                SMSCodeSheet(model: model, phone: model.pendingPhone)
            }
        }
    }

    // MARK: - 头像 Hero（`.v2-set-hero`）

    /// 品牌标记 `avatar-mark` 是**双色件**（accent 盘面 + 白色字形），
    /// 资产里已设 `template-rendering-intent: original` —— 直接 `Image("avatar-mark")`，
    /// **不要 `.renderingMode(.template)`、不要 `.foregroundStyle()`**，否则会糊成单色块。
    private var heroCard: some View {
        HStack(spacing: 14) {
            // `.v2-set-ava`：48×48 r24，盘面 #6742E8（资产里已烘焙，不染色）
            Image("avatar-mark")
                .resizable()
                .frame(width: 48, height: 48)
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: 4) {
                Text(vehicleName)
                    .v2Text(.setName16)
                    .lineLimit(1)
                Text(plateText)
                    .v2Text(.setSub13, color: V2Color.text2)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            // `.v2-set-chev`：20pt，不是 SF 的小箭头
            Text("›")
                .v2Text(.setName16, color: V2Color.text3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .v2Card()
        // HTML `.v2-set-hero{ margin-top: 8px }` —— 卡**外**间距。
        // 写在 .v2Card() 之前会变成卡内上内距（16+8=24），卡片比别的卡高 8pt。
        .padding(.top, 8)
    }

    private var vehicleName: String { "我的极氪" }

    private var plateText: String {
        if let plate = store.vehicleStatus?.plateNo, !plate.isEmpty { return plate }
        return "未绑定车辆"
    }

    // MARK: - 远程车控

    private var commandSection: some View {
        /* HTML `.v2-set-row`：一行标题+副标题 + 右侧原生开关。
           服务端那把锁的说明不在这张卡里 —— 车控屏会按 `/health` 单独提示。 */
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("远程车控")
                    .v2Text(.setName16)
                Text("允许 App 下发车辆指令")
                    .v2Text(.setRowT2, color: V2Color.text2)
            }
            Spacer(minLength: 0)
            Toggle("", isOn: Bindable(settings).commandsEnabled)
                .labelsHidden()
                .tint(V2Color.accent)
                .frame(width: 51, height: 31)
                .accessibilityLabel("远程车控")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .v2Card()
    }

    // MARK: - 服务端连接

    /// 已应用过的「地址 + 令牌」组合，用于去重 —— 回车与失焦会各触发一次，
    /// 避免重复请求。把令牌也纳入 key，这样只改令牌也能触发重新连接。
    @State private var appliedConnection: String?

    /// 地址或令牌变更后统一处理：同步客户端、重跑诊断、让首页按新配置重取数据。
    ///
    /// 除了 `.onSubmit`（回车），失焦时也会调到这里：用户改完往往直接切走
    /// 而不按回车，只挂 `.onSubmit` 会让新值停留在 UserDefaults 里、
    /// 界面上却还是旧数据。
    private func applyAddress() async {
        let current = settings.baseURL
        let key = current + "\u{1}" + settings.apiToken
        guard key != appliedConnection else { return }   // 同一次编辑只跑一次
        appliedConnection = key

        APIClient.shared.baseURL = current
        APIClient.shared.authToken = settings.apiToken
        // 换了地址/令牌，允许重新提示一次「已切换为模拟数据」
        store.resetFallbackNotification()
        await model.checkHealth(baseURL: current)
        await store.refresh()
        // 从 localhost 切到真实地址后轮询此前是被跳过的（mock 下不启动），
        // 这里补一次启动，避免用户一直停在首页时永远不刷新。
        store.startPolling()
    }

    private var connectionSection: some View {
        SettingsCard(title: "服务端") {
            VStack(spacing: 10) {
                settingsRow("地址") {
                    TextField("http://192.168.1.10:8765", text: Bindable(settings).baseURL)
                        .v2Text(.text13m)
                        .multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .onSubmit {
                            Task { await applyAddress() }
                        }
                        // 失焦即提交：覆盖「改完不按回车直接切走」的情况
                        .onChange(of: isAddressFocused) { _, focused in
                            guard !focused else { return }
                            Task { await applyAddress() }
                        }
                        .focused($isAddressFocused)
                }

                separator

                settingsRow("API 令牌") {
                    SecureField("未启用可留空", text: Bindable(settings).apiToken)
                        .v2Text(.text13m)
                        .multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onSubmit {
                            Task { await applyAddress() }
                        }
                        .onChange(of: isTokenFocused) { _, focused in
                            guard !focused else { return }
                            Task { await applyAddress() }
                        }
                        .focused($isTokenFocused)
                }

                Text("服务端设了 API_TOKEN 后必填，否则所有接口会返回 401；留空表示未启用鉴权")
                    .v2Text(.foot11, color: V2Color.text3)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)

                separator

                // 对齐网页「服务连接」里的「地址形态」。
                // 只判断"是不是本机"看不出「根本没填」和「填了本机」的区别，
                // 而这两者的处理方式不一样（前者要提示去填，后者是刻意的离线用）。
                settingsRow("地址形态") {
                    Text(endpointModeText)
                        .v2Text(.text13m)
                }

                separator

                settingsRow("状态") {
                    connectionBadge
                }

                if model.isLocalEndpoint {
                    Text("地址为空或指向本机，将直接展示内置模拟数据（不联网）")
                        .v2Text(.foot11, color: V2Color.warn)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    /// 一行设置：「标签 …… 右值」，标签 13/500 `#5E6775`
    private func settingsRow<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack {
            Text(title)
                .v2Text(.text13m, color: V2Color.text2)
            Spacer(minLength: 12)
            content()
        }
    }

    /// `--separator: rgba(27,31,36,.07)`
    private var separator: some View {
        Rectangle()
            .fill(V2Color.separator)
            .frame(height: 1)
    }

    /// 地址形态三态文案，与网页 `${ENDPOINT_MODE}` 的映射一致。
    private var endpointModeText: String {
        switch model.endpointMode {
        case .unset:    return "未配置"
        case .loopback: return "本机地址"
        case .remote:   return "远程地址"
        }
    }

    private var connectionBadge: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(connectionColor)
                .frame(width: 7, height: 7)

            Text(connectionText)
                .v2Text(.text13m, color: connectionColor)

            if model.isChecking {
                ProgressView().controlSize(.mini)
            }
        }
    }

    private var connectionColor: Color {
        if model.isChecking { return V2Color.text3 }
        // 地址为空 / localhost：按约定走模拟数据，不算失败
        if model.isLocalEndpoint { return V2Color.warn }
        return model.isReachable ? V2Color.good : V2Color.bad
    }

    private var connectionText: String {
        if model.isChecking { return "检测中" }
        if model.isLocalEndpoint { return "模拟数据" }
        return model.isReachable ? "已连接" : "未连接"
    }

    // MARK: - 账号

    private var accountSection: some View {
        SettingsCard(title: "账号登录") {
            VStack(spacing: 10) {
                settingsRow("登录状态") {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(model.isAuthenticated ? V2Color.good : V2Color.text3)
                            .frame(width: 7, height: 7)
                        Text(model.isAuthenticated ? "已登录" : "未登录")
                            .v2Text(.text13m)
                    }
                }

                if model.isAuthenticated {
                    // 已登录只给退出入口，不再摆着登录表单 —— 与网页一致。
                    // 此前 iOS 既没有退出按钮、表单又一直在，想换个账号只能重装 App。
                    Text("会话保存在服务端。退出后立即回到未登录态，车辆数据会被清空。")
                        .v2Text(.foot11, color: V2Color.text3)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    /* 位置按用户要求保留在账号卡里（HTML 把它放在「关于」卡，这里不搬）。
                       `.v2-set-out`：42 高 / r16 / #FFF1F4 底 / #C03950 字 / 15-600。 */
                    Button {
                        Task {
                            if await model.logout() {
                                // 清理交给 AppStore：refresh 会进 needsLogin 分支，
                                // 车况 / 权限包 / 车辆位置在那里被一并清掉
                                await store.refresh()
                            }
                        }
                    } label: {
                        HStack(spacing: 6) {
                            if model.isLoggingOut {
                                ProgressView().controlSize(.small)
                            }
                            Text(model.isLoggingOut ? "退出中" : "退出登录")
                                .v2Text(.btn15, color: Color(hex: 0xC03950))
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 42)
                        .background(Color(hex: 0xFFF1F4))
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(model.isLoggingOut)
                } else {
                    separator

                    settingsRow("手机号") {
                        TextField("13800138000", text: Bindable(model).phone)
                            .v2Text(.text13m)
                            .multilineTextAlignment(.trailing)
                            .keyboardType(.numberPad)
                    }

                    Button {
                        Task {
                            let sent = await model.sendCode()
                            if sent { showCodeSheet = true }
                        }
                    } label: {
                        HStack(spacing: 6) {
                            if model.isSending {
                                ProgressView().controlSize(.small)
                            }
                            Text(model.isSending ? "发送中" : "获取验证码")
                                .v2Text(.btn15, color: .white)
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .background(canSendCode ? V2Color.accent : V2Color.text3.opacity(0.4))
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSendCode)

                    Text("建议使用独立的极氪子账号并共享车辆，避免与手机 App 会话冲突")
                        .v2Text(.foot11, color: V2Color.text3)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if let message = model.accountMessage {
                    Text(message)
                        .v2Text(.foot11, color: V2Color.text3)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var canSendCode: Bool {
        !model.isSending && model.phone.count == 11 && model.phone.allSatisfy(\.isNumber)
    }

    // MARK: - 车辆权限

    /// 权限包 ID → 中文名。
    ///
    /// **只翻译有把握的**：表里没有的一律原样显示 ID。编一个像模像样的中文名
    /// 比显示原始 ID 更糟 —— 那是在编造事实。与 `preview/index.html` 的
    /// `PERM_LABELS` 保持同一份清单，两边不许各译各的。
    private static let permissionLabels: [String: String] = [
        "vehicle-share": "车辆分享",
        "vehicle-defence": "车辆守卫",
        "digital-key": "数字钥匙",
        "owner-digital-key": "车主数字钥匙",
        "view-vehicle-location": "查看车辆位置",
        "view-vehicle-album": "查看车辆相册",
        "remote-control": "远程车控",
        "traffic-card-owner": "车主流量卡",
        "digital-key1.0": "数字钥匙 1.0",
        "digital-key2.0": "数字钥匙 2.0",
        "digital-key3.0": "数字钥匙 3.0",
        "charge-manage": "充电管理",
        "ETC-LU-function": "ETC",
        "VIVO-watch": "vivo 手表",
        "journey-h5-owner": "行程（H5）",
        "owner-vehicle-trail": "行程轨迹",
        "owner-ai-cloud": "AI 云",
        "owner-ota-server": "OTA 升级",
        "ZK_face_recognition": "人脸识别",
        "Rear_seat_ventilation": "后排座椅通风",
    ]

    /// 能力键 → 中文名。只翻有把握的，表里没有的原样显示 key。
    private static let capabilityLabels: [String: String] = [
        "doorLock": "车锁", "climate": "空调", "defrost": "前除霜",
        "wheelHeat": "方向盘加热", "seatHeat": "座椅加热", "seatVent": "座椅通风",
        "window": "车窗", "sentinel": "哨兵", "travelPlan": "出行规划",
        "tyrePressure": "胎压", "charge": "充电", "location": "位置", "trips": "行程",
    ]

    /// 后端明确判定「没有此项」的能力（`capabilities[key] == false`）。
    /// 取不到能力集时返回空 —— 「不知道」不能写成「确认没有」。
    private var offCapabilityNames: [String] {
        guard let caps = store.capabilities else { return [] }
        return caps
            .filter { $0.value == false }
            .keys
            .sorted()
            .map { Self.capabilityLabels[$0] ?? $0 }
    }

    /// 权限清单默认只显示前 6 项（HTML `PERM_PREVIEW`）
    private static let permissionPreview = 6

    private var visiblePermissions: [String] {
        (store.permissions ?? []).filter { $0 != "half_load_260" }
    }

    private var capabilitySection: some View {
        SettingsCard(
            title: "车辆权限",
            badge: visiblePermissions.isEmpty ? nil : "\(visiblePermissions.count) 项"
        ) {
            VStack(alignment: .leading, spacing: 8) {
                if !visiblePermissions.isEmpty {
                    let shown = showAllPermissions
                        ? visiblePermissions
                        : Array(visiblePermissions.prefix(Self.permissionPreview))

                    LazyVGrid(
                        columns: [
                            GridItem(.flexible(), spacing: 8),
                            GridItem(.flexible(), spacing: 8),
                        ],
                        spacing: 8
                    ) {
                        ForEach(shown, id: \.self) { permission in
                            grantChip(Self.permissionLabels[permission] ?? permission, off: false)
                        }
                    }

                    /* HTML 的「…」/「收起」是**跨满整行**的 chip（`grid-column: 1/-1`），
                       不是文字链接、更不是 SF 的 chevron。 */
                    if visiblePermissions.count > Self.permissionPreview {
                        Button {
                            withAnimation(.easeInOut(duration: 0.18)) {
                                showAllPermissions.toggle()
                            }
                        } label: {
                            Text(showAllPermissions ? "收起" : "…")
                                .v2Text(.grantChip, color: V2Color.accent)
                                .frame(maxWidth: .infinity)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 8)
                                .background(V2Color.tintAccent)
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .strokeBorder(Color.white.opacity(0.90), lineWidth: 1)
                                )
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(showAllPermissions
                                            ? "收起权限列表"
                                            : "展开全部 \(visiblePermissions.count) 项权限")
                    }
                } else {
                    Text(store.permissions == nil
                         ? "未取到权限包 —— 权限接口不可用时界面按「全部显示」处理。"
                         : "服务端确认这台车没有任何权限包。")
                        .v2Text(.foot11, color: V2Color.text3)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                // 未开通：后端明确判定「没有此项」的能力，灰 chip 逐个列出。
                // 只写"已隐藏 3 项"回答不了「到底哪个按钮不见了」——
                // 而这张卡存在的意义就是让这件事可解释。
                if !offCapabilityNames.isEmpty {
                    Text("未开通")
                        .v2Text(.label11, color: V2Color.text3)
                        .padding(.top, 2)

                    LazyVGrid(
                        columns: [
                            GridItem(.flexible(), spacing: 8),
                            GridItem(.flexible(), spacing: 8),
                        ],
                        spacing: 8
                    ) {
                        ForEach(offCapabilityNames, id: \.self) { name in
                            grantChip(name, off: true)
                        }
                    }

                    Text("灰项为本账号未开通、已从界面隐藏的功能")
                        .v2Text(.foot11, color: V2Color.text3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// 一个权限 chip：`.v2-set-grants .v2-set-chip`（r12 / 内距 8 10 / 居中 / 单行省略）
    private func grantChip(_ text: String, off: Bool) -> some View {
        Text(text)
            .v2Text(.grantChip, color: off ? V2Color.muted : V2Color.accent)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(off ? V2Color.tintMuted : V2Color.tintAccent)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.90), lineWidth: 1)
            )
    }

    // MARK: - 关于当前数据

    /// 「关于当前数据」—— 对齐网页同名卡片，只在非 live 时出现。
    ///
    /// 这一段的用处不是装饰：模拟数据长得像真的，不写清楚「现在看到的不是真实车况」，
    /// 用户会把演示数据当成车。网页那边是一整张卡，这里保持一致。
    private var dataSourceNoticeCard: some View {
        SettingsCard(title: "关于当前数据") {
            VStack(alignment: .leading, spacing: 8) {
                Text(store.dataMode == .mock
                     ? "服务地址未配置或指向本机，界面展示的是内置模拟数据，不是真实车况。"
                     : "服务地址已配置，但后端当前不可达，已暂时切换为模拟数据，不是真实车况。")
                    .v2Text(.text12, color: V2Color.text2)
                    .fixedSize(horizontal: false, vertical: true)

                Text("在上方「服务端」里填写后端地址即可切换到真实数据。")
                    .v2Text(.foot11, color: V2Color.text3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// 「待配置项」—— 对齐网页独立卡片。
    ///
    /// 与「诊断」里那行分开：这里说的是"服务端缺什么密钥"，
    /// 是用户下一步要去改 `.env` 的清单，不该埋在诊断数字里。
    private var pendingConfigCard: some View {
        SettingsCard(title: "待配置项") {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(model.missingKeys, id: \.self) { key in
                    Text("· \(key)")
                        .font(Font.custom(V2Font.regular, size: 11).monospaced())
                        .foregroundStyle(V2Color.text2)
                }

                Text("填入服务端 .env 后重启服务即可切换到真实数据。")
                    .v2Text(.foot11, color: V2Color.text3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - 诊断

    private var diagnosticsSection: some View {
        SettingsCard(title: "诊断") {
            VStack(spacing: 0) {
                diagnosticRow("数据来源", value: diagnosticsSourceText)
                separator
                diagnosticRow("配置完整", value: model.isLiveConfigured ? "是" : "否")
                separator
                // 「服务端车控」已移到「车辆控制」卡（和客户端总开关放一起看才讲得清）。
                // 同一个信息不在一处之外再摆一遍 —— 两处都可能过期，还容易只改一处。
                diagnosticRow("上次刷新", value: store.lastRefresh.map {
                    $0.formatted(date: .omitted, time: .shortened)
                } ?? "--")

                // 「缺少的服务端配置」已移到独立卡片（对齐网页的「待配置项」），
                // 这里不再重复列，免得同一个信息出现两遍、还两处都可能过期。
            }
        }
    }

    /// 诊断区展示的数据来源文案
    private var diagnosticsSourceText: String {
        switch store.dataMode {
        case .mock:    return "本地模拟数据"
        case .live:    return "真实服务端"
        case .offline: return "模拟数据（后端不可达）"
        }
    }

    private func diagnosticRow(_ title: String, value: String) -> some View {
        HStack {
            Text(title)
                .v2Text(.text13m, color: V2Color.text2)
            Spacer()
            Text(value)
                .v2Text(.text13m)
        }
        .padding(.vertical, 9)
    }

    // MARK: - 关于

    private var aboutSection: some View {
        SettingsCard(title: "关于") {
            VStack(alignment: .leading, spacing: 8) {
                // `.v2-set-ver`：14/500，文案是「ZeekrDash v5.0.7 · iOS 26」
                Text("ZeekrDash v5.0.7 · iOS 26")
                    .v2Text(.body14m)

                Text("非官方工具，基于社区逆向研究成果实现。与极氪、吉利无任何关联，仅供个人自用。")
                    .v2Text(.foot11, color: V2Color.text3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - 高级与调试（`.v2-set-adv`）

    /// HTML：`<details class="v2-set-adv"><summary>高级与调试</summary>…</details>`，
    /// summary 是 11/500 text-3，`::before` 加了「ⓘ 」前缀；展开后里面的卡片带 8pt 上距。
    private var advancedSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) { showAdvanced.toggle() }
            } label: {
                HStack(spacing: 0) {
                    Text("ⓘ 高级与调试")
                        .v2Text(.label11, color: V2Color.text3)
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("高级与调试")
            .accessibilityAddTraits(showAdvanced ? [.isSelected] : [])

            if showAdvanced {
                VStack(spacing: V2Metrics.screenGap) {
                    // 只有非 live 时才有意义（真实数据没什么好提示的）
                    if store.dataMode != .live {
                        dataSourceNoticeCard
                    }
                    if !model.missingKeys.isEmpty {
                        pendingConfigCard
                    }
                    diagnosticsSection
                }
                .padding(.top, 8)
            }
        }
        .padding(.top, 4)
    }

    /// `.v2-set-fn`：11/500、居中、text-3
    private var footNote: some View {
        Text("车辆数据仅存本机 · 不上传云端")
            .v2Text(.label11, color: V2Color.text3)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 4)
    }
}

// MARK: - 设置卡片容器

/// v2 的区块：**标题在卡片内部**（`.v2-set-col` 的第一行），
/// 不是 v1 那种「卡外小标题 + 白卡」。这一条决定整屏的纵向节奏，
/// 所以所有区块共用它，不许各自拼。
private struct SettingsCard<Content: View>: View {

    let title: String
    /// 标题右侧的计数徽标（如「20 项」），`.v2-set-badge`
    var badge: String?
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(title)
                    .v2Text(.setSub13, color: V2Color.text2)
                if let badge {
                    Text(badge)
                        .v2Text(.chip11, color: V2Color.info)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(V2Color.tintInfo)
                        .clipShape(Capsule())
                }
            }

            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .v2Card()
    }
}

// MARK: - 验证码输入弹窗

private struct SMSCodeSheet: View {

    let model: SettingsViewModel
    let phone: String

    @Environment(\.dismiss) private var dismiss
    @Environment(AppStore.self) private var store
    @State private var code = ""
    @FocusState private var focused: Bool

    var body: some View {
        V2BottomSheet(
            title: "输入验证码",
            closeTitle: "取消",
            onClose: { dismiss() },
            heightRatio: 0.56
        ) {
            VStack(spacing: 16) {
                Text("验证码已发送至 \(phone)")
                    .v2Text(.text13m, color: V2Color.text2)
                    .padding(.top, 4)

                // 极氪**国区的验证码是 4 位**（2026-10-16 实测）。此前写死 6 位，
                // 用户收到 4 位码时永远凑不满，「确认登录」点不动 —— 登录链路直接死在这里。
                // 长度上限放宽到 8 位（与后端 `4 <= len(code) <= 8` 的校验一致），
                // 具体几位由网关判断，客户端只做基本格式校验。
                TextField("4 位验证码", text: $code)
                    .v2Text(.hero26)
                    .multilineTextAlignment(.center)
                    .keyboardType(.numberPad)
                    .textContentType(.oneTimeCode)
                    .focused($focused)
                    .frame(height: 52)
                    .background(Color.white.opacity(0.45))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .onChange(of: code) { _, value in
                        // 只保留数字，最多 8 位
                        let filtered = String(value.filter(\.isNumber).prefix(8))
                        if filtered != value { code = filtered }
                    }

                if let error = model.loginError {
                    Text(error)
                        .v2Text(.foot11, color: V2Color.bad)
                }

                Button {
                    Task {
                        if await model.verifyCode(code) {
                            // 登录成功立刻取一次车况，否则要等到下一个轮询周期
                            // 首页才从「去登录」切回真实数据。
                            await store.refresh()
                            dismiss()
                            // 登录的目的就是看车况 —— 停在设置页等用户自己点 tab
                            // 是没必要的额外一步（此前就是这样，登录完像"什么都没发生"）。
                            // 放在 dismiss 之后：先让 sheet 收起来，再切页面，
                            // 否则设置页在 sheet 展开时被销毁，弹窗会硬闪一下。
                            store.selectedTab = .dashboard
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        if model.isVerifying {
                            ProgressView().controlSize(.small)
                        }
                        Text(model.isVerifying ? "验证中" : "确认登录")
                            .v2Text(.btn15, color: .white)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                    .background(canSubmit ? V2Color.accent : V2Color.text3.opacity(0.4))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(!canSubmit)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
        }
        .onAppear { focused = true }
    }

    /// 国区验证码 4 位；按后端校验放宽到 4–8 位，不再写死 6 位
    private var canSubmit: Bool {
        (4...8).contains(code.count) && !model.isVerifying
    }
}
