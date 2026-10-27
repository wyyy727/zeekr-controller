//
//  V2StaleBanner.swift
//  ZeekrDash
//
//  「这一轮没读到，下面是上次的数据」横幅（HTML `.v2-stale`）
//
//  四个数据屏（车况 / 车控 / 行程 / 充电）原来是各抄一份，48 行里 40 行完全一样，
//  只有文案和重试动作不同。抽在这里，改样式只改一处。
//

import SwiftUI

struct V2StaleBanner: View {

    /// 左侧说明，例如「这一轮没读到最新车况，下面是上次读到的数据」
    let text: String
    /// 失败详情（错误原文），只用于无障碍朗读；不传就读 `text`
    var detail: String?
    /// 点「重试」做什么：各屏的刷新入口不同（`store.refresh()` / `model.load()`）
    let onRetry: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(text)
                .v2Text(.text12, color: V2Color.text1)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)

            Button("重试", action: onRetry)
                .v2Text(.text12, color: V2Color.bad)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        // `.v2-stale`：bg #FFF1F4 + 内描边 rgba(240,106,128,.35) + r16
        .background(V2Color.tintBad)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(V2Color.bad.opacity(0.35), lineWidth: 1)
        )
        .accessibilityLabel("读取失败：\(detail ?? text)")
    }
}
