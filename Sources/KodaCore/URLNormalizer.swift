import CryptoKit
import Foundation

public struct NormalizedURL: Hashable, Sendable {
    public let absoluteString: String
    public let host: String
    public let path: String
    public let sha256: Data

    init(absoluteString: String, host: String, path: String) {
        self.absoluteString = absoluteString
        self.host = host
        self.path = path
        self.sha256 = Data(SHA256.hash(data: Data(absoluteString.utf8)))
    }
}

public enum URLNormalizer {
    /// Returns nil for anything that is not a crawlable http(s) URL.
    public static func normalize(_ raw: String, relativeTo base: NormalizedURL?) -> NormalizedURL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let resolved: URL?
        if let base, let baseURL = URL(string: base.absoluteString) {
            resolved = URL(string: trimmed, relativeTo: baseURL)?.absoluteURL
        } else {
            resolved = URL(string: trimmed)
        }
        guard let url = resolved,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: true)
        else { return nil }

        guard let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return nil
        }
        guard let rawHost = components.host?.lowercased(), !rawHost.isEmpty else { return nil }

        components.scheme = scheme
        components.host = rawHost
        components.fragment = nil
        components.user = nil
        components.password = nil

        if (scheme == "http" && components.port == 80) || (scheme == "https" && components.port == 443) {
            components.port = nil
        }
        if components.path.isEmpty {
            components.path = "/"
        }
        // Preserve an empty-but-present query ("?") as absent; keep parameter order otherwise.
        if components.query?.isEmpty == true {
            components.query = nil
        }

        guard let finalURL = components.url else { return nil }
        return NormalizedURL(
            absoluteString: finalURL.absoluteString,
            host: rawHost,
            path: components.path
        )
    }
}
