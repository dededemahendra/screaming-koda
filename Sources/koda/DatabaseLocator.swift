import ArgumentParser
import Foundation

/// Finds the database a report or export command should open.
///
/// `koda crawl` names its output after the host, so the common case is a single
/// `.koda` file sitting in the working directory. Requiring `--db` every time
/// would be friction for no benefit, but silently picking one of several would
/// be worse than asking.
enum DatabaseLocator {
    static func resolve(explicit: String?) throws -> String {
        if let explicit {
            guard FileManager.default.fileExists(atPath: explicit) else {
                throw ValidationError("No database at \(explicit)")
            }
            return explicit
        }

        let cwd = FileManager.default.currentDirectoryPath
        let candidates = ((try? FileManager.default.contentsOfDirectory(atPath: cwd)) ?? [])
            .filter { $0.hasSuffix(".koda") }
            .sorted()

        switch candidates.count {
        case 0:
            throw ValidationError("No .koda database here. Run 'koda crawl <url>' first, or pass --db.")
        case 1:
            return cwd + "/" + candidates[0]
        default:
            throw ValidationError(
                "Several databases here (\(candidates.joined(separator: ", "))). Pass --db to choose one."
            )
        }
    }
}
