//
//  WebShellView.swift
//  ZeekrDash
//
//  B 档：WKWebView 直接加载后端托管的网页版界面
//
//  为什么是它：网页版（preview/index-v2.html，近 8000 行、149 个组件类、
//  14 组自定义动画、52 处毛玻璃）与原生五屏是两套独立实现，逐屏对齐的
//  成本远高于「直接嵌」。而后端 main.py 的 mount_preview 已经把 preview
//  目录挂在 /preview 上，WKWebView 加载同一个 URL 即可得到 100% 一致的
//  界面与动效，网页改了也不用重新打包。
//
//  已知取舍（是设计代价，不是 bug）：
//  · 依赖电脑后端在线；连不上时是本页的错误态，不会退回本地模拟数据
//  · 页面跑在 http 非安全上下文，WebKit 拒绝 navigator.geolocation，
//    附近充电站要在页面里手动填坐标（页面已提供该入口）
//  · 滚动惯性、长按选择、下拉回弹都是 Web 手感，与原生页不同
//  · 界面里的颜色/字号来自网页 CSS，不跟随 iOS 深浅色主题
//
//  开关在「设置 → Web 版界面（实验）」，默认关闭；左上角常驻一个「原生」
//  按钮，任何时候都能切回五屏原生界面。
//

import SwiftUI
import WebKit

struct WebShellView: View {

    @Environment(SettingsStore.self) private var settings

    /// 页面加载失败的原因（nil 表示当前正常）
    @State private var errorText: String?
    /// 自增即触发一次重新加载
    @State private var reloadTick = 0

    var body: some View {
        ZStack(alignment: .topLeading) {
            WebContainer(url: shellURL, reloadTick: reloadTick) { message in
                errorText = message
            }
            .ignoresSafeArea()

            if let errorText {
                errorPanel(errorText)
            }

            topBar
        }
        .background(Color(red: 0.96, green: 0.97, blue: 0.99))
    }

    // MARK: - 目标地址

    /// 把设置页里的服务端地址拼成网页入口。
    ///
    /// 用 `?debug=1&api=...` 而不是依赖同源推断：网页版默认「不请求后端」，
    /// 必须显式打开才发真实请求（见 index-v2.html 的 defaultApiSource）。
    private var shellURL: URL? {
        let base = settings.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty, var comps = URLComponents(string: base) else { return nil }
        guard let scheme = comps.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        comps.path = "/preview/index-v2.html"
        var items = [
            URLQueryItem(name: "debug", value: "1"),
            URLQueryItem(name: "api", value: base),
        ]
        let token = settings.apiToken.trimmingCharacters(in: .whitespacesAndNewlines)
        if !token.isEmpty {
            items.append(URLQueryItem(name: "token", value: token))
        }
        comps.queryItems = items
        return comps.url
    }

    // MARK: - 顶部常驻操作条

    private var topBar: some View {
        HStack(spacing: 8) {
            Button {
                settings.webShellEnabled = false
            } label: {
                Label("原生", systemImage: "chevron.left")
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(.ultraThinMaterial, in: Capsule())
            }

            Spacer(minLength: 0)

            Button {
                errorText = nil
                reloadTick += 1
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12, weight: .semibold))
                    .padding(9)
                    .background(.ultraThinMaterial, in: Circle())
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 6)
    }

    private func errorPanel(_ text: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 26))
                .foregroundStyle(.orange)
            Text("网页版界面没有加载出来")
                .font(.system(size: 15, weight: .semibold))
            Text(text)
                .font(.system(size: 12))
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button("重试") {
                    errorText = nil
                    reloadTick += 1
                }
                Button("回原生") { settings.webShellEnabled = false }
            }
            .font(.system(size: 13, weight: .semibold))
        }
        .padding(20)
        .frame(maxWidth: 300)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .padding(.horizontal, 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - WKWebView 包装

private struct WebContainer: UIViewRepresentable {

    let url: URL?
    let reloadTick: Int
    let onError: (String?) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onError: onError)
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        // 网页里「导航到这里」用的是 window.open，不打开这个开关拿不到回调
        config.preferences.javaScriptCanOpenWindowsAutomatically = true

        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = context.coordinator
        web.uiDelegate = context.coordinator
        // 单页应用：没有可回退的历史，开了只会误触
        web.allowsBackForwardNavigationGestures = false
        // 外层已经 ignoresSafeArea，这里再让 WebView 自动加内距就会出现双份留白
        web.scrollView.contentInsetAdjustmentBehavior = .never
        // 长按弹预览会盖住图表气泡，且网页本身没有可预览的链接
        web.allowsLinkPreview = false
        web.isOpaque = false
        web.backgroundColor = .clear

        context.coordinator.load(url: url, in: web, tick: reloadTick)
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {
        context.coordinator.load(url: url, in: web, tick: reloadTick)
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {

        private let onError: (String?) -> Void
        /// 已发起过的「地址 + 重载序号」，避免 SwiftUI 每次刷新都重新 load
        private var lastKey = ""

        init(onError: @escaping (String?) -> Void) {
            self.onError = onError
        }

        func load(url: URL?, in web: WKWebView, tick: Int) {
            guard let url else {
                report("还没有配置服务端地址。请先到「设置 → 服务端」填上电脑的局域网地址，例如 http://192.168.1.10:8765")
                return
            }
            let key = url.absoluteString + "#" + String(tick)
            guard key != lastKey else { return }
            lastKey = key
            web.load(URLRequest(url: url))
        }

        private func report(_ message: String?) {
            DispatchQueue.main.async { [onError] in onError(message) }
        }

        // MARK: 加载结果

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            report(nil)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            report(error.localizedDescription)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            let host = webView.url?.host ?? "服务端"
            report("连不上 " + host + "：" + error.localizedDescription + "。请确认电脑后端已启动、手机与电脑在同一个 Wi-Fi，并且地址填的是电脑的局域网 IP。")
        }

        // MARK: 站外跳转交给系统

        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.allow)
                return
            }
            let scheme = (url.scheme ?? "").lowercased()
            // iosamap:// 之类的自定义 scheme 只能交给系统
            if scheme != "http" && scheme != "https" {
                open(url)
                decisionHandler(.cancel)
                return
            }
            // 站外链接（高德网页版等）用 Safari 打开，别把 WebView 带走
            if navigationAction.navigationType == .linkActivated, url.host != webView.url?.host {
                open(url)
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }

        /// window.open / target=_blank 会走到这里；返回 nil 表示不开新窗口，
        /// 由系统浏览器接管（网页里「导航到这里」就是这条路）。
        func webView(_ webView: WKWebView,
                     createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction,
                     windowFeatures: WKWindowFeatures) -> WKWebView? {
            if let url = navigationAction.request.url { open(url) }
            return nil
        }

        private func open(_ url: URL) {
            DispatchQueue.main.async {
                UIApplication.shared.open(url)
            }
        }
    }
}
