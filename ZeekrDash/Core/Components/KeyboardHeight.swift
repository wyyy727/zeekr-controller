//
//  KeyboardHeight.swift
//  ZeekrDash
//
//  键盘在**屏幕坐标系**里遮住屏幕底部的高度（pt）。键盘收起时是 0。
//
//  为什么需要它：自绘的底部面板（`V2BottomSheet`）**不走系统的键盘避让** ——
//  面板自己 `.ignoresSafeArea(edges: .bottom)` 铺到屏幕物理底边，键盘弹起来就
//  整块压在面板上。表现是：验证码弹窗的输入框和「确认登录」全被键盘吃掉，
//  键盘毛玻璃底下只透出一条淡紫色（那就是被压住的确认按钮）。
//  系统不会替自绘面板抬位置，只能自己量键盘高度，再把面板整体上移这一段。
//
//  为什么不用 `GeometryReader` 的 `safeAreaInsets.bottom`：它给的是「上一层已经
//  算过避让」之后的剩余值 —— 面板外面已经 `.ignoresSafeArea(.bottom)` 了，
//  读到的恒为 0，正是「键盘明明在，却量不到」的原因。
//
//  写法与 `NetworkActivity` 一致：`@Observable` 单例 + **只在主线程写**，
//  SwiftUI 在 body 里读到 `value` 就自动建立依赖，不需要 @State/@StateObject。
//  通知回调挂在 `queue: .main`，所以写入天然在主线程。
//

import SwiftUI
import UIKit

@Observable
final class KeyboardHeight {

    static let shared = KeyboardHeight()

    /// 键盘遮住屏幕底边的高度。0 = 键盘收起。
    private(set) var value: CGFloat = 0

    private init() {
        let center = NotificationCenter.default

        /* 用 `willChangeFrame` 而不是 `willShow`/`willHide`：
           切换输入法、切换键盘类型（字母 ↔ 数字）时高度会变，但 show/hide 不一定再发；
           willChangeFrame 每次变化都发，收起时 end frame 落在屏幕外 —— 算出来就是 0。 */
        center.addObserver(
            forName: UIResponder.keyboardWillChangeFrameNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            self?.apply(note)
        }

        /* 收起时也显式清零：个别路径（外接键盘、系统手势收起）只发 hide 不发 changeFrame。 */
        center.addObserver(
            forName: UIResponder.keyboardWillHideNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.value = 0
        }
    }

    private func apply(_ note: Notification) {
        guard
            let frame = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue,
            let screen = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first?.screen
        else {
            value = 0
            return
        }
        // end frame 是屏幕坐标系：屏幕底边 − 键盘上沿 = 被遮住的高度
        value = max(0, screen.bounds.maxY - frame.minY)
    }
}
