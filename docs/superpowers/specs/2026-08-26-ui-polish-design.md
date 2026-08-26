# UI Polish — Design

**Date:** 2026-08-26
**Status:** Approved for implementation planning
**Scope:** The whole window. Sidebar, table, inspector, settings, empty and
live states, and the two visualisations.

## Why now

The window was designed for eleven report tabs. It now has twenty-six, and 163
filters, 112 of which are issue filters. Nothing about the layout changed as
that grew, so the interface is not so much unpolished as outgrown.

Rendered and inspected before designing any of this, which is worth doing
because two things that looked like bugs were not:

| Looked like | Actually |
|---|---|
| The toolbar is missing | It renders; the capture had a transparent ground |
| The inspector draws nothing | It renders 78 distinct colours; same cause |
| The sidebar takes half the window | Real. `HSplitView` ignores its `idealWidth` |
| Columns truncate and overflow | Real. Address is a fixed 340pt; seven columns fall off the right |
| The URL cap reads "500.000" | **Not a bug.** The locale here is `en_ID`, whose grouping separator is `.`, so 500000 is grouped correctly |

**Views that paint no background composite as transparent, and `cacheDisplay`
leaves those regions uninitialised — which looks exactly like a view that
failed to draw.** That cost two false diagnoses and is the reason the capture
harness becomes a real test utility rather than a probe.

The third came from reading a screenshot rather than checking a value. Locale
formatting was correct all along, and the lesson is the same one: a rendering
that looks wrong is evidence about the rendering, not yet about the code.

## Decisions

**Issues first, browse second.** The sidebar opens on what is wrong with the
site, ranked, rather than on a list of report names. Twenty-six tabs is too many
to hunt through, and "what should I fix" is the question the tool exists to
answer. Report sections stay, collapsed, below a divider, for the times you
want a specific view.

**Severity is a property of the finding, not of the sidebar.** It lives on
`ReportFilter` in `KodaCore`, replacing `isIssue: Bool` with `severity:
Severity?` — an issue filter is exactly one with a band. Putting it in the view
would let the window, the export and the CLI disagree about what matters, which
is the same divergence the crawl summary and the reports already had once and
which took a test to notice.

That change has two call sites beyond the sidebar: `Store.overview()`, which
lists issue filters in the export's first sheet, and the sidebar's own count
colouring. Both should read the band rather than a boolean, so the export can
group by severity too.

**Native chrome, deliberate data language.** Standard controls, materials and
SF Symbols, so the app behaves as a Mac app should and ages with the OS. What
is designed is the data display: type scale, tabular figures, and semantic
colour used sparingly. Dense tables are won on legibility.

**Colour marks exceptions only.** A 200 is not an event and gets no colour. If
every row is coloured, none of them is. This is the single rule that decides
whether the table scans.

**`ContentView` splits up.** It is 256 lines already doing toolbar, layout,
export and two sheets; adding issues, browse, four states and a preferences
window would push it past 600. It becomes a shell over `CrawlToolbar`,
`WorkspaceView` and the sidebar pieces, each answerable for one thing.

**`NavigationSplitView`, not `HSplitView`.** This is the actual fix for the
sidebar taking half the window, and it brings correct sidebar material and
width behaviour with it rather than being fought for.

## Severity bands

Three, in the order a person would work through them.

| Band | Means | Colour |
|---|---|---|
| **Breaks indexing** | The page cannot rank, or the crawler could not reach it | critical |
| **Costs clicks** | The page is indexed but underperforms in results | warning |
| **Hygiene** | Worth fixing, not costing traffic today | secondary |

Assignment is per filter, not per report, because a report mixes severities: a
canonical pointing at a 404 breaks indexing while a missing canonical does not.
Each report declares a default band and individual filters override it.

**Breaks indexing** — response codes (4xx, 5xx, no response, redirect loops,
reached via 2+ redirects), non-indexable pages, broken external links and
resources, canonicalised or multiple canonicals, canonical to a non-200,
noindex, meta-versus-header directive conflicts, hreflang to a non-200,
duplicate and near-duplicate content, sitemap orphans, sitemap URLs that are
non-indexable or were never reached, every crawlability reason, content that
only exists after rendering, pages empty without JavaScript, and pages getting
clicks that the crawl found non-indexable.

**Costs clicks** — every title and meta description finding, all four SERP
truncation findings, thin and empty content, field Core Web Vitals failing,
Lighthouse under 50, slow LCP, TTFB and load, impressions without clicks, and
indexable pages with no clicks at all.

**Hygiene** — headings, images, URL shape, anchor text, social tags, structured
data, pagination, security headers and cookie flags, page depth, hreflang
return links and x-default, nofollow and noarchive, missing canonicals, missing
analytics, low text ratio, JavaScript errors, slow renders, oversized
resources, pages absent from the sitemap, and extraction rules that matched
nothing.

Within a band, order by count descending. A band with nothing in it is not
shown — an empty heading is worse than no heading.

## Design tokens

One file, `Sources/KodaUI/Design/Theme.swift`. Everything visual reads from it.

**Type.** System font throughout. Four roles: `title` for section headers,
`body` for table rows and detail values, `label` for sidebar rows and column
headers, `caption` for counts, units and secondary text. Every numeral in the
app is `.monospacedDigit()` — a table of right-aligned counts that jitter as
they update is the most obvious tell of an unconsidered data view.

**Spacing.** A 4pt grid: 2, 4, 8, 12, 16, 24. No other values.

**Colour.** Semantic, not decorative, and defined only in terms of system
colours so both appearances and increased-contrast come free.

| Token | Used for |
|---|---|
| `critical` | 4xx, 5xx, transport errors, breaks-indexing findings |
| `warning` | 3xx, costs-clicks findings |
| `quiet` | 2xx, hygiene findings, everything unremarkable |
| `accent` | selection and indexable state only |

## The window

**Sidebar**, fixed width via `NavigationSplitView`. A header naming the crawl
and its total issue count; the three severity bands listing only non-zero
filters; a divider; collapsible report sections, with the one currently being
viewed expanded and the rest closed. One search field narrows both halves at
once, matching filter names and report names — so typing "canonical" finds both
the Canonicals report and the canonical findings inside other reports.

**Table.** Address flexes to fill; every other column sizes to its content
instead of falling off the right edge. Status becomes a badge carrying its
semantic colour, indexability takes the same colours so the two agree at a
glance, numerals are tabular. The empty striped rows below the data go — they
read as a rendering fault.

**Inspector.** Unchanged in structure; it already works. Its label column stops
being a fixed 190pt so values do not strand themselves mid-pane on a wide
window.

## Four states

Today there is one, and a finished crawl that found nothing looks identical to
a broken one.

| State | Shows |
|---|---|
| No crawl | A centred panel: what this does, and the seed field focused |
| Crawling | Rate, depth reached, and issues appearing in the sidebar as they are found |
| Finished, clean | "No issues found" stated plainly, with what was checked |
| Failed | The existing notice banner, restyled to the tokens |

## Settings

Becomes a preferences window with panes — Crawl, Limits, Rendering,
Authentication, Extraction, Data sources — instead of eight sections stacked in
a fixed 520×640 sheet that shows two.

Numeric fields gain their units — the timeout reads "20" today with nothing
saying seconds, and the URL cap is a bare number. Locale formatting is left
alone: it was already correct, and a hand-rolled separator would be wrong on
every machine but one.

## The visualisations

The tree and graph work and are legible. They adopt the tokens: severity
colours rather than their own orange, the spacing grid, and the type scale. No
structural change.

## Testing

| Unit | Approach |
|---|---|
| Severity bands | Every issue filter has exactly one band; no non-issue filter has one; the inventory count is asserted so a new filter cannot be added without a band |
| Sidebar ordering | Pure function over counts and bands: band order fixed, count order within, empty bands absent |
| Table columns | Widths resolve to fill a given pane width without overflow at several window sizes |
| Theme tokens | Every semantic colour resolves in both appearances |
| Views | Rendered through the capture utility and asserted non-blank, against an opaque ground |
| Settings | Numeric fields round-trip their values under a locale whose separators differ from the developer's, since that is where hand-rolled formatting breaks |

**The capture harness becomes `Tests/KodaUITests/ViewCapture.swift`**, a real
utility rather than a probe: it hosts a view in a window over an opaque ground,
gives SwiftUI run-loop turns to draw, and returns the bitmap. Its doc comment
records why the opaque ground is not optional. Layout stays a pure function
wherever possible, so most of this is testable without rendering at all — as
`LinkGraphView.layout` already is.

## Out of scope

A density control, themes, window-state restoration, animation beyond what the
standard controls do themselves, and any change to what the reports contain.
This pass changes how the crawl is presented, not what is crawled.
