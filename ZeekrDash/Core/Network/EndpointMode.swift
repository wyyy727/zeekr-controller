//
//  EndpointMode.swift
//  ZeekrDash
//
//  服务端地址形态判定 —— 决定数据来源的唯一依据
//
//  规则（与 preview/index.html 的 isLocalEndpoint() 保持一致）：
//
//    ┌ 地址未配置（空）           → .unset    → 模拟数据
//    ├ 地址指向 localhost/127.0.0.1 → .loopback → 模拟数据
//    └ 其余真实地址              → .remote   → 先请求真实数据，失败才回落模拟数据
//
//  「模拟数据」只在 .unset / .loopback 下静默展示；
//  .remote 连不上属于「配置了但不可用」，需要弹框告知用户再回落，
//  两种情况在徽标上都要能被区分出来。
//

import Foundation

/// 服务端地址形态
enum EndpointMode: Equatable {
    /// 未配置地址（空串）
    case unset
    /// 指向本机回环地址，如 localhost / 127.0.0.1
    case loopback
    /// 配置了指向真实主机的地址
    case remote

    /// 是否根本不需要发起网络请求，直接用本地模拟数据
    var preferredSourceIsMock: Bool {
        switch self {
        case .unset, .loopback: return true
        case .remote:           return false
        }
    }
}

enum EndpointResolver {

    /// 回环主机名（大小写不敏感）
    private static let loopbackHosts: Set<String> = [
        "localhost",
        "127.0.0.1",
        "0.0.0.0",
        "::1",
        "[::1]",
    ]

    /// 解析用户填写的地址属于哪种形态
    ///
    /// 容错处理：用户可能只填了 `192.168.1.10:8765` 而漏写协议，
    /// 直接交给 `URLComponents` 会把 host 解析成 nil，因此这里先补一个
    /// 协议头再解析。
    static func resolve(_ raw: String) -> EndpointMode {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .unset }

        guard let host = host(of: trimmed), !host.isEmpty else {
            // 填了内容但解析不出主机名，无法访问，按未配置处理
            return .unset
        }

        return loopbackHosts.contains(host.lowercased()) ? .loopback : .remote
    }

    /// 从地址串中取出主机名
    static func host(of raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let candidate = hasScheme(trimmed) ? trimmed : "http://\(trimmed)"

        guard let components = URLComponents(string: candidate) else {
            // 还有一类常见输入：`localhost:8765`，无协议且冒号被当成协议分隔符，
            // 补 `//` 再解析一次
            if let retry = URLComponents(string: "http://\(trimmed)") {
                return retry.host
            }
            return nil
        }

        if let host = components.host { return host }

        // 兜底：手工剥离 userinfo / port / path
        var manual = trimmed
        if let range = manual.range(of: "://") {
            manual = String(manual[range.upperBound...])
        }
        if let at = manual.firstIndex(of: "@") {
            manual = String(manual[manual.index(after: at)...])
        }
        if let slash = manual.firstIndex(of: "/") {
            manual = String(manual[..<slash])
        }
        if let colon = manual.firstIndex(of: ":") {
            manual = String(manual[..<colon])
        }
        return manual.isEmpty ? nil : manual
    }

    private static func hasScheme(_ value: String) -> Bool {
        guard let range = value.range(of: "://") else { return false }
        return !value[value.startIndex..<range.lowerBound].isEmpty
    }
}
