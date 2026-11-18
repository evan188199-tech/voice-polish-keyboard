import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

@main
struct Checks {
    static func main() {
        let expected = URL(string: "https://example.invalid/v1/chat/completions")!
        for address in ["https://example.invalid", "https://example.invalid/v1/", "https://example.invalid/v1/chat/completions"] {
            precondition(ModelConnectionDiagnostics.validateAddress(address) == .valid(expected))
        }
        for (input, output) in [
            ("https://example.invalid/api/paas/v4", "https://example.invalid/api/paas/v4/chat/completions"),
            ("https://example.invalid/custom/chat/completions/", "https://example.invalid/custom/chat/completions"),
            ("https://example.invalid/proxy", "https://example.invalid/proxy/v1/chat/completions")
        ] {
            precondition(ModelConnectionDiagnostics.validateAddress(input) == .valid(URL(string: output)!))
        }
        precondition(ModelConnectionDiagnostics.validateAddress("http://example.invalid") == .insecureHTTP)
        for address in ["", "ftp://example.invalid", "https://user:secret@example.invalid", "https://example.invalid/?token=secret", "https://example.invalid/#fragment"] {
            precondition(ModelConnectionDiagnostics.validateAddress(address) == .invalid)
        }
        for code in [-1022, -1202, -1009, -1001, -999] {
            let message = ModelConnectionDiagnostics.networkMessage(NSError(domain: NSURLErrorDomain, code: code))
            precondition(!message.isEmpty)
        }
        precondition(ModelConnectionDiagnostics.networkMessage(NSError(domain: NSURLErrorDomain, code: -1022)).contains("HTTPS"))
        for code in [401, 403, 429] { precondition(ModelConnectionDiagnostics.httpMessage(code).contains("\(code)")) }
        precondition(!ModelConnectionDiagnostics.networkMessage(NSError(domain: "secret", code: 1)).contains("secret"))
        precondition(ModelConnectionDiagnostics.message(for: .insecureAddress).contains("HTTPS"))
        precondition(ModelConnectionDiagnostics.message(for: .timeout).contains("超时"))
        precondition(ModelConnectionDiagnostics.message(for: .http(status: 401)).contains("401"))
        let simulatedError = NSError(domain: NSURLErrorDomain, code: -1022,
                                     userInfo: [NSLocalizedDescriptionKey: "secret-token and private text"])
        let diagnostic = ModelConnectionDiagnostics.message(for: .network(simulatedError))
        precondition(diagnostic.contains("HTTPS"))
        precondition(!diagnostic.contains("secret-token") && !diagnostic.contains("private text"))
        precondition(!ModelConnectionDiagnostics.message(for: .unknown).contains("secret-token"))
        // All user-facing messages and diagnostic descriptions must be safe even
        // if an underlying transport error contains an address, response or token.
        let secrets = ["fictional-token-7f3", "fictional-response-9ab", "fictional-private-path"]
        let errorDetails = secrets.joined(separator: " ")
        let leakingError = NSError(domain: NSURLErrorDomain, code: -1022,
                                   userInfo: [NSLocalizedDescriptionKey: errorDetails,
                                              NSURLErrorFailingURLStringErrorKey: "https://example.invalid/fictional-private-path"])
        let failures: [ModelConnectionDiagnostics.Failure] = [
            .insecureAddress, .invalidAddress, .timeout, .http(status: 401),
            .http(status: 403), .http(status: 429), .http(status: 500),
            .network(leakingError), .network(NSError(domain: errorDetails, code: -1,
                                                    userInfo: [NSLocalizedDescriptionKey: errorDetails])), .unknown
        ]
        for failure in failures {
            for output in [ModelConnectionDiagnostics.message(for: failure), String(describing: failure), String(reflecting: failure)] {
                for secret in secrets { precondition(!output.contains(secret)) }
            }
        }
        let privateURL = URL(string: "https://example.invalid/fictional-private-path")!
        let address = ModelConnectionDiagnostics.AddressResult.valid(privateURL)
        for output in [String(describing: address), String(reflecting: address)] {
            for secret in secrets { precondition(!output.contains(secret)) }
        }
        let urlTimeout = ModelConnectionDiagnostics.message(for: .network(URLError(.timedOut)))
        precondition(urlTimeout == ModelConnectionDiagnostics.message(for: .timeout))
        print("Model connection diagnostics: offline fixtures passed")
    }
}
