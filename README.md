# Screaming Koda

A headless SEO site crawler in Swift. It fetches a site, records what it finds in
a SQLite database, and prints a summary. No UI, no Xcode required.

This repository is milestone M1: the crawler engine and a CLI. The reporting app
shell comes later.

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
koda crawl <url> [--db <path>] [--workers <n>] [--limit <n>] [--max-depth <n>] [--ignore-robots] [--resume]
```

```bash
koda crawl https://example.com/
```

Writes `example.com.koda` to the working directory and prints a summary: URLs
discovered and crawled, responses by status class, and counts for missing titles,
duplicate titles, missing meta descriptions, missing H1s and images missing alt
text.

| Option | Default | Meaning |
| --- | --- | --- |
| `--db` | `<host>.koda` | Database path |
| `--workers` | 5 | Concurrent fetches |
| `--limit` | 500000 | Stop after this many URLs |
| `--max-depth` | unlimited | Maximum link depth from the seed |
| `--ignore-robots` | off | Ignore robots.txt. Only for sites you control |
| `--resume` | off | Continue an existing database instead of starting over |

Without `--resume` an existing database at the target path is replaced.

## Behaviour

Politeness settings are defaults, not options. The crawler respects robots.txt
and `Crawl-delay`, identifies as `ScreamingKoda/0.1`, times out at 20 seconds,
and does not follow internal `nofollow` links or crawl subdomains. External links
are recorded but not fetched in M1.

Redirects are never followed automatically. Each hop is stored as its own row so
chains can be reconstructed, and a chain longer than `maxRedirects` (10) is
recorded and abandoned rather than walked forever.

A bad page never kills a crawl. Transport failures are stored as rows with
`status = 0` and an `error_kind`.

The frontier lives in SQLite rather than memory, which is what makes a crawl
resumable and keeps memory flat on large sites.

## The database

A `.koda` file is an ordinary SQLite database. Query it with anything.

```bash
sqlite3 example.com.koda "SELECT u.url, r.status FROM urls u JOIN responses r ON r.url_id = u.id"
```

| Table | Holds |
| --- | --- |
| `crawl_meta` | Seed URL, timestamps, the config the crawl ran with |
| `urls` | Every URL seen, with depth, internal flag, frontier state, redirect hops |
| `responses` | Status, timing, content type, optional gzipped body |
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
  implementation plan.
