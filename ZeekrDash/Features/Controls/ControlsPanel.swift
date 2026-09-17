//
//  ControlsPanel.swift
//  ZeekrDash
//
//  快捷车控面板
//

import SwiftUI

/// 快捷车控按钮面板
///
/// 安全设计：车控需要在「设置」中显式开启总开关，
/// 关闭时按钮呈禁用态并给出说明 —— 避免误触。
struct ControlsPanel: View {

    @Environment(AppStore.self) private var store
    @Environment(SettingsStore.self) private var settings
    @Environment(\.colorScheme) private var scheme

    /// 正在下发的指令（用于显示加载态，防止重复点击）
    @State private var pendingCommand: VehicleCommand?
    /// 指令结果提示
    @State private var toast: String?

    private let columns = [
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10),
    ]

    private var isEnabled: Bool {
        settings.commandsEnabled && !store.isLoading
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("快捷控制")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary(scheme))

                Spacer()

                if !settings.commandsEnabled {
                    Text("已禁用")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textTertiary(scheme))
                }
            }

            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(availableCommands, id: \.self) { command in
                    ControlButton(
                        command: command,
                        isPending: pendingCommand == command,
                        isEnabled: isEnabled
                    ) {
                        Task { await trigger(command) }
                    }
                }
            }

            if !settings.commandsEnabled {
                Text("在「设置」中开启控制指令开关后可用")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary(scheme))
            }
        }
        .padding(Metrics.cardPadding)
        .background(Theme.surface(scheme))
        .clipShape(RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous))
        .overlay(alignment: .top) {
            if let toast {
                Text(toast)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(ChineseColor.xiangYaBai)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(ChineseColor.xuanQing.opacity(0.92))
                    .clipShape(Capsule())
                    .offset(y: -34)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.25), value: toast)
    }

    /// 车况页只放最常用的四项，避免面板臃肿
    private var availableCommands: [VehicleCommand] {
        let locked = store.vehicleStatus?.isLocked ?? true
        return [
            locked ? .unlock : .lock,
            .climateOn,
            .flash,
            .honk,
        ]
    }

    @MainActor
    private func trigger(_ command: VehicleCommand) async {
        guard pendingCommand == nil else { return }
        pendingCommand = command
        defer { pendingCommand = nil }

        let result = await store.send(command: command)
        showToast(result?.success == true
                  ? "\(command.displayName)已下发"
                  : (result?.message ?? "指令下发失败"))
    }

    private func showToast(_ message: String) {
        toast = message
        Task {
            try? await Task.sleep(nanoseconds: 2_200_000_000)
            toast = nil
        }
    }
}

// MARK: - 单个控制按钮

private struct ControlButton: View {

    let command: VehicleCommand
    let isPending: Bool
    let isEnabled: Bool
    let action: () -> Void

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                if isPending {
                    ProgressView()
                        .controlSize(.small)
                        .frame(height: 22)
                } else {
                    Image(systemName: command.systemImage)
                        .font(.system(size: 18, weight: .medium))
                        .frame(height: 22)
                }

                Text(command.displayName)
                    .font(.system(size: 12))
                    .lineLimit(1)
            }
            // 保证触控目标不小于 44pt
            .frame(maxWidth: .infinity, minHeight: Metrics.minTouchTarget + 12)
            .foregroundStyle(isEnabled ? Theme.accent(scheme) : Theme.textTertiary(scheme))
            .background(Theme.surfaceAlt(scheme))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled || isPending)
        .accessibilityLabel(command.displayName)
    }
}
