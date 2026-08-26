# Screaming Koda

A Swift/SwiftUI macOS SEO crawler, built with Command Line Tools (Swift 6.0, macOS 14 floor).

## Building

```
swift build
```

## Testing

Run the full suite with:

```
swift test --no-parallel
```

Plain `swift test` fails with roughly 70 spurious issues, all originating in
`CrawlControllerTests` and `ReportSelectionTests`. This is a known
test-isolation defect, not a product defect: several tests open two
`CrawlController`s against the same `.koda` file within a single test, to
exercise resume/replace against a database a prior controller in that same
test already crawled. The first controller's GRDB connection is released
whenever ARC gets around to deallocating it, not synchronously when the test
moves on — under `swift test`'s parallel test execution, a second test's
controller can open that same file while an unrelated test's connection is
still alive and in the middle of being torn down, and hits
`SQLite error 5: database is locked`. Running the suite with `--no-parallel`
removes the race by never overlapping test bodies at all.

Do not attempt to fix this by chasing the individual failures it produces —
fix the isolation instead, or run with `--no-parallel`.
