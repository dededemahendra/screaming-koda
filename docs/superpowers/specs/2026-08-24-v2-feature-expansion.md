# v2 Feature Expansion — Design

**Date:** 2026-08-24
**Status:** In progress. 104 of 125 delivered.
**Supersedes:** nothing. v1 (`2026-08-17-screaming-koda-design.md`) is delivered
and its decisions still hold; this records what was built on top and why.

## What changed

v1 said, in as many words, that this would not reach Screaming Frog parity —
that the target was the reports you actually open, not every feature. v2
reverses that against a specific list of 125 Screaming Frog features.

That is a change of goal rather than more of the same work, and it is worth
being explicit that it was made deliberately. The audit that tracks it is
regenerated from `features.tsv` after each wave.

## The shape of the work

Sequenced by dependency, not preference. Each wave needed the one before it.

| Wave | What it was | Result |
|---|---|---|
| 1 | Surface data already collected | 41 → 55 |
| 2 | Read more out of HTML already fetched | 55 → 74 |
| 3 | New ways in and out of a crawl | 74 → 86 |
| 4 | A rendering engine | 86 → 92 |
| 5 | Blocked on external accounts | not started |
| 6 | Application features | 92 → 104 |

The estimate that was most wrong was Wave 4. A browser engine was budgeted in
months and took a sitting, because probing came before designing.

## Decisions

**Every report is still a filtered view over `urls`.** M3b's governing decision
survived twenty-five report tabs and 153 filters without a single per-report
special case. Two reports strained it — Images is keyed on the image URL rather
than the *(page, image)* pair, and Resources does the same for stylesheets and
scripts — and both are better for it, because the question really is "is this
file broken" rather than "which page mentioned it".

**`KodaCore` still imports no UI framework.** This survived PDFKit, CoreText and
WebKit by being tested rather than assumed each time. PDFKit and CoreText are
document and text-layout frameworks and went in directly; WebKit is not, and
went into a separate `KodaRender` target with `KodaCore` declaring only a
protocol. The grep that enforces it now covers WebKit too.

**Probe before designing.** Every framework question in v2 was settled by
running code before any design depended on the answer:

| Question | Answer |
|---|---|
| Does PDFKit work headless? | Yes — metadata, page count and text layer |
| Does CoreText measure text headless? | Yes |
| Does SQLite here have JSON1? | Yes — `json_extract` and `json_each` |
| Does WKWebView run with no `NSApplication`? | Yes, and inside `swift test` |
| Can Core Web Vitals be measured? | TTFB, FCP, LCP and load yes; **CLS and INP no** |

The last one is why there is a Performance tab and not a Core Web Vitals tab.
WebKit's `supportedEntryTypes` has no `layout-shift`, and INP needs a real
interaction a crawler never makes. Naming four of six metrics Core Web Vitals
would imply the other two passed, so there are no columns for them and a test
asserts their absence.

**Absent rather than defaulted.** A metric a page did not produce, a header a
server did not send, a title a PDF does not have: all nil. A zero would read as
a measurement.

**Rendering never costs a page.** A failed render keeps the static parse and
marks the row as not rendered. The v1 rule — a crawl never dies from a bad page
— extends to the browser.

## Two things that were structurally wrong before they were right

Worth recording because in both cases the number looked adjustable and was not.

**Near-duplicate banding.** Simhash near-duplicate detection uses an
index-backed band prefilter so a large crawl need not compare every page against
every other. That prefilter is only *complete* by pigeonhole: `k` differing bits
fall in at most `k` bands, so the threshold must stay below the band count or
genuine near-duplicates get silently dropped. The first attempt used four bands
with a threshold of three; measurement then showed real near-duplicates sit four
to eight bits apart. Raising the threshold alone would have produced a report
that looked clean while missing things. The structure changed instead: eight
bands of eight bits, threshold seven, with a test sweeping every combination of
up to three flipped bits to confirm no pair within the threshold loses every
band.

**Crawl comparison against old files.** Comparison uses SQLite `ATTACH` over two
`.koda` files. An older file genuinely lacks the later columns, `ATTACH` does not
migrate it, and migrating someone's previous crawl in order to read it would be
a rude thing for a comparison to do. So the comparison is restricted to fields
that have existed since v1 — which costs nothing, because status, title,
description, H1, canonical and the whole indexability ladder are all v1. A test
builds a real v1 database by running only the first migration.

## Known hazards

**Adding a stored property to a public `KodaCore` struct needs a clean build.**
SwiftPM's incremental build does not always propagate the layout change, and the
symptom is not a compile error — it is `swift test` crashing with SIGSEGV or
SIGBUS somewhere unrelated. Diagnosed from the `.ips` crash report, which named
`initializeWithCopy for ExtractionRule` inside `JSONEncoder`. Two hypotheses were
rejected before the crash report was consulted; read it first. This has recurred
three times since and been recognised immediately each time.

**The renderer and the static decoder disagree on undeclared encodings.** A page
that declares no charset renders in WebKit's legacy fallback, as any browser
would, while `TextDecoding` tries UTF-8 first. Neither is wrong. The browser is
the authority for a rendered page.

**Repeated `Set-Cookie` headers collapse.** `URLSession` joins them into one
comma-separated value, so the cookie filters answer "is any cookie missing this
flag" and cannot say which one.

**Pixel-width thresholds are conventions, not contracts.** Google changes them
without notice. They are a guide.

## What remains

Twenty-one items, of which twelve cannot be built here at all:

**Blocked on your accounts (12).** Google Analytics, Search Console, PageSpeed
Insights and Lighthouse need Google OAuth. Ahrefs, Majestic and Moz need paid
API keys, and backlink analysis needs one of them — no crawler can see backlinks
on its own. The three "versus crawl" comparison reports sit on top of those.

**Achievable, not yet built (9).** Crawl visualisation and crawl trees;
scheduling; user-defined custom reports; XPath extraction (CSS selectors and
JavaScript expressions cover the ground today); form-based authentication
(Basic and header auth work); and Core Web Vitals, which is capped by WebKit
rather than by effort.

Nothing left is blocked on a hard technical problem. What remains is either an
API key or a different kind of application.

## Testing

Unchanged in principle, larger in practice: 573 tests. Two habits carried the
weight.

**Assert on names, not counts.** Report tests name the fixture rows they expect,
so the fixture can grow without invalidating every assertion.

**The fixture defends itself.** After the long-URL page's generated title tripped
the Over 60 filter — making it a false positive in a report it had nothing to do
with — an invariant test was added asserting no auto-generated text trips a
length filter. It caught the same bug twice more, in H1 and then H2.
