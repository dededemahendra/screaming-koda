import Foundation
import KodaCore

/// Where the double-clickable app stores a crawl's database on disk.
///
/// The CLI writes `<host>.koda` into the current directory (see
/// `Sources/koda/Koda.swift`) because a terminal invocation has a directory
/// the user chose. A GUI app has no such directory, so the parent spec
/// (`docs/superpowers/specs/2026-08-17-screaming-koda-design.md`) pins crawls
/// to `~/Library/Application Support/ScreamingKoda/Crawls/<name>.koda`
/// instead. This type mirrors the CLI's naming convention — the file is named
/// after the seed host — inside that fixed directory.
public enum CrawlDatabaseLocation {
    /// `~/Library/Application Support/ScreamingKoda/Crawls`. Takes the search
    /// root as a parameter (rather than hard-coding `FileManager.default`)
    /// purely so tests can point it at a scratch directory instead of the
    /// real one.
    public static func crawlsDirectory(
        appSupport: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    ) -> URL {
        appSupport.appendingPathComponent("ScreamingKoda", isDirectory: true)
            .appendingPathComponent("Crawls", isDirectory: true)
    }

    /// The `.koda` file for a crawl of `host`, inside `directory`.
    public static func path(forHost host: String, in directory: URL) -> URL {
        directory.appendingPathComponent("\(host).koda", isDirectory: false)
    }
}

/// What was found on disk for a host the user is about to crawl.
/// `Identifiable` so SwiftUI's `.sheet(item:)` can present it directly.
public struct ExistingCrawl: Equatable, Sendable, Identifiable {
    public let host: String
    public let path: URL
    public let modifiedAt: Date
    /// How many URLs the existing crawl holds — the size of what Replace destroys.
    public let urlCount: Int

    public var id: URL { path }
}

extension CrawlDatabaseLocation {
    /// Describes an existing crawl for this host, or nil if there is none.
    /// A database that cannot be read is reported with a count of zero rather
    /// than treated as absent — silently overwriting an unreadable file would be
    /// the same data loss this whole flow exists to prevent.
    public static func existing(forHost host: String, in directory: URL) -> ExistingCrawl? {
        let path = self.path(forHost: host, in: directory)
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }

        let attributes = try? FileManager.default.attributesOfItem(atPath: path.path)
        let modified = (attributes?[.modificationDate] as? Date) ?? Date.distantPast
        let count = (try? {
            let store = try Store(path: path.path)
            return try store.dbQueue.read { db in
                try Int.fetchOne(db, sql: "SELECT count(*) FROM urls") ?? 0
            }
        }()) ?? 0

        return ExistingCrawl(host: host, path: path, modifiedAt: modified, urlCount: count)
    }

    /// Deletes a crawl database and its write-ahead-log sidecars. Leaving a stale
    /// `-wal` behind makes the next open fail with a disk I/O error — found the
    /// hard way in M2.
    public static func replace(at path: URL) throws {
        let fm = FileManager.default
        for candidate in [path.path, path.path + "-wal", path.path + "-shm"] {
            if fm.fileExists(atPath: candidate) {
                try fm.removeItem(atPath: candidate)
            }
        }
    }
}
