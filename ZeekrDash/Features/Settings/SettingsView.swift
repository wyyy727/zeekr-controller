//
//  SettingsView.swift
//  ZeekrDash
//
//  设置页
//

import SwiftUI

/// 设置页：服务端地址、账号登录、轮询、车控开关、诊断
struct SettingsView: View {

    @Environment(SettingsStore.self) private var settings
    @Environment(AppStore.self) private var store
    @Environment(\.colorScheme) private var scheme

    @State private var model = SettingsViewModel()
    @State private var showCodeSheet = false
    /// 服务端地址输入框焦点：失焦即提交，避免「改完不按回车」导致不生效
    @FocusState private var isAddressFocused: Bool
    /// API 令牌输入框焦点，同上
    @FocusState private var isTokenFocused: Bool

    var body: some View {
        // 页面标题与底部导航重复，已移除；顶部右上角为数据来源徽标
        NavigationStack {
            ScreenContainer(modeText: store.modeBadgeText) {
                connectionSection
                if model.isLocalEndpoint {
                    mockNotice
                } else {
                    accountSection
                }
                pollingSection
                commandSection
                capabilitySection
                diagnosticsSection
                aboutSection
            }
            .toolbar(.hidden, for: .navigationBar)
            .task { await model.checkHealth(baseURL: settings.baseURL) }
            .sheet(isPresented: $showCodeSheet) {
                SMSCodeSheet(model: model, phone: model.pendingPhone)
            }
        }
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
                HStack {
                    Text("地址")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textSecondary(scheme))
                    Spacer()
                    TextField("http://192.168.1.10:8765", text: Bindable(settings).baseURL)
                        .font(.system(size: 13))
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

                Divider().overlay(Theme.separator(scheme))

                HStack {
                    Text("API 令牌")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textSecondary(scheme))
                    Spacer()
                    SecureField("未启用可留空", text: Bindable(settings).apiToken)
                        .font(.system(size: 13))
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
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary(scheme))
                    .frame(maxWidth: .infinity, alignment: .leading)

                Divider().overlay(Theme.separator(scheme))

                HStack {
                    Text("状态")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textSecondary(scheme))
                    Spacer()
                    connectionBadge
                }

                if model.isLocalEndpoint {
                    Text("地址为空或指向本机，将直接展示内置模拟数据（不联网）")
                        .font(.system(size: 11))
                        .foregroundStyle(ChineseColor.statusWarn)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var connectionBadge: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(connectionColor)
                .frame(width: 7, height: 7)

            Text(connectionText)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(connectionColor)

            if model.isChecking {
                ProgressView().controlSize(.mini)
            }
        }
    }

    private var connectionColor: Color {
        if model.isChecking { return Theme.textTertiary(scheme) }
        // 地址为空 / localhost：按约定走模拟数据，不算失败
        if model.isLocalEndpoint { return ChineseColor.statusWarn }
        return model.isReachable ? ChineseColor.statusGood : ChineseColor.statusBad
    }

    private var connectionText: String {
        if model.isChecking { return "检测中" }
        if model.isLocalEndpoint { return "模拟数据" }
        return model.isReachable ? "已连接" : "未连接"
    }

    /// 诊断区展示的数据来源文案
    private var diagnosticsSourceText: String {
        switch store.dataMode {
        case .mock:    return "本地模拟数据"
        case .live:    return "真实服务端"
        case .offline: return "模拟数据（后端不可达）"
        }
    }

    private var mockNotice: some View {        HStack(spacing: 8) {
            Image(systemName: "info.circle.fill")
                .font(.system(size: 13))
                .foregroundStyle(ChineseColor.statusWarn)
            Text("演示模式：地址未配置或指向本机，界面展示的是内置模拟数据")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary(scheme))
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ChineseColor.tengHuang.opacity(scheme == .dark ? 0.10 : 0.14))
        .clipShape(RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous))
    }

    // MARK: - 账号

    private var accountSection: some View {
        SettingsCard(title: "极氪账号") {
            VStack(spacing: 10) {
                HStack {
                    Text("登录状态")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textSecondary(scheme))
                    Spacer()
                    HStack(spacing: 5) {
                        Circle()
                            .fill(model.isAuthenticated ? ChineseColor.statusGood : Theme.textTertiary(scheme))
                            .frame(width: 7, height: 7)
                        Text(model.isAuthenticated ? "已登录" : "未登录")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Theme.textPrimary(scheme))
                    }
                }

                Divider().overlay(Theme.separator(scheme))

                HStack {
                    Text("手机号")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textSecondary(scheme))
                    Spacer()
                    TextField("13800138000", text: Bindable(model).phone)
                        .font(.system(size: 13))
                        .multilineTextAlignment(.trailing)
                        .keyboardType(.numberPad)
                }

                Button {
                    Task {
                        let sent = await model.sendCode()
                        if sent { showCodeSheet = true }
                    }
                } label: {
                    HStack {
                        if model.isSending {
                            ProgressView().controlSize(.small)
                        }
                        Text(model.isSending ? "发送中" : "获取验证码")
                            .font(.system(size: 14, weight: .medium))
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: Metrics.minTouchTarget)
                    .foregroundStyle(ChineseColor.xiangYaBai)
                    .background(canSendCode ? Theme.accent(scheme) : Theme.textTertiary(scheme).opacity(0.4))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .disabled(!canSendCode)

                if let message = model.accountMessage {
                    Text(message)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textTertiary(scheme))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Text("建议使用独立的极氪子账号并共享车辆，避免与手机 App 会话冲突")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary(scheme))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var canSendCode: Bool {
        !model.isSending && model.phone.count == 11 && model.phone.allSatisfy(\.isNumber)
    }

    // MARK: - 轮询

    private var pollingSection: some View {
        SettingsCard(title: "数据刷新") {
            VStack(spacing: 10) {
                HStack {
                    Text("轮询间隔")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textSecondary(scheme))
                    Spacer()
                    Text("\(Int(settings.pollIntervalMinutes)) 分钟")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.textPrimary(scheme))
                        .monospacedDigit()
                }

                Slider(
                    value: Bindable(settings).pollIntervalMinutes,
                    in: 1...30,
                    step: 1
                )
                .tint(Theme.accent(scheme))

                Text("充电中会自动缩短到 60 秒，及时反映充电进度")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary(scheme))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: - 车控

    private var commandSection: some View {
        SettingsCard(title: "车辆控制") {
            VStack(spacing: 8) {
                Toggle(isOn: Bindable(settings).commandsEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("允许下发控制指令")
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.textPrimary(scheme))
                        Text("关闭时 App 仅可查看，不能操作车辆")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textTertiary(scheme))
                    }
                }
                .tint(Theme.accent(scheme))

                if settings.commandsEnabled {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 11))
                        Text("远程控制存在风险，请确认车辆处于安全场景")
                            .font(.system(size: 11))
                    }
                    .foregroundStyle(ChineseColor.statusWarn)
                    .frame(maxWidth: .infinity, alignment: .leading)

                    // 服务端没开时如实说明 —— 否则用户会以为「开关都开了怎么还是失败」
                    if model.serverAllowCommands == false {
                        Text("服务端也没有开启车控（.env 里 ALLOW_COMMANDS=true），即便本开关打开，指令仍会被拒绝")
                            .font(.system(size: 11))
                            .foregroundStyle(ChineseColor.statusBad)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                Text("总开关（默认关）与「诊断」里的「服务端车控」是两把锁，都要打开才能下发指令。")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary(scheme))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
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

    private var capabilitySection: some View {
        SettingsCard(title: "车辆权限") {
            VStack(alignment: .leading, spacing: 10) {
                permissionChips

                Text(capabilityHint)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary(scheme))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// 「这台车开通了什么」的原始清单。
    ///
    /// 取不到时如实说「没取到」，而不是显示一个空列表 —— 后者会被读成
    /// 「什么权限都没有」，那是把「不知道」谎报成「确认没有」。
    @ViewBuilder
    private var permissionChips: some View {
        if let permissions = store.permissions, !permissions.isEmpty {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 88), spacing: 6)],
                alignment: .leading,
                spacing: 6
            ) {
                ForEach(permissions, id: \.self) { permission in
                    Text(Self.permissionLabels[permission] ?? permission)
                        .font(.system(size: 11.5))
                        .foregroundStyle(ChineseColor.qingBi)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .frame(maxWidth: .infinity)
                        .background(ChineseColor.qingBi.opacity(0.10))
                        .clipShape(Capsule())
                }
            }
        } else {
            Text(store.permissions == nil
                 ? "尚未取到权限包，界面按「全部显示」处理。"
                 : "服务端确认这台车没有任何权限包。")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textTertiary(scheme))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// 卡片脚注。
    ///
    /// 除来源之外，把**被隐藏的按钮名逐个列出来** —— 这张卡存在的意义就是让
    /// 「某个按钮怎么不见了」变得可解释，只报个数字等于没说。
    private var capabilityHint: String {
        let source = "来源：ms-app-bff/api/1.0/permissions"
        guard let permissions = store.permissions, !permissions.isEmpty else {
            return source + " · 未取到时界面按「全部显示」处理"
        }
        let hidden = VehicleCommand.allCases
            .filter { !store.isCapabilityAvailable($0) }
            .map(\.displayName)
        guard !hidden.isEmpty else {
            return "\(source) · \(permissions.count) 项 · 界面已按此裁剪"
        }
        return "\(source) · \(permissions.count) 项 · 已隐藏：\(hidden.joined(separator: "、"))"
    }

    // MARK: - 诊断

    private var diagnosticsSection: some View {
        SettingsCard(title: "诊断") {
            VStack(spacing: 0) {
                diagnosticRow("数据来源", value: diagnosticsSourceText)
                Divider().overlay(Theme.separator(scheme))
                diagnosticRow("配置完整", value: model.isLiveConfigured ? "是" : "否")
                Divider().overlay(Theme.separator(scheme))
                // 服务端那把锁（.env 的 ALLOW_COMMANDS）。与设置页的车控总开关
                // 是两回事：一个管"发不发"，一个管"收不收"。取不到时显示 `--`。
                diagnosticRow("服务端车控", value: model.serverAllowCommands.map {
                    $0 ? "已开启" : "已禁用"
                } ?? "--")
                Divider().overlay(Theme.separator(scheme))
                diagnosticRow("上次刷新", value: store.lastRefresh.map {
                    $0.formatted(date: .omitted, time: .shortened)
                } ?? "--")

                if !model.missingKeys.isEmpty {
                    Divider().overlay(Theme.separator(scheme))
                    VStack(alignment: .leading, spacing: 4) {
                        Text("缺少的服务端配置")
                            .font(.system(size: 12))
                            .foregroundStyle(ChineseColor.statusWarn)
                        Text(model.missingKeys.joined(separator: "\n"))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(Theme.textTertiary(scheme))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
                }
            }
        }
    }

    private func diagnosticRow(_ title: String, value: String) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 13))
                .foregroundStyle(Theme.textSecondary(scheme))
            Spacer()
            Text(value)
                .font(.system(size: 13))
                .foregroundStyle(Theme.textPrimary(scheme))
        }
        .padding(.vertical, 9)
    }

    // MARK: - 关于

    private var aboutSection: some View {
        SettingsCard(title: "关于") {
            VStack(alignment: .leading, spacing: 8) {
                Text("ZeekrDash")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Theme.textPrimary(scheme))

                Text("非官方工具，基于社区逆向研究成果实现。与极氪、吉利无任何关联，仅供个人自用。")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary(scheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - 设置卡片容器

private struct SettingsCard<Content: View>: View {

    let title: String
    @ViewBuilder let content: () -> Content

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.textTertiary(scheme))
                .padding(.leading, 4)

            content()
                .padding(Metrics.cardPadding)
                .background(Theme.surface(scheme))
                .clipShape(RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous))
        }
    }
}

// MARK: - 验证码输入弹窗

private struct SMSCodeSheet: View {

    let model: SettingsViewModel
    let phone: String

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @Environment(AppStore.self) private var store
    @State private var code = ""
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Text("验证码已发送至 \(phone)")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary(scheme))
                    .padding(.top, 20)

                // 极氪**国区的验证码是 4 位**（2026-10-16 实测）。此前写死 6 位，
                // 用户收到 4 位码时永远凑不满，「确认登录」点不动 —— 登录链路直接死在这里。
                // 长度上限放宽到 8 位（与后端 `4 <= len(code) <= 8` 的校验一致），
                // 具体几位由网关判断，客户端只做基本格式校验。
                TextField("4 位验证码", text: $code)
                    .font(.system(size: 26, weight: .medium, design: .rounded))
                    .multilineTextAlignment(.center)
                    .keyboardType(.numberPad)
                    .textContentType(.oneTimeCode)
                    .focused($focused)
                    .frame(height: 56)
                    .background(Theme.surfaceAlt(scheme))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .padding(.horizontal, 32)
                    .onChange(of: code) { _, value in
                        // 只保留数字，最多 8 位
                        let filtered = String(value.filter(\.isNumber).prefix(8))
                        if filtered != value { code = filtered }
                    }

                if let error = model.loginError {
                    Text(error)
                        .font(.system(size: 12))
                        .foregroundStyle(ChineseColor.statusBad)
                }

                Button {
                    Task {
                        if await model.verifyCode(code) {
                            // 登录成功立刻取一次车况，否则要等到下一个轮询周期
                            // 首页才从「去登录」切回真实数据。
                            await store.refresh()
                            dismiss()
                        }
                    }
                } label: {
                    HStack {
                        if model.isVerifying {
                            ProgressView().controlSize(.small)
                        }
                        Text(model.isVerifying ? "验证中" : "确认登录")
                            .font(.system(size: 15, weight: .medium))
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: Metrics.minTouchTarget)
                    .foregroundStyle(ChineseColor.xiangYaBai)
                    .background(canSubmit ? Theme.accent(scheme) : Theme.textTertiary(scheme).opacity(0.4))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .disabled(!canSubmit)
                .padding(.horizontal, 32)

                Spacer()
            }
            .background(Theme.background(scheme))
            .navigationTitle("输入验证码")
            .toolbar(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
            }
        }
        .onAppear { focused = true }
    }

    /// 国区验证码 4 位；按后端校验放宽到 4–8 位，不再写死 6 位
    private var canSubmit: Bool {
        (4...8).contains(code.count) && !model.isVerifying
    }
}
