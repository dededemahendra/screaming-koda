# Screaming Koda — Design

**Date:** 2026-08-17
**Status:** v1 delivered 2026-08-21 (M1–M4)
**Scope:** v1 (milestones M1–M4)

## Purpose

A native macOS SEO crawler covering the work people actually open Screaming Frog
for: crawl a site, find broken links and redirect chains, audit titles and meta
descriptions, check canonicals and directives, inspect the internal link graph,
export the results.

Free, local, no account, no licence key, no crawl limit imposed by a vendor.

This is a personal tool. It is not a Screaming Frog clone and will not reach
feature parity — see [Non-goals](#non-goals).

## Decisions

These were settled during brainstorming and are not open questions:

| Decision | Choice | Reason |
|---|---|---|
| v1 scope | Crawl + core SEO reports, static HTML | Covers ~80% of real use; every later subsystem builds on it |
| Stack | Swift + SwiftUI/AppKit | Genuinely native; lowest memory per URL; single binary, no runtime |
| Storage | SQLite (GRDB) from the first URL | Flat RAM regardless of site size; resumable; filters become SQL |
| Target scale | Up to ~500k URLs | Large enough for real sites without enterprise-scale engineering |
| Distribution | Personal, local build | No signing, notarisation, or release pipeline; all effort goes to the crawler |
| Layout | Tab bar + table + detail inspector | Familiar working model, executed natively |
| Analysis timing | Hybrid: parse during crawl, retain bodies | New report rules can be tested against existing crawls without re-fetching |

### Toolchain, verified

SwiftUI, AppKit, and `NSApplication` compile, link, and run under Command Line
Tools alone (Swift 6.3, macOS 26.5, arm64). A hand-built `.app` bundle
(`Contents/MacOS/<binary>` plus `Info.plist`) is valid and launches.

**Full Xcode is not required.** SwiftPM plus a bundling script is sufficient.

## Architecture

Two SwiftPM targets, with a hard boundary between them.

### `KodaCore` — library

Pure Swift. No UI, no AppKit. Runs headless, which makes it CLI-driveable and
fully testable before a window exists.

| Unit | Responsibility | Depends on |
|---|---|---|
| `URLNormalizer` | Canonical URL form: lowercase scheme and host, strip fragment, drop default ports, resolve relative references. Trailing slashes and query parameter order are deliberately preserved — both can be semantically significant | — |
| `RobotsPolicy` | Fetch, parse, cache robots.txt; answer "may I fetch X?"; expose crawl-delay | `Fetcher` |
| `Frontier` | The queue: dedup, depth tracking, include/exclude rules; persisted for resume | `Store`, `URLNormalizer` |
| `Fetcher` | URLSession wrapper; manual redirect handling; per-host politeness; timeouts | — |
| `Parser` | HTML → `PageFacts`. A protocol; no I/O in implementations | SwiftSoup |
| `Analyzer` | Pure functions `PageFacts → [Finding]`; one file per rule family | — |
| `Store` | SQLite schema, migrations, batched writes, report queries | GRDB |
| `CrawlEngine` | Actor wiring the above; emits progress events | all of the above |

`Analyzer` functions being pure over a plain struct is the load-bearing decision:
every report rule is unit-testable against an HTML fixture with no network, no
database, and no app.

### `KodaApp` — executable

SwiftUI + AppKit. Knows nothing of HTTP or HTML. Observes a crawl session and
renders tables.

### Dependencies

- **GRDB.swift** (MIT) — SQLite. Chosen over raw SQLite3 for migrations, typed
  rows, and WAL handling; over Core Data because reports are SQL and Core Data
  fights that.
- **SwiftSoup** (MIT) — HTML parsing with CSS selectors. CSS selector support
  sets up custom extraction in a later milestone.

`Parser` is a protocol so that if profiling shows SwiftSoup is the bottleneck,
system libxml2 can replace it without touching any other unit.

## Data model

SQLite in WAL mode. One database file per crawl:

```
~/Library/Application Support/ScreamingKoda/Crawls/<name>.koda
```

Per-file keeps crawls portable and individually deletable. Cross-crawl
comparison remains possible later via SQLite `ATTACH`, so this does not
foreclose a comparison feature.

### Schema

```sql
CREATE TABLE crawl_meta (
  id INTEGER PRIMARY KEY CHECK (id = 1),
  seed_url TEXT NOT NULL,
  started_at REAL NOT NULL,
  finished_at REAL,
  config_json TEXT NOT NULL,
  schema_version INTEGER NOT NULL
);

CREATE TABLE urls (
  id INTEGER PRIMARY KEY,
  url TEXT NOT NULL,
  url_hash BLOB NOT NULL,          -- SHA-256 of normalized URL
  host TEXT NOT NULL,
  path TEXT NOT NULL,
  depth INTEGER NOT NULL,
  is_internal INTEGER NOT NULL,
  discovered_at REAL NOT NULL,
  state INTEGER NOT NULL           -- 0 queued, 1 in-flight, 2 done, 3 skipped
);
CREATE UNIQUE INDEX idx_urls_hash ON urls(url_hash);
CREATE INDEX idx_urls_state ON urls(state, depth);

CREATE TABLE responses (
  url_id INTEGER PRIMARY KEY REFERENCES urls(id),
  status INTEGER NOT NULL,         -- 0 = transport error
  error_kind TEXT,                 -- non-null only when status = 0
  content_type TEXT,
  content_length INTEGER,
  response_time_ms INTEGER,
  redirect_target_id INTEGER REFERENCES urls(id),
  fetched_at REAL NOT NULL,
  body_gz BLOB                     -- zlib (Apple Compression framework); NULL when retention is off
);
CREATE INDEX idx_responses_status ON responses(status);

CREATE TABLE page_facts (
  url_id INTEGER PRIMARY KEY REFERENCES urls(id),
  title TEXT, title_length INTEGER, title_count INTEGER,
  meta_description TEXT, meta_description_length INTEGER, meta_description_count INTEGER,
  h1 TEXT, h1_count INTEGER, h2_count INTEGER,
  canonical_id INTEGER REFERENCES urls(id),
  meta_robots TEXT, x_robots_tag TEXT,
  lang TEXT,
  word_count INTEGER,
  content_hash BLOB                -- for duplicate-content detection
);
CREATE INDEX idx_facts_title ON page_facts(title);
CREATE INDEX idx_facts_desc ON page_facts(meta_description);
CREATE INDEX idx_facts_hash ON page_facts(content_hash);

CREATE TABLE links (
  from_url_id INTEGER NOT NULL REFERENCES urls(id),
  to_url_id INTEGER NOT NULL REFERENCES urls(id),
  anchor_text TEXT,
  rel TEXT,
  is_internal INTEGER NOT NULL,
  position INTEGER NOT NULL
);
CREATE INDEX idx_links_from ON links(from_url_id);
CREATE INDEX idx_links_to ON links(to_url_id);

CREATE TABLE images (
  url_id INTEGER NOT NULL REFERENCES urls(id),
  src_url_id INTEGER NOT NULL REFERENCES urls(id),
  alt TEXT
);
CREATE INDEX idx_images_url ON images(url_id);

CREATE TABLE hreflang (
  url_id INTEGER NOT NULL REFERENCES urls(id),
  lang TEXT NOT NULL,
  href_url_id INTEGER NOT NULL REFERENCES urls(id)
);
CREATE INDEX idx_hreflang_url ON hreflang(url_id);
```

`links` is the largest table by an order of magnitude — roughly 40 rows per
page, so a 12k-page site produces around 500k link rows. Its two indexes are
what make the inlinks and outlinks panes instant.

### Issues are queries, not rows

There is no `issues` table. Each report is a SQL query over `page_facts` and
`responses`. Changing a rule's definition takes effect immediately on every
existing crawl — no migration, no re-analysis, no stale findings.

## Crawl engine

`CrawlEngine` is an actor owning frontier state. Worker tasks pull URLs, fetch
them, and parse **off** the actor so parsing never serialises behind queue
access.

**Write batching.** Results flow through a batching writer that flushes every
100 rows or 500 ms, whichever comes first. Per-row inserts would make SQLite the
bottleneck long before the network is.

**Redirects.** URLSession's automatic following is disabled. Each hop is
recorded as its own row with `redirect_target_id` pointing to the next, so full
chains are reconstructable rather than collapsed. Chains longer than the maximum
are recorded and abandoned, not followed.

**Politeness.** Defaults, not optional settings:

| Setting | Default |
|---|---|
| Concurrent workers | 5 |
| Max concurrent per host | 2 |
| Respect robots.txt | Yes |
| Respect crawl-delay | Yes |
| User agent | `ScreamingKoda/0.1` |
| Request timeout | 20s |
| Max redirect chain | 10 hops |
| Follow internal nofollow | No |
| Crawl subdomains | No |
| External links | Status checked, not crawled or parsed |
| Internal images | Fetched with HEAD, falling back to GET if HEAD is unsupported, to record status and byte size; never parsed |
| Max depth | Unlimited |
| URL cap | 500,000 |
| Body retention | On below 50k URLs, off above |

Include and exclude rules are ordered regex lists applied to the normalized URL
after robots.txt and before enqueueing.

## Reports

Each report is a `ReportDefinition`: a name, a SQL query, and a column list.
Adding a report is a new value in an array, not new UI code.

| Tab | Filters |
|---|---|
| Internal | All internal URLs |
| External | All external URLs, status only |
| Response Codes | 2xx, 3xx, 4xx, 5xx, transport errors, redirect chains, redirect loops |
| Titles | Missing, duplicate, over 60 chars, under 30 chars, multiple, same as H1 |
| Meta Description | Missing, duplicate, over 155 chars, under 70 chars, multiple |
| Headings | Missing H1, duplicate H1, multiple H1, over 70 chars, missing H2 |
| Images | Missing alt, alt over 100 chars, over 100KB |
| Canonicals | Missing, self-referencing, canonicalised, multiple, to non-200 |
| Directives | noindex, nofollow, noarchive, X-Robots-Tag conflicts |
| Hreflang | Missing return link, non-200 target, missing x-default |
| Page Depth | Depth distribution, pages deeper than 3, pages with a single inlink |

Duplicate detection in v1 is exact-match on `content_hash`, defined as SHA-256
of the page's normalised visible text — script, style, and comment nodes
stripped, whitespace collapsed. Near-duplicate detection (minhash) is out of
scope.

**Orphan pages are not a v1 report.** In a crawl-only tool every discovered URL
has an inlink by definition, so orphans are undetectable without an external
URL source (XML sitemap, GA, GSC) — all of which are out of scope. "Pages with
a single inlink" is the closest signal v1 can honestly provide.

## The window

**Toolbar** — URL field, Start/Pause/Resume, live progress: crawled, queued,
URLs per second.

**Tab bar** — one tab per report above.

**Sidebar** — overview counts and issue filters, each a `COUNT(*)` over the same
query its tab uses.

**Table** — `NSTableView` via `NSViewRepresentable`, not SwiftUI's `Table`.
SwiftUI's table does not hold up at hundreds of thousands of rows. The data
source is backed by paged SQL (`LIMIT`/`OFFSET`) behind an LRU cache of row
windows, so the full row set is never in memory. Sorting and filtering are
`ORDER BY` and `WHERE` — re-query rather than sort in Swift.

**Detail inspector** — for the selected URL: details, inlinks, outlinks, images,
headings. Each is a small query keyed on `url_id`.

**Live browsing during a crawl.** The UI re-queries on a throttled timer at
roughly 2 Hz. WAL mode means readers never block the writer.

## Error handling

The governing rule: **a crawl never dies from a bad page.**

| Situation | Behaviour |
|---|---|
| Network failure, DNS failure, timeout | Row with `status = 0` and `error_kind`; appears in Response Codes |
| Malformed HTML | Best-effort parse; keep whatever fields were extractable |
| Non-HTML content type | Status and size recorded; not parsed |
| Redirect chain over the limit | Recorded, marked, not followed |
| Database write failure | Crawl pauses and surfaces the error; rows are never silently dropped |
| Quit mid-crawl | Frontier state is persisted; relaunch offers Resume. On resume, every URL still marked in-flight (state 1) is reset to queued, since its fetch died with the process. Re-fetching a handful of URLs is correct; losing them is not. |

## Testing

Test-driven throughout. The layering is what makes it cheap:

| Layer | Approach |
|---|---|
| Analyzers | HTML fixture in, expected findings out. Pure, no I/O. Most tests live here. |
| Fetcher | `URLProtocol` stub: redirect chains, timeouts, status codes. No network. |
| URLNormalizer, Frontier | Plain unit tests. Normalisation edge cases — session IDs, parameter loops, case — are where crawlers quietly fail. |
| Store | In-memory SQLite; schema, migration, and report-query tests. |
| Integration | Local HTTP server serving a fixture site with known structure: a redirect chain, a 404, a duplicate title, a noindex page, a canonicalised page. Assert the finished database matches. |
| Export | Golden-file CSV comparison. |

## Milestones

All four are delivered as of 2026-08-21. Each has its own design spec and
implementation plan under `docs/superpowers/`.

| Milestone | Status | Delivered |
|---|---|---|
| **M1 — headless crawler** | Done | `KodaCore` end to end: fetch, robots, frontier, parse, store, plus a CLI |
| **M2 — app shell** | Done | Window, toolbar, paged `NSTableView`, live progress, pause/resume/stop, `.app` bundling |
| **M3a — data and table** | Done | External and image status checks, per-host concurrency, sortable columns, Resume / Replace / Cancel |
| **M3b — reports** | Done | The eleven tabs and their 52 filters, sidebar issue counts, detail inspector |
| **M4 — finishing** | Done | CSV and Excel export, crawl configuration UI, character-encoding detection |

M3 was split in two once M2 landed: M3a was the crawler work the reports needed
(external link statuses, image sizes) and M3b was the reports themselves.

### Known deviations from this spec

Recorded rather than quietly fixed, because both are deliberate:

**Write batching.** This spec promises a flush every 100 rows or 500ms. The
implementation flushes once per claim batch, which is *more* often. Changing it
is an optimisation and no measurement says it is needed, so it stands.

**`DatabaseQueue`, not `DatabasePool`.** "WAL mode means readers never block the
writer" is true of a pool and not of a queue, which is a single serialised
connection. In practice writes are batched per claim batch, so a read waits at
most one transaction. Recorded in the M2 design; the stall has never been
observed.

**Duplicate detection is exact-match**, per this spec's own v1 position. Two
titles differing by a trailing space are not duplicates.

## Non-goals

Explicitly out of scope for v1. Each would need its own design:

- JavaScript rendering (headless Chromium or WKWebView)
- Google Search Console, GA4, PageSpeed Insights integrations
- Custom extraction (XPath, CSS, regex)
- Force-directed crawl visualisations
- Crawl comparison and scheduling
- Near-duplicate content detection
- Structured data validation, spell check
- Log file analysis
- Code signing, notarisation, public distribution

## Known limitations

**This will not reach Screaming Frog parity.** That product is years of paid
team effort. What M4 delivers is a genuinely useful tool covering the reports
you actually open — not a replacement for every feature.

**JavaScript-heavy sites will crawl poorly** until rendering exists. Sites that
render content client-side will show empty titles and missing links. This is
expected in v1, not a bug.
