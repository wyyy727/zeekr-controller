//
//  KeyboardDismiss.swift
//  ZeekrDash
//
//  全局「收起键盘」出口。
//
//  为什么需要它：本 App 的文本输入全是**数字键盘**（手机号、API 令牌），
//  数字键盘没有 Return 键，系统因此不给任何「收起」通路 —— 用户在设置页
//  输入手机号后，键盘只能靠下拉列表收起，看着就像「关不掉」。
//
//  为什么不用 `@FocusState`：它必须对**每一个** TextField 单独绑定，
//  页面一多就会漏（漏了那个字段就还是关不掉）。这里直接走 UIKit 的
//  responder chain，谁拿到焦点就收谁，与 Web 里点空白处失焦等价。
//

import SwiftUI
import UIKit

/// 无条件收起当前键盘（无焦点时是空操作）。
func dismissKeyboard() {
    _ = UIApplication.shared.sendAction(
        #selector(UIResponder.resignFirstResponder),
        to: nil, from: nil, for: nil
    )
}
