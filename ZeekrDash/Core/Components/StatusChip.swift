//
//  StatusChip.swift
//  ZeekrDash
//
//  车身状态小标签
//

import SwiftUI

/// 车身状态指示标签
///
/// 用「图标 + 状态文字」表达车门/车窗/空调等二值状态。
/// `neutral` 用于那些「开启也是正常」的状态（如空调），避免误用告警色。
struct StatusChip: View {

    let title: String
    let isGood: Bool
    let goodText: String
    let badText: String
    let icon: String
    /// 中性状态：不用红/绿区分，统一用主色
    var neutral: Bool = false

    @Environment(\.colorScheme) private var scheme

    private var accentColor: Color {
        if neutral { return Theme.accentSecondary(scheme) }
        return isGood ? ChineseColor.statusGood : ChineseColor.statusWarn
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(accentColor)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary(scheme))
                Text(isGood ? goodText : badText)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.textPrimary(scheme))
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, minHeight: 48)
        .background(Theme.surfaceAlt(scheme))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title)\(isGood ? goodText : badText)")
    }
}

#Preview {
    VStack(spacing: 10) {
        HStack(spacing: 10) {
            StatusChip(title: "车门", isGood: true, goodText: "已锁", badText: "未锁", icon: "lock.fill")
            StatusChip(title: "车窗", isGood: false, goodText: "已关", badText: "未关", icon: "car.window.left")
        }
        HStack(spacing: 10) {
            StatusChip(title: "空调", isGood: true, goodText: "开启", badText: "关闭", icon: "snowflake", neutral: true)
            StatusChip(title: "后备箱", isGood: true, goodText: "已关", badText: "开启", icon: "car.side.rear.open")
        }
    }
    .padding()
    .background(Theme.background(.light))
}
