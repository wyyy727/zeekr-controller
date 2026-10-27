//
//  AssetSelfCheck.swift
//  ZeekrDash
//
//  资源自检：把「静默降级」变成可见错误
//

import UIKit

/// 启动时校验字体与图标是否真的进了 App。
///
/// 为什么需要它：这两类资源缺失**不会报错**。
/// · 字体没注册 → 悄悄用回 SF Pro，和「我没做 Inter 替换」长得一模一样；
/// · 图标没进 bundle → `Image("ctrl-lock")` 渲染成空白，actool 也不报警。
/// 两者都只能在真机上肉眼发现，而本机没有 Xcode —— 所以让 App 自己喊出来。
///
/// 只在 DEBUG 下跑：Release 不该因为一条断言崩在用户手机上。
enum AssetSelfCheck {

    /// `ZeekrDash/Resources/Icons.xcassets` 里的 imageset。改名 / 漏拷都会在这里被抓到。
    ///
    /// 两组来源：
    /// · 前 28 个是 `ios-icons/` 转来的矢量资产（底栏 + 车控 + 零散件）；
    /// · 后 35 个是 HTML **内联**的 `const SVG` 表（`index-v2.html:3720`），
    ///   统一 `ic-` 前缀 —— 空态、登录墙、行程、充电、设置都在用这批。
    ///   `ic-*` 由 `preview/index-v2.html` 的 SVG 表逐条转出（circle/rect 转 path、
    ///   currentColor 烘焙成 #000000、template 渲染），与那 28 个同一规格。
    ///   34 个键对应 34 个资产；`ic-chart-bar` 是第 35 个 —— `chart` 键在 HTML 里被
    ///   重复定义，运行时后者（折线）胜出，前者（柱状）是死代码，单独出资产备用。
    private static let iconNames: [String] = [
        // 底栏 5
        "tab-dashboard", "tab-trips", "tab-charging", "tab-controls", "tab-settings",
        // 车控 19
        "ctrl-lock", "ctrl-climate", "ctrl-defrost-front", "ctrl-steering-heat",
        "ctrl-seat-heat", "ctrl-flash", "ctrl-horn", "ctrl-window-close",
        "ctrl-charge-start", "ctrl-sentry", "ctrl-trip-plan", "ctrl-find-car",
        "ctrl-refresh", "ctrl-seat-vent", "ctrl-sunroof", "ctrl-trunk", "ctrl-frunk",
        "ctrl-drive-mode", "ctrl-home",
        // 其他 4
        "action-ocr-scan", "avatar-mark", "sheet-handle", "status-signal-battery",
        // 内联 SVG 35（HTML `const SVG` 表，含 chart 重复键的另一版）
        "ic-chart", "ic-chart-bar", "ic-route", "ic-phone", "ic-lock", "ic-unlock",
        "ic-snow", "ic-window", "ic-trunk", "ic-bolt", "ic-light",
        "ic-horn", "ic-plug", "ic-thermo", "ic-sun", "ic-battery",
        "ic-ruler", "ic-clock", "ic-car", "ic-money", "ic-car-lock",
        "ic-car-unlock", "ic-charge-port", "ic-defrost", "ic-wheel-heat", "ic-shield",
        "ic-sunshade", "ic-seats", "ic-vent", "ic-refresh", "ic-heat",
        "ic-pin", "ic-check", "ic-chevron", "ic-scan",
    ]

    /// 四个静态字重的 PostScript 名（见 `V2Font`）。
    private static let fontNames: [String] = [
        "Inter-Regular", "Inter-Medium", "Inter-SemiBold", "Inter-Bold",
    ]

    /// 返回缺失清单；全在则返回空数组。
    static func missingAssets() -> [String] {
        var missing: [String] = []

        for name in iconNames where UIImage(named: name) == nil {
            missing.append("图标 \(name)")
        }
        for name in fontNames where UIFont(name: name, size: 12) == nil {
            missing.append("字体 \(name)")
        }
        return missing
    }

    /// DEBUG 下把缺失打进控制台。
    ///
    /// 用 `print` 而不是 `assertionFailure`：CI 编的是 Release，
    /// 而真机调试时控制台一眼能看到；断言失败会直接中断调试流程。
    static func run() {
        #if DEBUG
        let missing = missingAssets()
        guard !missing.isEmpty else {
            print("[AssetSelfCheck] \(iconNames.count + fontNames.count) 项资源（\(iconNames.count) 图标 + \(fontNames.count) 字体）全部就位")
            return
        }
        print("[AssetSelfCheck] ⚠️ 缺失 \(missing.count) 项：")
        for item in missing { print("  · \(item)") }
        print("[AssetSelfCheck] 参考：资源必须放在 ZeekrDash/Resources/ 下才会被 xcodegen 收进 App")
        #endif
    }
}
