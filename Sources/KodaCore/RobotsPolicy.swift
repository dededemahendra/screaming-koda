import Foundation

public struct RobotsRules: Sendable {
    struct Rule: Sendable {
        let pattern: String
        let isAllow: Bool
    }

    struct Group: Sendable {
        var rules: [Rule] = []
        var crawlDelay: Double?
    }

    var groups: [String: Group]
    public var sitemaps: [String]

    public static let allowAll = RobotsRules(groups: [:], sitemaps: [])

    public static func parse(_ text: String) -> RobotsRules {
        var groups: [String: Group] = [:]
        var currentAgents: [String] = []
        var sitemaps: [String] = []
        var lastLineWasAgent = false

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = String(rawLine)
            if let hash = line.firstIndex(of: "#") { line = String(line[line.startIndex..<hash]) }
            line = line.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, let colon = line.firstIndex(of: ":") else { continue }

            let field = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)

            switch field {
            case "user-agent":
                if !lastLineWasAgent { currentAgents = [] }
                currentAgents.append(value.lowercased())
                groups[value.lowercased()] = groups[value.lowercased()] ?? Group()
                lastLineWasAgent = true
            case "disallow", "allow":
                lastLineWasAgent = false
                guard !currentAgents.isEmpty, !value.isEmpty else { continue }
                for agent in currentAgents {
                    groups[agent, default: Group()].rules.append(Rule(pattern: value, isAllow: field == "allow"))
                }
            case "crawl-delay":
                lastLineWasAgent = false
                guard let delay = Double(value) else { continue }
                for agent in currentAgents {
                    groups[agent, default: Group()].crawlDelay = delay
                }
            case "sitemap":
                sitemaps.append(value)
            default:
                break
            }
        }
        return RobotsRules(groups: groups, sitemaps: sitemaps)
    }

    /// The group for this agent: an exact match if present, otherwise the longest
    /// non-wildcard group name that is a substring of the agent string (ties broken
    /// lexicographically for determinism — dictionary iteration order is not stable),
    /// otherwise the wildcard group.
    func group(for userAgent: String) -> Group? {
        let lower = userAgent.lowercased()
        if let exact = groups[lower] { return exact }
        var bestName: String?
        for name in groups.keys where name != "*" && lower.contains(name) {
            if let current = bestName {
                if name.count > current.count || (name.count == current.count && name < current) {
                    bestName = name
                }
            } else {
                bestName = name
            }
        }
        if let bestName { return groups[bestName] }
        return groups["*"]
    }

    /// `path` is the path *and query*: robots.txt rules are matched against both,
    /// and `Disallow: /*?sort=` is an ordinary rule that matching the path alone
    /// would silently ignore. Pass `NormalizedURL.pathWithQuery`.
    public func isAllowed(path: String, userAgent: String) -> Bool {
        guard let group = group(for: userAgent) else { return true }
        var best: (length: Int, isAllow: Bool)?
        for rule in group.rules where Self.matches(pattern: rule.pattern, path: path) {
            let length = rule.pattern.count
            if best == nil || length > best!.length || (length == best!.length && rule.isAllow) {
                best = (length, rule.isAllow)
            }
        }
        return best?.isAllow ?? true
    }

    public func crawlDelay(userAgent: String) -> Double? {
        group(for: userAgent)?.crawlDelay
    }

    /// robots.txt globbing: `*` matches any run of characters, `$` anchors the end.
    ///
    /// Non-final segments are matched leftmost, which is safe: consuming as little of the
    /// path as possible only ever leaves *more* room for the segments that follow, so a
    /// leftmost match never forecloses a later one. The final segment of a `$`-anchored
    /// pattern is different — it must land exactly at the end of the path, so it is matched
    /// against the path's suffix instead of via leftmost search, avoiding the false negative
    /// where an earlier occurrence of that literal leaves no way to reach the end.
    static func matches(pattern: String, path: String) -> Bool {
        let anchored = pattern.hasSuffix("$")
        let body = anchored ? String(pattern.dropLast()) : pattern
        let segments = body.components(separatedBy: "*")

        var index = path.startIndex
        for (offset, segment) in segments.enumerated() {
            let isFirst = offset == 0
            let isLast = offset == segments.count - 1

            if isLast && anchored {
                if segment.isEmpty { return true } // trailing "*$" (or bare "$") matches any remainder
                guard path.hasSuffix(segment) else { return false }
                let suffixStart = path.index(path.endIndex, offsetBy: -segment.count)
                if suffixStart < index { return false }
                if isFirst && suffixStart != path.startIndex { return false }
                return true
            }

            if segment.isEmpty { continue }
            guard let found = path.range(of: segment, range: index..<path.endIndex) else { return false }
            if isFirst && found.lowerBound != path.startIndex { return false }
            index = found.upperBound
        }
        return true
    }
}
