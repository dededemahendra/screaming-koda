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
                lastLineWasAgent = false
                sitemaps.append(value)
            default:
                lastLineWasAgent = false
            }
        }
        return RobotsRules(groups: groups, sitemaps: sitemaps)
    }

    /// The group for this agent: an exact match if present, otherwise the wildcard group.
    func group(for userAgent: String) -> Group? {
        let lower = userAgent.lowercased()
        if let exact = groups[lower] { return exact }
        for (name, group) in groups where name != "*" && lower.contains(name) {
            return group
        }
        return groups["*"]
    }

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
    static func matches(pattern: String, path: String) -> Bool {
        let anchored = pattern.hasSuffix("$")
        let body = anchored ? String(pattern.dropLast()) : pattern
        let segments = body.components(separatedBy: "*")

        var index = path.startIndex
        for (offset, segment) in segments.enumerated() {
            if segment.isEmpty {
                if offset == segments.count - 1 && anchored { return index == path.endIndex }
                continue
            }
            guard let found = path.range(of: segment, range: index..<path.endIndex) else { return false }
            if offset == 0 && found.lowerBound != path.startIndex { return false }
            index = found.upperBound
        }
        if anchored { return index == path.endIndex }
        return true
    }
}
