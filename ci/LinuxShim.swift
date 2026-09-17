#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// ── 仅为 Linux 类型检查补齐的平台差异（macOS/iOS 上原生存在）──
#if !canImport(Darwin)
import Foundation

extension URLSessionConfiguration {
    // Linux Foundation 把该属性实现为只读，macOS 可写；
    // 用关联存储模拟可写语义，仅为通过类型检查
    var waitsForConnectivitySettable: Bool {
        get { false }
        set { _ = newValue }
    }
}

extension URL {
    // iOS/macOS 沙盒安全作用域 API，Linux 无
    func startAccessingSecurityScopedResource() -> Bool { true }
    func stopAccessingSecurityScopedResource() {}
}
#endif
