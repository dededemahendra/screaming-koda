# Screaming Koda

A headless SEO site crawler in Swift. It fetches a site, records what it finds in
a SQLite database, and reports on it. No UI, no Xcode required.

This repository is the headless half of the tool: the crawler, the report
catalogue, and a CLI. The desktop app shell is a later milestone.

## Requirements

- macOS 14 or later
- Swift 6.0 toolchain (Command Line Tools is enough)
- `/usr/bin/python3` for the end-to-end tests only (present by default on macOS)

## Build

```bash
swift build -c release
```

## Usage

```bash
koda crawl https://example.com/     # crawl a site and print what is wrong with it
koda report                         # list the reports that found something
koda report titles-duplicate        # look at one
koda export                         # write every report with findings to CSV
koda summary                        # reprint a finished crawl without re-running it
```

A crawl writes `example.com.koda` to the working directory and prints a summary
followed by a findings list. `report`, `export` and `summary` default to the only
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

Without `--resume` an existing database at the target path is replaced.

### koda report

`koda report` with no argument lists every report that found something, with its
id and count. `koda report <id>` prints one as a table; add `--csv` for CSV,
`--limit` to change how many rows are shown, or `--all` when listing to include
reports with no findings.

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

Reports are either inventory or issues. "4 internal URLs" is inventory and is not
reported as a finding, because mixing the two teaches people to ignore findings.

Duplicate content is exact-match on a SHA-256 of the page's visible text, with
script, style and noscript stripped and whitespace collapsed. Near-duplicate
detection is out of scope.

## Behaviour

Politeness settings are defaults, not options. The crawler respects robots.txt
and `Crawl-delay`, identifies as `ScreamingKoda/0.1`, times out at 20 seconds,
and does not follow internal `nofollow` links or crawl subdomains unless asked.

External links and images are status-checked with HEAD after the internal crawl
finishes, so a slow third-party host can never starve the crawl of the site you
asked about. HEAD falls back to GET when a server answers 405 or 501. Neither is
ever parsed. Image sizes come from `Content-Length`.

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
tests can run in parallel.

## Layout

- `Sources/KodaCore` is the library. It never imports AppKit or SwiftUI so it can
  run headless.
- `Sources/koda` is the CLI.
- `docs/superpowers/specs` and `docs/superpowers/plans` hold the design and the
  M1 implementation plan.
