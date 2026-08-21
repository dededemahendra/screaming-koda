# M4 Finishing — Design

**Milestone:** M4, the last of v1, per
`docs/superpowers/specs/2026-08-17-screaming-koda-design.md`.

**Goal:** Get the results out of the app, let the crawl be configured, and stop
lying about character encodings.

## What M4 still owes

The master spec lists M4 as "CSV and Excel export, crawl configuration UI,
resume, `.app` bundling script". Two of those are already done and are not
reopened:

| Item | Status |
|---|---|
| Resume | Done in M3a — Resume / Replace / Cancel on an existing crawl |
| `.app` bundling | Done in M2 — `Scripts/make-app.sh` |
| CSV and Excel export | This milestone |
| Crawl configuration UI | This milestone |

Plus one thing the master spec did not list, which M3b's design flagged as an
inherited limitation and which is now the most user-visible defect left:

**Character encoding.** Bodies are decoded as UTF-8 unconditionally
(`CrawlEngine.swift:261`). A page in Windows-1252 or Shift_JIS produces a
mangled title, and that mangled title then appears in the Titles report as a
genuine finding. That is a report inventing a problem that does not exist,
which is worse than missing one. It is fixed here.

## Decisions

**Export what is on screen.** The export writes the selected report, the
selected filter, the selected sort, and that report's columns. Exporting
something other than what the user is looking at is a support burden. A second
command exports every report at once, for handing a whole audit to someone.

**Both formats, one writer.** `ReportExport` produces rows once; CSV and XLSX
are two encoders over the same `[[String?]]`. Neither format gets its own query
path, so they cannot disagree about what a report contains.

**XLSX is written directly, with no dependency.** A `.xlsx` is a ZIP of XML
parts. Adding a third-party spreadsheet library for this would be a large
dependency for a small, fully-specified job. M4 ships a minimal store-only ZIP
writer (~120 lines, CRC32 plus local headers, central directory, EOCD) and the
five OOXML parts a workbook needs. Cells use `inlineStr`, which avoids the
shared-strings table entirely at the cost of a larger file — the right trade
for an export nobody diffs.

The risk is producing a file Excel rejects. It is checked by unzipping the
output in the test and asserting the parts parse, not by eyeballing it.

**CSV is UTF-8 with a BOM.** Without one, Excel on both platforms reads a UTF-8
CSV as the system codepage and mangles every non-ASCII character — which, in a
tool whose job is finding mangled text, would be a poor joke. The BOM is what
Screaming Frog writes too. Anything reading the file programmatically has to
tolerate it; that is the lesser cost.

**Configuration is per-crawl, and persisted.** The sheet edits a `CrawlConfig`
held by the controller and used by the next `start()`. It is saved to
`UserDefaults` as JSON so it survives relaunch, because a user who turned off
image checking for a big site means it.

Seed URL stays in the toolbar, not the sheet — it is the one field that changes
every time.

**Encoding detection order.** Content-Type `charset` first, since the server is
authoritative; then a `<meta charset>` or `<meta http-equiv>` sniffed from the
first 2KB of the body; then UTF-8; then Windows-1252, which cannot fail and is
what a mislabelled Western European page almost always is.

The last step matters: decoding must always produce *something*. A page whose
declared encoding is wrong should crawl with slightly wrong characters, not
vanish from the report. That is the same "a crawl never dies from a bad page"
rule the rest of the crawler follows.

## Architecture

| Unit | Target | Responsibility |
|---|---|---|
| `ReportExport` | `KodaCore` | Report → header row plus data rows |
| `CSVWriter` | `KodaCore` | RFC 4180 encoding |
| `XLSXWriter` | `KodaCore` | OOXML parts |
| `ZIPArchive` | `KodaCore` | Minimal store-only ZIP |
| `TextDecoding` | `KodaCore` | Bytes plus headers → String |
| `ConfigSheet` | `KodaUI` | The settings form |
| `ExportCommands` | `KodaUI` | Save panel, progress, errors |

`KodaCore` still imports neither AppKit nor SwiftUI. `NSSavePanel` lives in
`KodaUI`; `KodaCore` only ever writes to a `URL` it is handed.

## Export shape

```swift
public struct ReportExport: Sendable {
    public let name: String        // the report's name, and the sheet/file name
    public let headers: [String]
    public let rows: [[String?]]
}

extension Store {
    public func export(report: Report, filter: ReportFilter,
                       sortBy: ReportColumn?, ascending: Bool,
                       limit: Int?) throws -> ReportExport
}
```

Exports read through `ids` and `rows`, the same two functions the table uses, so
an exported file and the table it came from cannot disagree.

A whole-crawl export at 500,000 URLs across eleven reports is a lot of rows.
Rows are fetched in the same 200-row pages the table uses rather than one giant
result set, and the export runs off the main actor so the window stays alive.

## Error handling

| Situation | Behaviour |
|---|---|
| Destination not writable | Reported in the window; no partial file left behind |
| Export of an empty report | Writes a file with headers and no rows, rather than nothing — "I checked and it is clean" is a result |
| Crawl running during export | Allowed. The export is a snapshot of the moment it ran and says so in the filename |
| Undecodable body | Falls back down the encoding chain; never drops the page |

## Testing

| Unit | Approach |
|---|---|
| CSV | Golden-file comparison, plus the awkward cases: commas, quotes, newlines inside a field, nil versus empty |
| XLSX | Unzip the produced bytes in the test, assert every part is present and parses, and that a known cell holds a known value |
| ZIP | Round-trip through the system `unzip`, so the check is against a real implementation rather than my own reader |
| Export content | The exported rows equal the table's rows for the same report, filter, and sort |
| Encoding | A Windows-1252 body with a charset header, one with only a meta tag, one mislabelled, and one that is genuine UTF-8 |
| Config | Round-trips through `UserDefaults`; an invalid regex is rejected before a crawl starts, not during one |

## Out of scope for v1

Everything in the master spec's non-goals, unchanged. Also: scheduled or
automated exports, exporting the inspector panes, PDF, and Google Sheets.

**The write-batching cadence stays as it is.** The master spec promises a flush
every 100 rows or 500ms; the implementation flushes once per claim batch, which
is more often. Changing it is an optimisation, and there is no measurement
saying it is needed. It is recorded as a known deviation rather than changed on
a guess.
