import Testing
@testable import KodaCore

private let sample = """
User-agent: *
Disallow: /private/
Disallow: /tmp
Allow: /private/public-thing
Crawl-delay: 2

User-agent: ScreamingKoda
Disallow: /nope/

Sitemap: https://example.com/sitemap.xml
"""

@Test func allowsUnlistedPaths() {
    let r = RobotsRules.parse(sample)
    #expect(r.isAllowed(path: "/", userAgent: "SomeBot"))
    #expect(r.isAllowed(path: "/about", userAgent: "SomeBot"))
}

@Test func disallowsMatchingPrefix() {
    let r = RobotsRules.parse(sample)
    #expect(!r.isAllowed(path: "/private/secret", userAgent: "SomeBot"))
    #expect(!r.isAllowed(path: "/tmp/x", userAgent: "SomeBot"))
}

@Test func longestMatchWins() {
    let r = RobotsRules.parse(sample)
    #expect(r.isAllowed(path: "/private/public-thing", userAgent: "SomeBot"))
}

@Test func exactUserAgentGroupOverridesWildcard() {
    let r = RobotsRules.parse(sample)
    #expect(!r.isAllowed(path: "/nope/x", userAgent: "ScreamingKoda"))
    // Our own group has no /private rule, so the wildcard group does not apply to us.
    #expect(r.isAllowed(path: "/private/secret", userAgent: "ScreamingKoda"))
}

@Test func userAgentMatchIsCaseInsensitive() {
    let r = RobotsRules.parse(sample)
    #expect(!r.isAllowed(path: "/nope/x", userAgent: "screamingkoda"))
}

@Test func parsesCrawlDelay() {
    let r = RobotsRules.parse(sample)
    #expect(r.crawlDelay(userAgent: "SomeBot") == 2)
    #expect(r.crawlDelay(userAgent: "ScreamingKoda") == nil)
}

@Test func parsesSitemaps() {
    #expect(RobotsRules.parse(sample).sitemaps == ["https://example.com/sitemap.xml"])
}

@Test func emptyDisallowMeansAllowAll() {
    let r = RobotsRules.parse("User-agent: *\nDisallow:")
    #expect(r.isAllowed(path: "/anything", userAgent: "Bot"))
}

@Test func disallowSlashBlocksEverything() {
    let r = RobotsRules.parse("User-agent: *\nDisallow: /")
    #expect(!r.isAllowed(path: "/", userAgent: "Bot"))
    #expect(!r.isAllowed(path: "/a/b", userAgent: "Bot"))
}

@Test func supportsWildcardAndAnchor() {
    let r = RobotsRules.parse("User-agent: *\nDisallow: /*.pdf$")
    #expect(!r.isAllowed(path: "/docs/file.pdf", userAgent: "Bot"))
    #expect(r.isAllowed(path: "/docs/file.pdf.html", userAgent: "Bot"))
}

@Test func ignoresCommentsAndBlankLines() {
    let r = RobotsRules.parse("# comment\n\nUser-agent: *\n  Disallow: /x  # trailing\n")
    #expect(!r.isAllowed(path: "/x", userAgent: "Bot"))
}

@Test func allowAllIsPermissive() {
    #expect(RobotsRules.allowAll.isAllowed(path: "/anything", userAgent: "Bot"))
}
