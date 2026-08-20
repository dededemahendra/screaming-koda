# Screaming Koda M3a — Complete Data and a Real Table

**Date:** 2026-08-20
**Status:** Approved for implementation planning
**Scope:** M3a — external and image status checking, per-host concurrency, sortable columns, resume-versus-overwrite
**Parent spec:** `docs/superpowers/specs/2026-08-17-screaming-koda-design.md`
**Predecessors:** M1 (headless crawler + CLI), M2 (app shell) — both complete, 179 tests passing

## Purpose

M3 was going to be "reports". It split, because writing fifty report filters
against data that is about to change shape is wasted work.

M3a makes the data complete and the table usable. M3b then builds the eleven
report tabs, the sidebar, and the detail inspector on top — each filter written
once, against data that already exists and a table that already sorts.

Everything in M3a is a debt already promised and deferred at least once.

## Why these four things, together

| Item | Promised in | Deferred |
|---|---|---|
| External link status checking | M1 defaults table: "External links: Status checked" | Twice — M1, M2 |
| Image size (HEAD requests) | M1 defaults table: "Internal images: Fetched with HEAD" | Twice — M1, M2 |
| Per-host concurrency cap | M1 defaults table: "Max concurrent per host: 5" | Twice, honestly — nothing fetched off-host until now |
| Resume versus overwrite | M1 plan | Twice — M1→M2, M2→M3 |
| Sortable columns | M2 non-goals | Once |

Two of M3b's eleven tabs are unbuildable without the first two. The External tab
promises "status only" for URLs that are never fetched, and the Images tab
promises "over 100KB" for images whose size is never recorded. Doing the crawler
work first is what stops M3b shipping two tabs that look broken.

The per-host cap was deferred for a good reason that has now expired: until this
milestone, every request in a crawl went to the seed host, so the global worker
count already was the per-host count. Once we fetch external URLs, it stops being
true, and a page with 200 links to one domain becomes 200 rapid requests to a
stranger's server.

## Decisions

| Decision | Choice | Reason |
|---|---|---|
| External/image fetching | Reuse the frontier via a `check_only` flag | Inherits batching, politeness, pause/cancel, and hop limits rather than duplicating them |
| Method | HEAD, falling back to GET | Some servers reject HEAD; a fallback is the difference between a status and a phantom error |
| robots.txt for external hosts | Not fetched | Fetching robots for thousands of third-party domains is itself the impolite act |
| Random access to sorted rows | Materialised ordered id list | `NSTableView` asks for arbitrary rows; keyset paging cannot answer that without counting |
| Existing database on Start | Sheet: Resume / Replace / Cancel | Replacing a crawl silently is data loss; the notice M2 added explains it afterwards, too late |

### The keyset reversal, recorded deliberately

The M2 spec and the M3 brainstorm both said sortable columns would need keyset
pagination. That was wrong, and the correction is load-bearing enough to write
down.

Keyset pagination answers "the next page after this key". `NSTableView` asks for
row 40,000 directly, and keyset cannot satisfy that without walking to it —
which is the very cost it exists to avoid.

Materialising an ordered list of row ids answers it exactly: row *N* is
`ids[N]`, fetched by primary key. At the 500,000-URL target the array is about
4MB. This is less code than keyset, genuinely O(1) per row, and it removes M2's
documented `OFFSET` limitation outright rather than mitigating it.

## Architecture

### Crawler: status-check URLs

**Migration v3** adds one column:

```sql
ALTER TABLE urls ADD COLUMN check_only INTEGER NOT NULL DEFAULT 0;
```

`Store.upsertURL` gains a `checkOnly: Bool = false` parameter. The call sites in
`Store+Write.swift` change:

- External link targets: `enqueue: true, checkOnly: true` (were `enqueue: false`)
- Image sources: `enqueue: true, checkOnly: true` (were `enqueue: false`)

`FrontierItem` carries `checkOnly`. `CrawlEngine.process` branches on it:

- **check-only:** `HEAD` the URL. Retry once with `GET` **only** on 405 (Method
  Not Allowed) or 501 (Not Implemented) — the two codes that actually mean "this
  server does not do HEAD". Retrying every 4xx would double our traffic on
  ordinary 404s, which is precisely the impoliteness this milestone is trying to
  avoid. Record status,
  `content_type`, and `content_length`. No parsing, no link discovery, no body
  retention. Produces a `CrawlResult` with `facts: nil`.
- **full:** unchanged.

`content_length` comes from the `Content-Length` header for a HEAD, since there
is no body to measure. When the header is absent, the column stays null and the
"images over 100KB" filter simply will not match that row — a missing size must
never be treated as zero.

Two config flags, both defaulting true:

```swift
public var checkExternalLinks: Bool = true
public var checkImages: Bool = true
```

When false, the corresponding URLs are recorded as before (`enqueue: false`), so
turning the feature off restores exactly M2's behaviour.

**Depth:** a check-only URL inherits the standard child depth
(`parentDepth + 1`), like any other discovered link. It is never crawled deeper,
so depth only affects reporting.

**The URL cap** counts check-only URLs, because they are work the crawler
performs. A site with 50,000 outbound links genuinely is a larger crawl.

### Per-host concurrency

`Store.claimNext` becomes host-diverse so no single host dominates a batch:

```sql
SELECT id, url, depth, check_only FROM (
  SELECT id, url, depth, check_only, host,
         ROW_NUMBER() OVER (PARTITION BY host ORDER BY depth, id) AS rn
  FROM urls WHERE state = 0
)
WHERE rn <= :maxPerHost
ORDER BY depth, id
LIMIT :limit
```

`CrawlConfig.maxPerHost` (already present, defaulting to 5, unused since M1)
becomes the parameter. Window functions require SQLite 3.25+, which macOS 14
comfortably exceeds.

This bounds concurrent requests per host *within a batch*. Because batches are
processed to completion before the next is claimed, it bounds them across the
crawl too.

### The visibility filter must change, or images flood the table

`Store.visibleURLsFilter` currently excludes a URL that is only an image source,
and keeps it when it is *also* a fetched page or a link target:

```sql
u.id NOT IN (
  SELECT src_url_id FROM images
  WHERE src_url_id NOT IN (SELECT url_id FROM responses)
    AND src_url_id NOT IN (SELECT to_url_id FROM links)
)
```

That `NOT IN (SELECT url_id FROM responses)` clause exists so a URL that is both
a real page and an image source stays visible. But once M3a fetches images,
**every** image gains a `responses` row, so the clause always fails, nothing is
ever excluded, and every `.png` and `.jpg` appears in the main URL table mixed in
with pages.

So the filter changes to key on links alone:

```sql
u.id NOT IN (
  SELECT src_url_id FROM images
  WHERE src_url_id NOT IN (SELECT to_url_id FROM links)
)
```

A URL that is both an image source and a linked page is still visible, via the
links clause. A pure image is excluded whether or not it has been fetched.
`Store.summary()` shares the same constant, so its counts stay consistent for
free — and the existing test asserting `RowStore.count == summary().totalURLs`
keeps them pinned together.

This is a change to shipped, tested behaviour, so it needs its own test: an
image that has been fetched must still be absent from the table, and a URL that
is both a page and an image source must still be present.

### Table: RowIndex and sorting

**`RowIndex`** (new, in `KodaUI`) owns the ordered id list for the current sort:

```swift
@MainActor public final class RowIndex {
    public enum SortColumn: String, CaseIterable, Sendable {
        case address, status, title, depth
    }
    public private(set) var ids: [Int64]
    public var count: Int { ids.count }
    public func id(at index: Int) -> Int64?
    public func rebuild(sort: SortColumn, ascending: Bool)
    public func appendNewIds()   // fast path for the default sort during a live crawl
}
```

`RowStore` keeps its LRU page cache but fetches by id rather than by offset:
`SELECT … FROM urls u … WHERE u.id IN (…)`, then reorders the returned rows to
match the requested id order, since `IN` does not preserve it.

**One place applies the visibility filter.** `RowIndex` applies
`Store.visibleURLsFilter` when it builds the id list; `RowStore` then fetches
purely by id and does **not** re-apply it. Applying it twice would be the same
two-definitions-drifting-apart trap that produced M1's `urlCounts().total`
versus `summary().totalURLs` divergence.

**Live-crawl behaviour.** Under the default sort (id ascending) new rows only
ever append, so the 2 Hz tick calls `appendNewIds()` — a query for ids greater
than the current maximum — rather than rebuilding. Under any other sort a
rebuild is required, and rebuilds are throttled to at most once every 2 seconds
so a large crawl does not spend its time re-sorting.

**Sorting in the table.** `NSTableColumn.sortDescriptorPrototype` on each column;
`tableView(_:sortDescriptorsDidChange:)` maps to a `SortColumn` and direction,
rebuilds the index, and reloads. Sorting is always by SQL, never in Swift.

Null handling is explicit: rows with no status or no title sort **last in both
directions**, not merely in ascending order. A table sorted by status should
open on real statuses whichever way the arrow points; burying the blanks only
when ascending would make descending useless.

**Indexes.** `idx_responses_status` and `idx_facts_title` already exist.
Migration v3 adds `CREATE INDEX idx_urls_depth ON urls(depth)` and
`CREATE INDEX idx_urls_url ON urls(url)` to support the other two sorts.

### Resume versus overwrite

`CrawlDatabaseLocation.prepare` currently deletes an existing database and
returns a notice. It splits: a `existingDatabase(forHost:) -> URL?` query, and
explicit `resume` / `replace` actions.

`CrawlController` gains a pending-decision state. When `start()` finds an
existing database, it does not begin — it publishes a `pendingExistingCrawl`
value describing what was found (host, path, when it was last modified, how many
URLs it holds), and waits.

`ContentView` presents a sheet with three choices:

- **Resume** — open the existing store and run the engine against its frontier.
  An interrupted crawl continues where it stopped. A *finished* crawl has an
  empty frontier, so this opens and displays it without re-fetching, which is
  also how "look at my last crawl" works without a separate flow.
- **Replace** — delete the database and its `-wal`/`-shm` sidecars (the M2 fix
  applies here unchanged) and crawl fresh.
- **Cancel** — do nothing; the controller returns to idle.

## Error handling

| Situation | Behaviour |
|---|---|
| HEAD rejected by server | Retry once with GET; record whatever that returns |
| HEAD succeeds but no `Content-Length` | Status recorded, size left null; size filters do not match it |
| External host unreachable | Recorded as a transport error like any other, status 0 with an error kind |
| Sort rebuild fails | Keep the previous ordering and leave the table usable rather than emptying it |
| Existing database unreadable on Resume | Surface the reason and offer Replace; never silently delete it |
| Migration v3 on an M2-era database | Applies cleanly; existing rows default to `check_only = 0` |

## Testing

| Layer | Approach |
|---|---|
| Check-only fetching | Stub client asserting HEAD is used, that a 405 triggers exactly one GET retry, and that no links are discovered from a check-only response |
| Content-Length | Present, absent, and non-numeric header cases |
| Per-host diversity | Seed a frontier with many URLs on one host plus a few on others; assert no claimed batch exceeds `maxPerHost` for any host |
| Config flags off | `checkExternalLinks = false` restores M2 behaviour exactly — external URLs recorded, never fetched |
| `RowIndex` | Ordering per column and direction; null-sorts-last; `id(at:)` correctness at boundaries |
| Live append | `appendNewIds()` picks up rows added mid-crawl without a full rebuild |
| `RowStore` by id | Rows come back in the requested order despite `IN` not preserving it |
| Resume | An interrupted crawl continues; a finished crawl opens without re-fetching; Replace deletes sidecars |
| Sheet | UI, verified by running the app |

## Milestone completion criteria

- `swift test` passes: all M1 and M2 tests plus the new ones
- A crawl records statuses for external links and sizes for images
- No batch exceeds `maxPerHost` requests to a single host
- Clicking a column header sorts the table, including on a 10,000-row crawl
- Scrolling to the end of a 100,000-row crawl is as fast as scrolling to the start
- Starting a crawl over an existing database offers Resume / Replace / Cancel
- Resuming an interrupted crawl continues it; resuming a finished one displays it
- `KodaCore` still imports neither AppKit nor SwiftUI

## Non-goals

Deferred to M3b: the eleven report tabs, sidebar filters and issue counts, and
the detail inspector.

Deferred to M4 or later: CSV and Excel export, a crawl configuration UI, a
browsable list of past crawls beyond the Resume sheet, crawl comparison, and
resizable or reorderable columns.

Still open from M1, and not addressed here: the write-batching cadence (the
spec promises 100 rows or 500ms; the implementation flushes per fetch batch),
and character-encoding detection (bodies are always decoded as UTF-8).
