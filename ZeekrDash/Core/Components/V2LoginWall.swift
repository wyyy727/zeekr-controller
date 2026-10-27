//
//  V2LoginWall.swift
//  ZeekrDash
//
//  未登录引导卡（五屏共用）
//
//  规格出处：`index-v2.html` 的 `renderLoginWall()`（7203–7212）与 `.v2-wall*`
//  （2013–2019）。五屏在未登录时都显示这一张，而不是空白 —— 空白看起来像页面坏了。
//

import SwiftUI

struct V2LoginWall: View {

    /// 点「去登录」后要做什么（通常是切到设置页）
    var onGoSettings: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // `.v2-wall-ico svg { 32×32; color: rgba(103,66,232,.30) }`
            Image("ic-phone")
                .renderingMode(.template)
                .resizable()
                .frame(width: 32, height: 32)
                .foregroundStyle(V2Color.accent.opacity(0.30))

            Text("需要先登录极氪账号")
                .v2Text(.emptyTitle)
                .padding(.top, 12)

            Text("服务端已连上（真实数据模式）。\n登录前不会请求任何车况 / 行程 / 充电接口。")
                .v2Text(.wallDesc, color: V2Color.text3)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 7)

            Button(action: onGoSettings) {
                Text("去登录")
                    .v2Text(.button14, color: .white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .background(V2Color.accent)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .padding(.top, 18)
        }
        // `.v2-wall { padding: 36px 20px; text-align: center }`
        .padding(.horizontal, 20)
        .padding(.vertical, 36)
        .frame(maxWidth: .infinity)
        // 内距已由 `.v2-wall` 接管，卡片自身不再叠一层 16
        .v2Card(padding: 0)
    }
}
