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

/// Reads a response, keeping only as much of the body as is worth keeping.
///
/// A crawler follows whatever the site links to, which on a real site includes
/// PDFs, installers and video. `URLSession.data(for:)` buffers all of it before
/// returning, so one such link costs its full size in memory and in bandwidth
/// for a body that will never be parsed. Its `bytes(for:)` alternative streams,
/// but iterates one byte at a time: measured against a 64KB page it ran roughly
/// three hundred times slower than `data(for:)`, which is not a trade a crawler
/// can make.
///
/// A data delegate gets chunks and can cancel, which is what was wanted. It
/// declines the body of anything that is not markup, and stops reading markup
/// that runs past the cap rather than following it wherever it goes.
final class BodyCollector: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let limit: Int
    private let wantsBody: Bool
    private let onFinish: @Sendable (Result<(HTTPURLResponse, Data?), Error>) -> Void

    private let lock = NSLock()
    private var response: HTTPURLResponse?
    private var body = Data()
    private var stoppedEarly = false
    private var finished = false

    init(limit: Int, wantsBody: Bool,
         onFinish: @escaping @Sendable (Result<(HTTPURLResponse, Data?), Error>) -> Void) {
        self.limit = limit
        self.wantsBody = wantsBody
        self.onFinish = onFinish
    }

    /// Redirects stay unfollowed here too: a task delegate takes precedence over
    /// the session's, so leaving this out would quietly re-enable them.
    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }

    /// The completion-handler form rather than the `async` one: this runs on
    /// URLSession's delegate queue and takes a lock, which is not allowed from an
    /// asynchronous context.
    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            return
        }
        lock.lock()
        self.response = http
        lock.unlock()

        guard wantsBody, Self.isTextual(http.value(forHTTPHeaderField: "Content-Type")) else {
            complete(.success((http, nil)))
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        let overflowed = body.count + data.count >= limit
        if overflowed {
            body.append(data.prefix(max(0, limit - body.count)))
            stoppedEarly = true
        } else {
            body.append(data)
        }
        let http = response
        lock.unlock()

        // Truncated markup still parses: SwiftSoup closes what is open, and the
        // head is where everything a report cares about lives.
        if overflowed, let http {
            complete(.success((http, bodySnapshot())))
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        lock.lock()
        let http = response
        let ours = stoppedEarly
        lock.unlock()

        // A cancellation we asked for is a success; the caller's is not.
        if let error, !(ours && (error as? URLError)?.code == .cancelled) {
            complete(.failure(error))
        } else if let http {
            complete(.success((http, wantsBody ? bodySnapshot() : nil)))
        } else {
            complete(.failure(URLError(.badServerResponse)))
        }
    }

    /// What is worth reading: markup, and text generally, because robots.txt is
    /// `text/plain` and the crawl depends on it.
    ///
    /// A missing or empty Content-Type reads the body too. Unknown is not the
    /// same as binary, and a server that omits the header on its HTML is a
    /// server whose site would otherwise crawl as a single blank page.
    static func isTextual(_ contentType: String?) -> Bool {
        guard let type = contentType?.lowercased(),
              !type.trimmingCharacters(in: .whitespaces).isEmpty else { return true }
        return type.hasPrefix("text/") || type.contains("html") || type.contains("xml")
    }

    private func bodySnapshot() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return body
    }

    /// Exactly once: a cancelled task still reports completion afterwards, and
    /// resuming a continuation twice is a crash.
    private func complete(_ result: Result<(HTTPURLResponse, Data?), Error>) {
        lock.lock()
        let alreadyFinished = finished
        finished = true
        lock.unlock()
        guard !alreadyFinished else { return }
        onFinish(result)
    }
}

public struct URLSessionHTTPClient: HTTPClient {
    /// The most of one response to keep. Real HTML is orders of magnitude below
    /// this; past it a crawler has stopped reading a page and started
    /// downloading a file.
    public static let defaultMaxBodyBytes = 8 * 1024 * 1024

    private let session: URLSession
    private let maxBodyBytes: Int
    private static let delegate = NoRedirectDelegate()

    public init(session: URLSession? = nil, maxBodyBytes: Int = defaultMaxBodyBytes) {
        self.maxBodyBytes = maxBodyBytes
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
        let task = session.dataTask(with: request)
        let result: Result<(HTTPURLResponse, Data?), Error> = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                task.delegate = BodyCollector(limit: maxBodyBytes, wantsBody: method != "HEAD") {
                    continuation.resume(returning: $0)
                }
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }

        let elapsed = Int((DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
        switch result {
        case .failure(let error as URLError):
            return .failure(kind: urlErrorKindName(error.code))
        case .failure(let error):
            return .failure(kind: "\(type(of: error))")
        case .success(let (http, body)):
            var headers: [String: String] = [:]
            for (key, value) in http.allHeaderFields {
                if let k = key as? String, let v = value as? String { headers[k] = v }
            }
            return .response(HTTPResponse(status: http.statusCode, headers: headers,
                                          body: body, elapsedMs: elapsed))
        }
    }
}
