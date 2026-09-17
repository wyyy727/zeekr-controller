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

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: Metrics.sectionSpacing) {
                    connectionSection
                    if model.isMock {
                        mockNotice
                    } else {
                        accountSection
                    }
                    pollingSection
                    commandSection
                    diagnosticsSection
                    aboutSection
                }
                .padding(.horizontal, Metrics.screenPadding)
                .padding(.bottom, 24)
            }
            .background(Theme.background(scheme))
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.large)
            .task { await model.checkHealth(baseURL: settings.baseURL) }
            .sheet(isPresented: $showCodeSheet) {
                SMSCodeSheet(model: model, phone: model.pendingPhone)
            }
        }
    }

    // MARK: - 服务端连接

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
                            Task {
                                APIClient.shared.baseURL = settings.baseURL
                                await model.checkHealth(baseURL: settings.baseURL)
                            }
                        }
                }

                Divider().overlay(Theme.separator(scheme))

                HStack {
                    Text("状态")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textSecondary(scheme))
                    Spacer()
                    connectionBadge
                }

                if model.isMock {
                    Text("当前服务端运行在模拟数据模式，未接入真实车辆")
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
        return model.isReachable ? ChineseColor.statusGood : ChineseColor.statusBad
    }

    private var connectionText: String {
        if model.isChecking { return "检测中" }
        return model.isReachable ? "已连接" : "未连接"
    }

    private var mockNotice: some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle.fill")
                .font(.system(size: 13))
                .foregroundStyle(ChineseColor.statusWarn)
            Text("演示模式：数据为本地生成，用于预览界面效果")
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
                }
            }
        }
    }

    // MARK: - 诊断

    private var diagnosticsSection: some View {
        SettingsCard(title: "诊断") {
            VStack(spacing: 0) {
                diagnosticRow("服务端模式", value: model.isMock ? "模拟数据" : "真实车辆")
                Divider().overlay(Theme.separator(scheme))
                diagnosticRow("配置完整", value: model.isLiveConfigured ? "是" : "否")
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
    @State private var code = ""
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Text("验证码已发送至 \(phone)")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary(scheme))
                    .padding(.top, 20)

                TextField("6 位验证码", text: $code)
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
                        // 只保留数字，最多 6 位
                        let filtered = String(value.filter(\.isNumber).prefix(6))
                        if filtered != value { code = filtered }
                    }

                if let error = model.loginError {
                    Text(error)
                        .font(.system(size: 12))
                        .foregroundStyle(ChineseColor.statusBad)
                }

                Button {
                    Task {
                        if await model.verifyCode(code) { dismiss() }
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
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
            }
        }
        .onAppear { focused = true }
    }

    private var canSubmit: Bool {
        code.count == 6 && !model.isVerifying
    }
}
