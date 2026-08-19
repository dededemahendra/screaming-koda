import Foundation

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

    public enum PreparationOutcome: Equatable {
        /// No database existed for this host; a fresh path was handed back.
        case created
        /// A database for this host already existed and was deleted to make
        /// way for the new crawl.
        case replacedExisting
    }

    /// Ensures the crawls directory exists and decides what happens to an
    /// existing database for `host`.
    ///
    /// Mirrors the CLI's already-reviewed choice: resuming an existing crawl
    /// isn't supported yet, so re-crawling the same host replaces whatever
    /// was there rather than accumulating same-named files forever (see the
    /// comment on `Crawl.run` in `Sources/koda/Koda.swift`). The CLI can only
    /// announce that on stderr; the GUI surfaces it through
    /// `CrawlController.notice`, which already exists for exactly this kind
    /// of "something the user should know just happened" message.
    public static func prepare(
        forHost host: String,
        fileManager: FileManager = .default,
        appSupport: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    ) throws -> (path: String, outcome: PreparationOutcome) {
        let directory = crawlsDirectory(appSupport: appSupport)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let fileURL = path(forHost: host, in: directory)
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return (fileURL.path, .created)
        }
        // `Store` opens its databases in WAL mode, which grows `-wal` and `-shm` sidecar
        // files alongside the main one. Deleting only the main file and leaving those
        // behind is not a clean replace: a fresh `DatabaseQueue` opened at the same path
        // can find a stale `-shm` (a memory-mapped index into a `-wal` that no longer
        // matches the new main file) and fail with a SQLite disk I/O error trying to read
        // `sqlite_master` — this was caught by a test that re-crawls the same host twice
        // in one process, which is exactly what a user editing the seed field and
        // re-clicking Start does. Removing all three together, in this order, guarantees
        // the next connection starts from nothing rather than from a mismatched leftover.
        for suffix in ["", "-wal", "-shm"] {
            let sidecar = URL(fileURLWithPath: fileURL.path + suffix)
            if fileManager.fileExists(atPath: sidecar.path) {
                try fileManager.removeItem(at: sidecar)
            }
        }
        return (fileURL.path, .replacedExisting)
    }
}
