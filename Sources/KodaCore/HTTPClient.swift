import Foundation

public struct HTTPResponse: Sendable {
    public let status: Int
    public let headers: [String: String]
    public let body: Data?
    public let elapsedMs: Int

    public init(status: Int, headers: [String: String], body: Data?, elapsedMs: Int) {
        self.status = status
        self.headers = headers
        self.body = body
        self.elapsedMs = elapsedMs
    }

    /// Header lookup is case-insensitive, as HTTP requires.
    public func header(_ name: String) -> String? {
        let lower = name.lowercased()
        return headers.first { $0.key.lowercased() == lower }?.value
    }

    public var contentType: String? {
        header("content-type")?.split(separator: ";").first.map { String($0).trimmingCharacters(in: .whitespaces) }
    }

    /// Size from the Content-Length header. A HEAD response has no body, so this
    /// is the only way to learn an asset's size without downloading it.
    public var declaredContentLength: Int? { header("content-length").flatMap { Int($0) } }

    public var isRedirect: Bool { (300...399).contains(status) }
    public var location: String? { header("location") }
}

public enum FetchOutcome: Sendable {
    case response(HTTPResponse)
    case failure(kind: String)
}

public protocol HTTPClient: Sendable {
    func fetch(url: String, method: String, userAgent: String, timeout: TimeInterval) async -> FetchOutcome
}

/// Maps `URLError.Code` to a stable, human-readable name.
///
/// Interpolating a `URLError.Code` directly (e.g. `"\(error.code)"`) renders the
/// raw numeric `rawValue` on this toolchain rather than a symbolic case name, which
/// would make the `responses.error_kind` column full of bare integers instead of
/// readable strings. This switch covers the codes a crawler is realistically going
/// to see and falls back to a descriptive-but-stable name for everything else.
func urlErrorKindName(_ code: URLError.Code) -> String {
    switch code {
    case .cannotFindHost: return "cannotFindHost"
    case .cannotConnectToHost: return "cannotConnectToHost"
    case .timedOut: return "timedOut"
    case .networkConnectionLost: return "networkConnectionLost"
    case .notConnectedToInternet: return "notConnectedToInternet"
    case .dnsLookupFailed: return "dnsLookupFailed"
    case .badURL: return "badURL"
    case .unsupportedURL: return "unsupportedURL"
    case .secureConnectionFailed: return "secureConnectionFailed"
    case .serverCertificateUntrusted: return "serverCertificateUntrusted"
    case .serverCertificateHasBadDate: return "serverCertificateHasBadDate"
    case .serverCertificateHasUnknownRoot: return "serverCertificateHasUnknownRoot"
    case .serverCertificateNotYetValid: return "serverCertificateNotYetValid"
    case .clientCertificateRejected: return "clientCertificateRejected"
    case .cancelled: return "cancelled"
    case .cannotParseResponse: return "cannotParseResponse"
    case .redirectToNonExistentLocation: return "redirectToNonExistentLocation"
    case .badServerResponse: return "badServerResponse"
    case .zeroByteResource: return "zeroByteResource"
    case .userAuthenticationRequired: return "userAuthenticationRequired"
    case .httpTooManyRedirects: return "httpTooManyRedirects"
    case .resourceUnavailable: return "resourceUnavailable"
    case .internationalRoamingOff: return "internationalRoamingOff"
    case .callIsActive: return "callIsActive"
    case .dataNotAllowed: return "dataNotAllowed"
    default: return "urlError(\(code.rawValue))"
    }
}

/// Refuses every redirect so each hop is recorded separately.
private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

public struct URLSessionHTTPClient: HTTPClient {
    private let session: URLSession
    private static let delegate = NoRedirectDelegate()

    public init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.httpShouldSetCookies = false
            config.requestCachePolicy = .reloadIgnoringLocalCacheData
            self.session = URLSession(configuration: config, delegate: Self.delegate, delegateQueue: nil)
        }
    }

    public func fetch(url: String, method: String, userAgent: String, timeout: TimeInterval) async -> FetchOutcome {
        guard let parsed = URL(string: url), parsed.host != nil else {
            return .failure(kind: "invalidURL")
        }
        var request = URLRequest(url: parsed, timeoutInterval: timeout)
        request.httpMethod = method
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml,*/*;q=0.8", forHTTPHeaderField: "Accept")

        let start = DispatchTime.now().uptimeNanoseconds
        do {
            let (data, response) = try await session.data(for: request, delegate: Self.delegate)
            let elapsed = Int((DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
            guard let http = response as? HTTPURLResponse else {
                return .failure(kind: "nonHTTPResponse")
            }
            var headers: [String: String] = [:]
            for (key, value) in http.allHeaderFields {
                if let k = key as? String, let v = value as? String { headers[k] = v }
            }
            return .response(HTTPResponse(status: http.statusCode, headers: headers, body: data, elapsedMs: elapsed))
        } catch let error as URLError {
            return .failure(kind: urlErrorKindName(error.code))
        } catch {
            return .failure(kind: "\(type(of: error))")
        }
    }
}
