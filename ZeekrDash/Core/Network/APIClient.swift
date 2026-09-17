//
//  APIClient.swift
//  ZeekrDash
//
//  网络客户端：URLSession + async/await，统一错误处理
//

import Foundation

// MARK: - 错误定义

enum ApiError: LocalizedError {
    /// 地址无效或未配置
    case invalidURL
    /// 请求失败（网络不通、超时等）
    case transport(underlying: Error)
    /// 服务端返回非 2xx
    case http(statusCode: Int)
    /// 服务端 success = false
    case server(message: String)
    /// 响应解析失败
    case decoding(underlying: Error)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "服务端地址无效，请在设置中检查"
        case .transport(let err):
            return "网络请求失败：\(err.localizedDescription)"
        case .http(let code):
            return "服务端错误（HTTP \(code)）"
        case .server(let msg):
            return msg
        case .decoding:
            return "数据解析失败，请检查服务端版本"
        }
    }
}

// MARK: - 客户端

final class APIClient {

    static let shared = APIClient()

    /// 默认 BaseURL，可在设置中覆盖
    static let defaultBaseURL = "http://localhost:8765"

    /// 当前 BaseURL（由 SettingsStore 在启动及修改时同步进来）
    var baseURL: String = defaultBaseURL

    private let session: URLSession
    private let decoder = JSONDecoder.zeekr

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 60
        config.waitsForConnectivity = false
        session = URLSession(configuration: config)
    }

    // MARK: - 通用 GET

    func get<T: Codable>(_ path: String, query: [String: String] = [:]) async throws -> T {
        guard var components = URLComponents(string: normalizedBaseURL + path) else {
            throw ApiError.invalidURL
        }
        if !query.isEmpty {
            components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = components.url else { throw ApiError.invalidURL }

        let request = URLRequest(url: url)
        return try await run(request)
    }

    // MARK: - 通用 POST（JSON body）

    func post<T: Codable>(_ path: String, body: [String: Any] = [:]) async throws -> T {
        guard let url = URL(string: normalizedBaseURL + path) else { throw ApiError.invalidURL }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        return try await run(request)
    }

    // MARK: - 通用 DELETE

    func delete<T: Codable>(_ path: String) async throws -> T {
        guard let url = URL(string: normalizedBaseURL + path) else { throw ApiError.invalidURL }

        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"

        return try await run(request)
    }

    // MARK: - 文件上传（账单导入）

    /// multipart/form-data 上传账单文件
    func uploadFile<T: Codable>(_ path: String, fileURL: URL, fieldName: String = "file") async throws -> T {
        guard let url = URL(string: normalizedBaseURL + path) else { throw ApiError.invalidURL }

        let fileData: Data
        do {
            // 安全读取用户通过 fileImporter 选择的文件（仅临时授权访问）
            let scoped = fileURL.startAccessingSecurityScopedResource()
            defer { if scoped { fileURL.stopAccessingSecurityScopedResource() } }
            fileData = try Data(contentsOf: fileURL)
        } catch {
            throw ApiError.transport(underlying: error)
        }

        let boundary = "ZeekrDash-\(UUID().uuidString)"
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        let filename = fileURL.lastPathComponent
        let mime = mimeType(for: filename)
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"\(fieldName)\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: \(mime)\r\n\r\n".data(using: .utf8)!)
        body.append(fileData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body

        return try await run(request)
    }

    // MARK: - 健康检查（不计入统一错误提示，返回 Bool）

    func healthCheck() async -> Bool {
        struct Health: Codable { var status: String? }
        do {
            let _: APIResponse<Health> = try await get(APIRoutes.health)
            return true
        } catch {
            return false
        }
    }

    // MARK: - 内部

    /// 规范化 BaseURL：去掉尾部斜杠
    private var normalizedBaseURL: String {
        var base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if base.isEmpty { base = Self.defaultBaseURL }
        while base.hasSuffix("/") { base.removeLast() }
        return base
    }

    private func run<T: Codable>(_ request: URLRequest) async throws -> T {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ApiError.transport(underlying: error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw ApiError.transport(underlying: URLError(.badServerResponse))
        }
        guard (200..<300).contains(http.statusCode) else {
            throw ApiError.http(statusCode: http.statusCode)
        }

        do {
            let wrapped = try decoder.decode(APIResponse<T>.self, from: data)
            guard wrapped.success, let payload = wrapped.data else {
                throw ApiError.server(message: wrapped.error ?? "服务端返回失败")
            }
            return payload
        } catch let error as ApiError {
            throw error
        } catch {
            throw ApiError.decoding(underlying: error)
        }
    }

    private func mimeType(for filename: String) -> String {
        switch (filename as NSString).pathExtension.lowercased() {
        case "csv":  return "text/csv"
        case "xlsx": return "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
        default:     return "application/octet-stream"
        }
    }
}

private extension Data {
    mutating func append(_ string: String) {
        append(string.data(using: .utf8) ?? Data())
    }
}
