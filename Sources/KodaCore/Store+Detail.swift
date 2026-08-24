import Foundation
import GRDB

/// Everything the inspector shows about one URL.
public struct URLDetail: Sendable, Hashable {
    public let id: Int64
    public let url: String
    public let depth: Int
    public let isInternal: Bool
    public let status: Int?
    public let errorKind: String?
    public let contentType: String?
    public let contentLength: Int?
    public let responseTimeMs: Int?
    public let redirectTarget: String?
    public let title: String?
    public let metaDescription: String?
    public let h1: String?
    public let h1Count: Int?
    public let h2Count: Int?
    public let canonical: String?
    public let metaRobots: String?
    public let xRobotsTag: String?
    public let lang: String?
    public let wordCount: Int?
}

public struct LinkRow: Sendable, Hashable {
    public let url: String
    public let anchor: String?
    public let rel: String?
    public let isInternal: Bool
    public let status: Int?
}

public struct ImageRow: Sendable, Hashable {
    public let url: String
    public let alt: String?
    public let status: Int?
    public let bytes: Int?
}

public struct HreflangRow: Sendable, Hashable {
    public let lang: String
    public let url: String
    public let status: Int?
}

extension Store {
    /// Looks a URL up by its exact text, which is how a table selection maps back
    /// to a row: the table renders URLs, not ids.
    public func urlID(for url: String) throws -> Int64? {
        guard let normalized = URLNormalizer.normalize(url, relativeTo: nil) else { return nil }
        return try dbQueue.read { db in
            try Int64.fetchOne(db, sql: "SELECT id FROM urls WHERE url_hash = ?", arguments: [normalized.sha256])
        }
    }

    public func urlDetail(id: Int64) throws -> URLDetail? {
        try dbQueue.read { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT u.id, u.url, u.depth, u.is_internal,
                       r.status, r.error_kind, r.content_type, r.content_length, r.response_time_ms,
                       t.url AS redirect_target,
                       f.title, f.meta_description, f.h1, f.h1_count, f.h2_count,
                       c.url AS canonical, f.meta_robots, f.x_robots_tag, f.lang, f.word_count
                FROM urls u
                LEFT JOIN responses r ON r.url_id = u.id
                LEFT JOIN urls t ON t.id = r.redirect_target_id
                LEFT JOIN page_facts f ON f.url_id = u.id
                LEFT JOIN urls c ON c.id = f.canonical_id
                WHERE u.id = ?
                """, arguments: [id])
            else { return nil }

            return URLDetail(
                id: row["id"], url: row["url"], depth: row["depth"],
                isInternal: (row["is_internal"] as Int) == 1,
                status: row["status"], errorKind: row["error_kind"],
                contentType: row["content_type"], contentLength: row["content_length"],
                responseTimeMs: row["response_time_ms"], redirectTarget: row["redirect_target"],
                title: row["title"], metaDescription: row["meta_description"],
                h1: row["h1"], h1Count: row["h1_count"], h2Count: row["h2_count"],
                canonical: row["canonical"], metaRobots: row["meta_robots"],
                xRobotsTag: row["x_robots_tag"], lang: row["lang"], wordCount: row["word_count"]
            )
        }
    }

    /// Pages linking to this URL. Capped because a site-wide footer link can have
    /// tens of thousands of sources and the inspector only shows a pane of them.
    public func inlinks(to id: Int64, limit: Int = 500) throws -> [LinkRow] {
        try dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT src.url AS url, l.anchor_text, l.rel, l.is_internal, r.status
                FROM links l
                JOIN urls src ON src.id = l.from_url_id
                LEFT JOIN responses r ON r.url_id = src.id
                WHERE l.to_url_id = ?
                ORDER BY src.url
                LIMIT ?
                """, arguments: [id, limit]).map(Self.linkRow)
        }
    }

    public func outlinks(from id: Int64, limit: Int = 1000) throws -> [LinkRow] {
        try dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT dst.url AS url, l.anchor_text, l.rel, l.is_internal, r.status
                FROM links l
                JOIN urls dst ON dst.id = l.to_url_id
                LEFT JOIN responses r ON r.url_id = dst.id
                WHERE l.from_url_id = ?
                ORDER BY l.position
                LIMIT ?
                """, arguments: [id, limit]).map(Self.linkRow)
        }
    }

    private static func linkRow(_ row: Row) -> LinkRow {
        LinkRow(url: row["url"], anchor: row["anchor_text"], rel: row["rel"],
                isInternal: (row["is_internal"] as Int? ?? 0) == 1, status: row["status"])
    }

    public func images(on id: Int64) throws -> [ImageRow] {
        try dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT src.url AS url, i.alt, r.status, r.content_length
                FROM images i
                JOIN urls src ON src.id = i.src_url_id
                LEFT JOIN responses r ON r.url_id = src.id
                WHERE i.url_id = ?
                ORDER BY src.url
                """, arguments: [id]).map {
                    ImageRow(url: $0["url"], alt: $0["alt"], status: $0["status"], bytes: $0["content_length"])
                }
        }
    }

    public func hreflang(on id: Int64) throws -> [HreflangRow] {
        try dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT h.lang, dst.url AS url, r.status
                FROM hreflang h
                JOIN urls dst ON dst.id = h.href_url_id
                LEFT JOIN responses r ON r.url_id = dst.id
                WHERE h.url_id = ?
                ORDER BY h.lang
                """, arguments: [id]).map {
                    HreflangRow(lang: $0["lang"], url: $0["url"], status: $0["status"])
                }
        }
    }
}
