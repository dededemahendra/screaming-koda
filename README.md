# Screaming Koda

A headless SEO site crawler in Swift. It fetches a site, records what it finds in
a SQLite database, and reports on it. No UI, no Xcode required.

There are two ways to use it: a CLI, and a macOS app that crawls and browses
results live.

## Requirements

- macOS 14 or later
- Swift 6.0 toolchain (Command Line Tools is enough)
- `/usr/bin/python3` for the end-to-end tests only (present by default on macOS)

## Build

```bash
swift build -c release      # the koda CLI
./Scripts/build-app.sh      # build/ScreamingKoda.app
```

SwiftPM only produces a bare executable. The script wraps it in a bundle,
without which a SwiftUI app gets no Dock icon, no menu bar and cannot be brought
to the front.

## The app

`ScreamingKoda.app` crawls and browses in one window: a toolbar with the seed
URL, Start/Stop and crawl settings, a sidebar of reports with live counts, a
results table, and an inspector showing the selected URL's details, inlinks,
outlinks, images and hreflang alternates.

Results can be browsed while the crawl is still running. Stop leaves the
frontier intact, so Start becomes Resume. Opening a `.koda` file (double-click,
`open -a ScreamingKoda site.koda`, or Open Recent) browses a crawl without
crawling, including one the CLI produced — and a crawl that was never finished
opens as stopped, so Resume is offered rather than a partial site presented as
the whole of it.

Everything the CLI exposes is in the settings sheet: depth and URL limits,
include and exclude regexes, subdomains, robots.txt, workers, per-host limits,
timeout, user agent, and what to collect. Settings persist between launches.
Resuming replays the config the crawl started with rather than what the form
currently says, because the frontier was already filtered by those rules.

| Doing | How |
| --- | --- |
| Sort | Click a column header |
| Filter | The filter box, or Cmd-F |
| Copy rows | Select and Cmd-C, or right-click. Tab-separated, so it pastes into cells |
| Open a URL | Double-click a row, or right-click |
| Export this report | Cmd-Option-E. Keeps the sort and filter on screen |
| Export a workbook | Cmd-E. One `.xlsx`, one tab per report with findings |
| Export CSVs | Cmd-Shift-E. One file per report |

Sorting and filtering re-query rather than sorting in memory, so they cost the
same on a half-million-row crawl as on a small one.

The live counts are read off the main thread, and the next read waits at least
as long as the last one took. A crawl of a thousand pages refreshes twice a
second; one large enough that a pass costs more than that refreshes as often as
it can afford to, rather than queueing work it will never finish.

## Usage

```bash
koda crawl https://example.com/     # crawl a site and print what is wrong with it
koda report                         # list the reports that found something
koda report titles-duplicate        # look at one
koda export                         # write every report with findings to CSV
koda export --format xlsx           # or as one spreadsheet, a tab per report
koda summary                        # reprint a stored crawl without re-running it
```

A crawl writes `example.com.koda` to the working directory and prints a summary
followed by a findings list. `koda summary` says whether the crawl it is reading
ran to the end, because every count in it is a floor rather than a total if it
did not. `report`, `export` and `summary` default to the only
`.koda` file in the working directory, so `--db` is only needed when there are
several.

### koda crawl

| Option | Default | Meaning |
| --- | --- | --- |
| `--db` | `<host>.koda` | Database path |
| `--workers` | 5 | Concurrent fetches |
| `--limit` | 500000 | Stop after this many URLs |
| `--max-depth` | unlimited | Maximum link depth from the seed |
| `--include` | none | Only crawl URLs matching this regex. Repeatable |
| `--exclude` | none | Never crawl URLs matching this regex. Repeatable, wins over `--include` |
| `--subdomains` | off | Also crawl subdomains of the seed host |
| `--max-per-host` | 5 | Maximum concurrent requests to any one host |
| `--timeout` | 20 | Request timeout in seconds |
| `--user-agent` | `ScreamingKoda/0.1` | How to identify |
| `--follow-nofollow` | off | Follow internal `rel=nofollow` links |
| `--skip-external` | off | Do not status-check external links |
| `--skip-images` | off | Do not status-check images |
| `--no-bodies` | off | Do not store page bodies |
| `--ignore-robots` | off | Ignore robots.txt. Only for sites you control |
| `--resume` | off | Continue an existing database instead of starting over |

Without `--resume` an existing database at the target path is replaced — but
only if it is a crawl. `--db` is one typo away from an ordinary file, so a path
holding anything else is refused and left alone, by `crawl` and by the read-only
commands alike.

### koda report

`koda report` with no argument lists every report that found something, with its
id and count. `koda report <id>` prints one as a table; add `--csv` for CSV,
`--limit` to change how many rows are shown, or `--all` when listing to include
reports with no findings.

### koda export

`--format csv` (the default) writes a directory with one file per report.
`--format xlsx` writes one workbook whose first tab is an overview of the crawl
and whose remaining tabs are the reports that found something. `--out` sets the
directory or the file; without it you get `koda-reports/` or
`koda-reports.xlsx`.

The workbook is written directly rather than through a library: an `.xlsx` is a
zip of XML parts, and `ZIPArchive` plus `XLSXWriter` are smaller than the
dependency would be. Exporting the same crawl twice produces byte-identical
files.

CSV is written a chunk at a time straight to the file, so exporting costs the
same memory whether the report has fifty rows or half a million. The workbook
does not: a zip entry needs its own length before it can be written, so the
whole thing is assembled in memory. Exporting a 20,000 URL crawl peaks at about
90 MB that way against 25 MB for CSV, and the gap grows with the crawl. On a very
large crawl, export CSV — which is also the format a spreadsheet will still open
past a million rows.

## Reports

Issues are queries, not rows. There is no findings table: each report is a SQL
query over the crawl, so changing a rule takes effect on an existing database
immediately and adding one is a new entry in `ReportCatalogue.all`.

| Group | Covers |
| --- | --- |
| Internal | All internal URLs, duplicate content |
| External | Outbound URLs with their status |
| Response Codes | 2xx to 5xx, transport errors, redirect chains, redirect loops, broken links |
| Titles | Missing, duplicate, too long, too short, multiple, same as H1 |
| Meta Description | Missing, duplicate, too long, too short, multiple |
| Headings | Missing or duplicate or multiple H1, long H1, missing H2 |
| Images | Missing alt, long alt, over 100KB, broken |
| Canonicals | Missing, self-referencing, canonicalised, multiple, to a non-200 |
| Directives | noindex, nofollow, noarchive, X-Robots-Tag conflicts |
| Hreflang | Missing return link, non-200 target, missing x-default |
| Page Depth | Distribution, deeper than 3, single inlink |

Page Depth counts pages, not URLs. Images, broken links, redirect targets and
external URLs all sit at some depth, and on a real site they outnumber the
pages, so those rules join `page_facts` — which only exists for HTML that was
actually parsed — and require a 200.

Reports are either inventory or issues. "4 internal URLs" is inventory and is not
reported as a finding, because mixing the two teaches people to ignore findings.

Duplicate content is exact-match on a SHA-256 of the page's visible text, with
script, style and noscript stripped and whitespace collapsed. Near-duplicate
detection is out of scope.

## Behaviour

Politeness settings are defaults, not options. The crawler respects robots.txt
and `Crawl-delay`, identifies as `ScreamingKoda/0.1`, times out at 20 seconds,
and does not follow internal `nofollow` links or crawl subdomains unless asked.
`nofollow` means the attribute on a link and the directive on a page — as a
`meta name=robots` tag or an `X-Robots-Tag` header, including the `none`
shorthand. `--follow-nofollow` governs all of them. `noindex` is about indexing,
not crawling, and is only reported.

Only markup is read. Anything else — a PDF, an archive, a video — is recorded
from its headers and its body is never downloaded, and markup itself stops at
8 MB. A crawler that buffers whatever a site links to is one large file away
from running out of memory.

Relative URLs resolve against `<base href>` when a page declares one.

A seed URL without a scheme gets one: `koda crawl example.com` crawls
`https://example.com/`, and a loopback host gets `http`, because nothing serves
TLS on a bare `localhost:3000`. Links inside a page never get this treatment —
there, `example.com` is a relative path, and guessing otherwise would invent
URLs that are not on the site.

Pages are decoded with the encoding they declare, in the order the HTML standard
gives: a byte order mark, then the `Content-Type` charset, then a `<meta charset>`
in the first 4 KB, then a guess. A page labelled `iso-8859-1` is read as
windows-1252, as browsers do, because pages labelled Latin-1 are full of smart
quotes that Latin-1 has no room for. An unlabelled page is UTF-8 if its bytes are
valid UTF-8 and windows-1252 otherwise — guessing the other way turns "é" into
"Ã©" without ever failing. Assuming UTF-8 throughout would put replacement
characters in every title, description and content hash on a legacy site, and
report a problem the site does not have.

External links and images are status-checked with HEAD after the internal crawl
finishes, so a slow third-party host can never starve the crawl of the site you
asked about. HEAD falls back to GET when a server answers 405 or 501. Neither is
ever parsed. Image sizes come from `Content-Length`. This is a phase of its own
in the UI and on the CLI, because it drains no frontier and a progress display
that only knows about crawling shows it as a stall.

Redirects are never followed automatically. Each hop is stored as its own row so
chains can be reconstructed, and a chain longer than `maxRedirects` (10) is
recorded and abandoned rather than walked forever. Redirect targets keep the
depth of the URL that redirected, so a chain cannot consume a `--max-depth`
budget meant for real links.

A bad page never kills a crawl. Transport failures are stored as rows with
`status = 0` and an `error_kind`, and show up under Response Codes.

The frontier lives in SQLite rather than memory, which is what makes a crawl
resumable and keeps memory flat on large sites. Page bodies stop being retained
once a crawl passes 50,000 URLs.

## The database

A `.koda` file is an ordinary SQLite database. Query it with anything.

`links` is the largest table by an order of magnitude — roughly 40 rows a page —
and most reports read it, so the crawl keeps SQLite's query statistics current
rather than leaving them to the end. Without them the planner assumes a join over
every link on the site costs the same as one over a handful of responses, which
on a five thousand page crawl made one report sixty times slower than it needed
to be. Counting a page's inlinks is answered from an index that carries the
internal flag, so it never has to visit the table at all.

`urls.state` is 0 queued, 1 in-flight, 2 done, 3 skipped, 4 claimed for a status
check. The last two are separate on purpose: a skipped URL is an external link
or an image, and recovering a crashed status check has to put it back to skipped
rather than hand it to the frontier, or the next run would crawl third-party
sites.

```bash
sqlite3 example.com.koda "SELECT u.url, r.status FROM urls u JOIN responses r ON r.url_id = u.id"
```

| Table | Holds |
| --- | --- |
| `crawl_meta` | Seed URL, timestamps, the config the crawl ran with |
| `urls` | Every URL seen, with depth, internal flag, frontier state, redirect hops |
| `responses` | Status, timing, content type, size, optional gzipped body |
| `page_facts` | Title, meta description, headings, canonical, robots, word count |
| `links` | Link graph, with anchor text, `rel` and document position |
| `images` | Image references and alt text |
| `hreflang` | Language alternates |

## Tests

```bash
swift test
```

Most tests stub the network. `EndToEndTests` runs the real HTTP client against
`python3 -m http.server` serving a fixture site, on a kernel-assigned port so the
tests can run in parallel. `XLSXTests` reads its own output back with
`/usr/bin/unzip` rather than trusting the writer that produced it.

Tests that prove concurrency assert on ordering, not on elapsed time. A test
that compares a 5ms sleep against a 300ms one fails on correct code, because
macOS coalesces short timers hard enough under the test runner that the ratio
does not survive.

## Layout

| Path | Imports | Holds |
| --- | --- | --- |
| `Sources/KodaCore` | Foundation, GRDB, SwiftSoup | Crawling, storage, reports, export |
| `Sources/KodaUI` | KodaCore, Observation | Observable models for the app |
| `Sources/KodaApp` | KodaUI, SwiftUI, AppKit | Views |
| `Sources/koda` | KodaCore, ArgumentParser | The CLI |

`KodaCore` and `KodaUI` never import AppKit or SwiftUI. That keeps the crawler
headless and keeps the models testable, because there is no UI test harness
under Command Line Tools. `Scripts/check-layering.sh` enforces it.

The results table is `NSTableView` behind `NSViewRepresentable`, fed by an LRU
cache of row windows over paged SQL. SwiftUI's `Table` wants the whole
collection, and never holding the whole row set is the point.

`docs/superpowers/specs` and `docs/superpowers/plans` hold the design and the
milestone plans.
