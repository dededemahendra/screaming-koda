# Screaming Koda

A Swift/SwiftUI macOS SEO crawler, built with Command Line Tools (Swift 6.0, macOS 14 floor).

## Building

```
swift build
```

## Testing

Run the full suite with:

```
swift test
```

`Store.init` sets a busy timeout on its SQLite connections. Without one,
plain `swift test` used to fail with roughly 70 spurious issues in
`CrawlControllerTests` and `ReportSelectionTests`: several tests open two
`CrawlController`s against the same `.koda` file within a single test, to
exercise resume/replace against a database a prior controller in that same
test already crawled, and the first controller's GRDB connection is released
whenever ARC gets around to deallocating it, not synchronously when the test
moves on. Under parallel test execution a second test's controller could open
that same file while an unrelated test's connection was still alive and in
the middle of being torn down, and SQLite returned `SQLite error 5: database
is locked` immediately rather than waiting. The busy timeout makes a
connection wait for the lock instead of failing on it, which is the same
coexistence WAL mode is meant to give the app's own reader against the CLI's
writer — so `--no-parallel` is no longer needed to keep the suite green.
