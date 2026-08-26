# M4 Finishing — Implementation Plan

**Design:** `docs/superpowers/specs/2026-08-21-m4-finishing-design.md`
**Baseline:** `c447e0f`, 326 tests passing.

## Global Constraints

Same three that have applied all project: `try await store.dbQueue.read` in
async contexts; a `public struct`'s memberwise init is internal so anything
`KodaUITests` builds needs an explicit `public init`; `KodaCore` imports no UI
framework.

**Adding a stored property to a public `KodaCore` struct needs a clean build.**
Layout changes are not always propagated by SwiftPM's incremental build, and the
symptom is not a compile error — it is `swift test` crashing with SIGSEGV or
SIGBUS somewhere unrelated. Diagnosed 2026-08-24 from the `.ips` crash report,
which named `initializeWithCopy for ExtractionRule` inside `JSONEncoder`: adding
fields to `CrawlConfig` left object files compiled against the old layout, and
`rm -rf .build` fixed it outright. Reach for the crash report before bisecting;
two hypotheses were rejected before it was consulted.

New for this milestone: **verify binary output with a real reader.** A ZIP or
XLSX checked only by the code that wrote it proves nothing. Every test on
produced bytes goes through the system `unzip` or Python's `zipfile`.

---

## Task 1: Character-encoding detection

**Files:** `Sources/KodaCore/TextDecoding.swift` (new),
`Sources/KodaCore/CrawlEngine.swift`

```swift
public enum TextDecoding {
    public static func decode(_ body: Data, contentType: String?) -> String
    static func charset(fromContentType: String?) -> String.Encoding?
    static func charset(sniffedFrom: Data) -> String.Encoding?
}
```

Order: Content-Type `charset`, then a `<meta charset>` / `<meta http-equiv>`
in the first 2KB, then UTF-8, then Windows-1252 as the never-fails floor.

Replace `String(decoding: body, as: UTF8.self)` at `CrawlEngine.swift:261`.
Leave `CrawlSession.swift:68` (robots.txt) alone — RFC 9309 says robots.txt is
UTF-8, and guessing at it would be wrong.

**Tests** (`Tests/KodaCoreTests/TextDecodingTests.swift`):
- `aCharsetHeaderIsBelieved` — Windows-1252 bytes, `text/html; charset=windows-1252`
- `aMetaCharsetIsUsedWhenTheHeaderIsSilent`
- `aMetaHttpEquivIsAlsoRead`
- `theHeaderBeatsTheMetaTag` — they disagree; the server wins
- `validUTF8DecodesAsUTF8WithNoDeclaration`
- `aMislabelledPageStillDecodesToSomething` — declared UTF-8, actually 1252;
  must not return empty or drop the page
- `anUnknownCharsetNameFallsThroughRatherThanFailing`
- `decodingIsLosslessForASCII`

**Verify:** a real crawl of a Windows-1252 fixture page yields the correct title.
Add the fixture page to `Tests/KodaCoreTests/Fixtures/site/`.

---

## Task 2: Minimal ZIP writer

**Files:** `Sources/KodaCore/ZIPArchive.swift` (new)

Store-only (method 0), no compression. Local file header, central directory,
EOCD. CRC32 by table. Fixed DOS timestamp so output is byte-deterministic and
diffable in tests.

```swift
struct ZIPArchive {
    mutating func add(path: String, data: Data)
    func finish() -> Data
}
```

**Tests** (`Tests/KodaCoreTests/ZIPArchiveTests.swift`): write the bytes to a
temp file and shell out to the system `unzip -t` and `unzip -p`. Asserting with
my own reader would only prove it is self-consistent.
- `producesAnArchiveTheSystemUnzipAccepts`
- `roundTripsFileContentsExactly`
- `handlesMultipleEntriesAndNestedPaths`
- `handlesAnEmptyFile`
- `isByteDeterministic` — same input, same bytes, twice

**Verify:** `unzip -t` returns "No errors detected".

---

## Task 3: Export rows

**Files:** `Sources/KodaCore/Store+Export.swift` (new)

`ReportExport` plus `Store.export(report:filter:sortBy:ascending:limit:)`,
reading through the same `ids`/`rows` the table uses, paged 200 at a time.

**Tests** (`Tests/KodaCoreTests/StoreExportTests.swift`):
- `exportedRowsMatchTheTablesRowsForTheSameQuery` — the important one
- `headersComeFromTheReportsColumns`
- `anEmptyReportExportsHeadersAndNoRows`
- `theSortIsHonoured`
- `pagingDoesNotDropOrDuplicateRows` — more rows than one page

---

## Task 4: CSV and XLSX writers

**Files:** `Sources/KodaCore/CSVWriter.swift`, `Sources/KodaCore/XLSXWriter.swift`

CSV: RFC 4180. Quote a field containing comma, quote, CR or LF; double internal
quotes; CRLF line endings; UTF-8 BOM.

XLSX: `[Content_Types].xml`, `_rels/.rels`, `xl/workbook.xml`,
`xl/_rels/workbook.xml.rels`, one `xl/worksheets/sheetN.xml` per report.
`inlineStr` cells. XML-escape `& < > " '`, and strip control characters, which
are legal in a crawled title and illegal in XML — a single stray 0x0C in a
page title would otherwise produce a workbook Excel refuses to open.

Sheet names: Excel forbids `: \ / ? * [ ]` and caps at 31 characters. Sanitise,
and de-duplicate the result so two long report names cannot collide.

**Tests:**
- CSV: `quotesAFieldContainingAComma`, `doublesInternalQuotes`,
  `quotesAFieldContainingANewline`, `distinguishesNilFromEmpty`,
  `startsWithAUTF8BOM`, `usesCRLF`
- XLSX: `producesAWorkbookPythonCanOpen` (shell to `python3 -c` using
  `zipfile` and `xml.etree`), `everySheetIsListedInTheWorkbook`,
  `aKnownCellHoldsAKnownValue`, `escapesXMLSpecialCharacters`,
  `stripsControlCharactersThatWouldBreakExcel`,
  `sanitisesAndDeduplicatesSheetNames`

**Verify:** the Python check must actually parse the XML, not just open the zip.

---

## Task 5: Export from the app

**Files:** `Sources/KodaUI/ExportCommands.swift` (new),
`Sources/KodaUI/ContentView.swift`

Two commands: export the current report, and export all reports. CSV writes one
file (or a folder for "all"); XLSX writes one workbook with one sheet per
report. `NSSavePanel` picks the destination. The work runs off the main actor,
with the toolbar showing progress and any error surfacing in the existing
notice banner.

**Tests** (`Tests/KodaUITests/ExportCommandsTests.swift`): the filename builder
and format selection are testable; `NSSavePanel` is not, and is not tested.
- `theSuggestedFilenameNamesTheHostReportAndDate`
- `aFilenameIsSafeForTheFilesystem`
- `exportingAllReportsWritesOneFilePerReport` — against a temp directory,
  bypassing the panel

---

## Task 6: Crawl configuration UI

**Files:** `Sources/KodaUI/CrawlSettings.swift` (new),
`Sources/KodaUI/ConfigSheet.swift` (new), `Sources/KodaUI/CrawlController.swift`

`CrawlSettings` persists a `CrawlConfig` to `UserDefaults` as JSON and validates
it. The controller uses it in `beginCrawl` instead of building a default config.

Validation, before a crawl starts rather than during one:
- workers 1...50, maxPerHost 1...workers, timeout 1...300, maxRedirects 0...50
- urlCap at least 1
- every include/exclude pattern compiles as a regex

An invalid regex today would silently match nothing inside
`Store.passesFilters`, which is the worst possible failure: the crawl looks fine
and quietly skips everything.

**Tests** (`Tests/KodaUITests/CrawlSettingsTests.swift`):
- `settingsRoundTripThroughUserDefaults` — against a scratch suite, not the
  real one
- `anInvalidRegexIsRejectedWithTheOffendingPattern`
- `maxPerHostIsClampedToWorkers`
- `outOfRangeValuesAreClampedNotAccepted`
- `defaultsAreReturnedWhenNothingIsStored`
- `corruptStoredJSONFallsBackToDefaults` — a truncated blob must not brick the app

---

## Task 7: Completion

Update `docs/superpowers/specs/2026-08-17-screaming-koda-design.md` to mark
M1–M4 delivered, and record the two known deviations: the write-batching cadence
and exact-match-only duplicate detection.

## M4 Completion Criteria

- [x] `swift test` passes
- [x] A crawled page in Windows-1252 shows the correct title
- [x] The current report exports to CSV; the file is written and read back in a test
- [x] All reports export to one XLSX with eleven sheets, and Python can parse it
- [x] An exported file's rows equal the table's rows for the same view
- [x] Configuration survives relaunch
- [x] An invalid regex is refused before the crawl starts
- [x] `grep -rE 'import (AppKit|SwiftUI)' Sources/KodaCore` returns nothing
- [x] No build warnings outside the swift-testing deprecation

Verified 2026-08-21 against `4757b24` plus the CLI export: `swift test` 388
passed, `swift build` clean with no warnings outside the swift-testing
deprecation, `grep -rE 'import (AppKit|SwiftUI)' Sources/KodaCore` empty.

End-to-end, through the shipped `koda` binary rather than only through tests:
a crawl of the fixture site over real HTTP, then `koda export` producing an
eleven-sheet workbook that Python's `zipfile` and `xml.etree` both accept, with
the Windows-1252 page's title surviving as `Café naïve` all the way into the
CSV.

**Not verified:** that Excel or Numbers opens the workbook. The format is
checked against a real OOXML parser, not against Excel itself, and a sample
file has been handed over for a human to double-click.
