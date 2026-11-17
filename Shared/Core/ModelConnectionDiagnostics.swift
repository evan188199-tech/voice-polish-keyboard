import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Offline validation and user-facing diagnostics. This type performs no network requests.
enum ModelConnectionDiagnostics {
    enum AddressResult: Equatable, CustomStringConvertible, CustomDebugStringConvertible {
        case valid(URL)
        case insecureHTTP
        case invalid

        var description: String {
            switch self {
            case .valid: return "valid"
            case .insecureHTTP: return "insecureHTTP"
            case .invalid: return "invalid"
            }
        }
        var debugDescription: String { description }
    }

    /// Map application errors at the boundary without passing HTTP bodies or input text.
    enum Failure: CustomStringConvertible, CustomDebugStringConvertible {
        case insecureAddress
        case invalidAddress
        case timeout
        case http(status: Int)
        case network(Error)
        case unknown

        var description: String {
            switch self {
            case .insecureAddress: return "insecureAddress"
            case .invalidAddress: return "invalidAddress"
            case .timeout: return "timeout"
            case .http: return "http"
            case .network: return "network"
            case .unknown: return "unknown"
            }
        }
        var debugDescription: String { description }
    }

    static func message(for failure: Failure) -> String {
        switch failure {
        case .insecureAddress:
            return "模型地址使用 HTTP。请配置受信任证书的 HTTPS 服务地址。"
        case .invalidAddress:
            return "模型地址无效。请输入不含凭据、查询参数或片段的 HTTPS 服务地址。"
        case .timeout:
            return "连接超时。请检查网络、服务地址和服务状态后重试。"
        case .http(let status):
            return httpMessage(status)
        case .network(let error):
            return networkMessage(error)
        case .unknown:
            return "测试失败。请检查模型配置和服务状态后重试。"
        }
    }

    /// Returns the chat-completions endpoint. Never silently upgrades HTTP to HTTPS.
    static func validateAddress(_ input: String) -> AddressResult {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix("/") { text.removeLast() }
        guard var components = URLComponents(string: text),
              let scheme = components.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil else { return .invalid }
        guard scheme == "https" else { return .insecureHTTP }
        var path = components.percentEncodedPath
        if path.lowercased().hasSuffix("/chat/completions") {
            path.removeLast("/chat/completions".count)
        }
        if path.lowercased().hasSuffix("/v1") { path.removeLast(3) }
        while path.hasSuffix("/") { path.removeLast() }
        components.percentEncodedPath = path + "/v1/chat/completions"
        guard let endpoint = components.url else { return .invalid }
        return .valid(endpoint)
    }

    /// HTTP bodies and arbitrary error descriptions are deliberately not included.
    static func httpMessage(_ status: Int) -> String {
        switch status {
        case 401: return "服务拒绝认证（401）。请检查已保存的凭据和服务配置。"
        case 403: return "服务拒绝访问（403）。请检查该凭据是否获准访问此模型。"
        case 429: return "服务返回限流（429）。请稍后重试并检查服务额度。"
        default: return "服务返回 HTTP 错误（\(status)）。请检查地址、模型和服务状态。"
        }
    }

    static func networkMessage(_ error: Error) -> String {
        let ns = error as NSError
        guard ns.domain == NSURLErrorDomain else { return "连接失败，请检查服务状态后重试。" }
        switch ns.code {
        case -1022: return "iOS 阻止了不安全连接。请配置受信任证书的 HTTPS 服务地址。"
        case -1200, -1201, -1202, -1203, -1204, -1205, -1206:
            return "安全连接或证书验证失败。请检查 HTTPS 证书、域名和服务的 TLS 配置。"
        case -1003, -1006: return "无法解析服务域名。请检查服务地址与 DNS 连接。"
        case -1004: return "无法连接服务。请检查服务是否运行，以及设备能否访问该地址和端口。"
        case -1005: return "连接中断。原文已保留，请确认网络稳定后重试。"
        case -1009: return "设备当前无法连接网络。请检查网络和访问服务所需的连接。"
        case -1001: return "连接超时。请检查网络、服务地址和服务状态后重试。"
        case -999: return "测试已取消。"
        default: return "连接失败（网络错误 \(ns.code)）。请检查网络、服务地址和服务状态。"
        }
    }
}
