# Screaming Koda M2 — App Shell Design

**Date:** 2026-08-19
**Status:** Approved for implementation planning
**Scope:** M2 — window, toolbar, paged table, live crawl progress
**Parent spec:** `docs/superpowers/specs/2026-08-17-screaming-koda-design.md`

## Purpose

Turn the headless crawler into a macOS application: a window that starts a
crawl, shows rows arriving live, and lets you stop it.

M1 delivered `KodaCore` and the `koda` CLI — 121 tests, a real crawl writing a
correct SQLite database. M2 puts a native window on it. Report tabs, sidebar
filters, and the detail inspector are M3.

## Decisions

Settled during brainstorming; not open questions.

| Decision | Choice | Reason |
|---|---|---|
| Crawl control | Real pause/resume plus cancel, in the engine | The spec's toolbar promises it, and the batch loop over a durable frontier makes it cheap and safe |
| App bundle | Minimal `.app` bundling pulled into M2 | A SwiftUI binary without a bundle has no dock icon and does not activate properly; you cannot evaluate M2's output without one |
| Window contents | One table of all crawled URLs | Enough to prove the paged table holds up under a live crawl; tabs and inspector are M3 |
| Target layout | Four targets — logic in a library, not the executable | Executables cannot be unit-tested here |
| Paging | `LIMIT`/`OFFSET` with a page cache | Simple and adequate now; keyset pagination waits until sortable columns need it |

## Problem this milestone must solve first

`CrawlEngine.run(onProgress:)` runs to completion and returns. There is no
pause, no resume, and no cancel. A user who starts a crawl against the wrong
URL, or one hammering a site, has no recourse but to quit the application.

M2 is therefore not purely a UI milestone: it adds a control surface to
`KodaCore` before any window can be useful.

## Architecture

### Target layout

`KodaCore` must stay headless — it is the constraint that keeps the crawler
testable and reusable. UI logic must be testable, and SwiftPM executables
cannot host unit tests. Hence four targets:

| Target | Kind | Contents | Tests |
|---|---|---|---|
| `KodaCore` | library | Unchanged crawler. Never imports AppKit or SwiftUI | `KodaCoreTests` |
| `KodaUI` | library | `CrawlController`, `RowStore`, SwiftUI views, table wrapper | `KodaUITests` |
| `koda` | executable | The CLI, unchanged | — |
| `KodaApp` | executable | `@main` shell only, roughly 20 lines | — |

### KodaCore additions

```swift
public enum CrawlState: Sendable, Equatable {
    case idle
    case running
    case paused
    case finished
    case cancelled
    case failed(String)
}
```

`CrawlEngine` gains:

```swift
public func pause()
public func resume()
public func cancel()
public var state: CrawlState { get }
```

`CrawlEngine` is an actor, so reading `state` is `await`ed. `CrawlController`
mirrors it into main-actor observable state rather than awaiting it during view
updates.

**Pause semantics.** Checked between batches, never mid-batch. The in-flight
batch always completes and its results are written — fetched work is never
discarded, because discarding it would mean re-fetching pages from a site we
are trying to be polite to. Implemented as a poll on the actor at 100ms
intervals rather than a stored continuation: marginally less elegant,
substantially harder to deadlock.

**Cancel semantics.** Stops claiming new batches, lets the current batch finish
and be written, then calls `resetInFlight()` so claimed-but-unproduced rows
return to the queue. `crawl_meta.finished_at` stays null, so the database
honestly records an incomplete crawl. Restarting against the same database
continues where it stopped.

**Pause is not persisted.** Quitting while paused ends the crawl; relaunching
offers the same resume path any interrupted crawl gets.

**On resume, and being straight about it.** The M1 plan deferred
"frontier resume in the CLI" to M2, on the grounds that a user-facing
resume-versus-overwrite choice belongs with the app shell. M2 delivers the
*capability* — cancel leaves a resumable database, and restarting against it
continues where it stopped — but not the *choice*. Presenting "resume or start
fresh?" needs somewhere to present it: a crawl-open flow, a recent-crawls list,
or a configuration sheet, none of which exist until M3 brings the wider UI.
Building that surface now would mean building a chunk of M3 to host one
question. So it moves to M3, and this is the second time it has moved — worth
knowing when M3 is scoped.

### CrawlSession split

The app must construct an engine, hold a reference for control, and run it in a
task it owns. `start(...)` cannot do that because it runs to completion.

```swift
public static func prepare(
    dbPath: String?, config: CrawlConfig, client: HTTPClient, parser: PageParser
) async throws -> (engine: CrawlEngine, store: Store, robotsOutcome: RobotsFetchOutcome)
```

`start(...)` becomes a thin wrapper over `prepare` plus `run`. Its signature
does not change, so the CLI and all 121 existing tests are untouched.

### KodaUI

**`CrawlController`** — `@MainActor @Observable`. Owns the config being edited,
the engine, the store, the current `CrawlState`, and the latest `CrawlProgress`.
Exposes `start()`, `pause()`, `resume()`, `stop()`. The engine's `@Sendable`
progress callback hops to the main actor to update observable state.

It also surfaces what the CLI already surfaces: a `.unreachable` robots outcome,
and a crawl that fetched nothing because robots disallowed it. A zero-row window
must never be silently ambiguous — the same reasoning that put those warnings in
the CLI applies with more force to a GUI, where there is no scrollback.

**`RowStore`** — the paged data source behind the table.

```swift
@MainActor final class RowStore {
    struct Row: Identifiable { let id: Int64; let address: String; let status: Int?; let title: String?; let depth: Int }
    var count: Int { get }
    func row(at index: Int) -> Row?
    func refresh()          // re-reads count, invalidates cache
    func invalidate()
}
```

Backed by `ORDER BY u.id LIMIT ? OFFSET ?` over a page cache: 200 rows per page,
20 pages resident, LRU eviction — roughly 4,000 rows in memory regardless of
crawl size.

Reads are synchronous. `NSTableView` requests cell values during draw, and an
indexed page fetch is sub-millisecond. An async data source would mean returning
placeholder rows and reloading, which is more machinery for no gain at this
scale.

**Known limitation, accepted deliberately.** `OFFSET` is O(offset) in SQLite, so
scrolling near row 490,000 of 500,000 will feel sluggish. Keyset pagination
fixes it but requires a stable sort key, which only becomes meaningful when M3
adds sortable columns. Revisit it there.

### The window

**Toolbar** — URL field, Start / Pause / Resume / Stop, and live counts
(crawled, queued, URLs per second). Button availability follows `CrawlState`:
Start when idle or finished, Pause when running, Resume when paused, Stop
whenever a crawl is active.

**Table** — `NSTableView` inside an `NSScrollView`, wrapped in
`NSViewRepresentable`. View-based, with an `NSTableCellView` per column.
Columns: Address, Status, Title, Depth. Sorting is M3.

The coordinator implements `NSTableViewDataSource` and `NSTableViewDelegate`,
reading through `RowStore`.

**Live updates.** While a crawl runs, a 2 Hz timer refreshes the row count,
invalidates the cache, and reloads. Selection and scroll position are preserved
across reloads — a table that jumps to the top twice a second is unusable.
WAL mode means these reads never block the writer.

### Bundling

`Scripts/make-app.sh` builds release, assembles `Koda.app/Contents/MacOS` plus
an `Info.plist` (`CFBundleName` Koda, `LSMinimumSystemVersion` 14.0,
`NSHighResolutionCapable`), and ad-hoc signs it (`codesign -s -`) so it launches
locally without Gatekeeper complaints.

No notarisation, no Developer ID — this remains a personal tool per the parent
spec.

## Error handling

| Situation | Behaviour |
|---|---|
| Crawl throws mid-run | State becomes `.failed(reason)`; the message is shown in the window, not swallowed. Rows already written stay visible |
| robots.txt unreachable | Surfaced in the window, as the CLI does — a restricted crawl must explain itself |
| robots.txt disallows everything | Same: an empty table says why it is empty |
| Invalid seed URL | Start is refused with an inline message; no empty database is created |
| Database read fails during draw | The affected rows render empty rather than crashing the app; the error is logged once, not per row |

## Testing

| Layer | Approach |
|---|---|
| Engine control | Stub client counts calls: assert no growth while paused, growth resumes after `resume()`, `cancel()` stops claiming and leaves `finished_at` null while already-fetched results are still written |
| `CrawlSession.prepare` | Returns a runnable engine; `start` still behaves identically (existing tests are the regression net) |
| `RowStore` | Seeded database: correct rows at page boundaries, correct behaviour under LRU eviction, `count` refresh picks up rows added mid-crawl |
| `CrawlController` | State transitions across start/pause/resume/stop; robots warnings surface |
| Views | No automated coverage. Verified by running the app and screenshotting it |

## Milestone completion criteria

- `swift test` passes: all existing `KodaCoreTests` plus new `KodaUITests`
- `Scripts/make-app.sh` produces a `Koda.app` that launches by double-click
- A crawl of a real multi-page site shows rows arriving live in the table
- Pause visibly halts row growth; resume continues; stop ends the crawl
- Scrolling a crawl of at least 10,000 rows stays responsive
- `KodaCore` still imports neither AppKit nor SwiftUI

## Non-goals

Deferred to M3 or later, and out of scope here: report tabs, sidebar filters and
issue counts, the detail inspector, sortable and resizable columns, CSV/Excel
export, crawl configuration UI, the resume-versus-overwrite choice in the UI (see
"On resume" above — deferred a second time, deliberately), and crawl comparison.
