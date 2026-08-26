# M3b Reports — Design

**Milestone:** M3b, per `docs/superpowers/specs/2026-08-17-screaming-koda-design.md`.

**Goal:** The eleven report tabs, the sidebar with issue counts, and the detail
inspector. After this the app answers the questions people actually open an SEO
crawler for.

**Scope:** Presentation and queries only. The crawler is not touched — M3a
finished the data. Every report is a query over rows that already exist.

## The one decision everything else follows from

**Every report is a filtered view over `urls`, keyed by `urls.id`.**

All eleven tabs, and every filter within them, are the same shape: a `WHERE`
clause over `urls LEFT JOIN responses LEFT JOIN page_facts`. Nothing introduces
a second row identity.

This is not obvious for two of them, so it is worth being explicit:

- **Images** could plausibly be keyed on the *(page, image)* pair, since "missing
  alt" is a property of an occurrence rather than of an image. It is keyed on
  the image URL instead, with alt problems aggregated across the pages that
  reference it. That is also what Screaming Frog does: the Images tab lists
  image URLs and the inspector shows which pages reference them.
- **Page Depth** is described in the master spec as a distribution. A
  distribution is a chart, not a table, and M3b has no charts. It ships as two
  row filters — pages deeper than 3, and pages with a single inlink — which is
  the part that leads to action anyway.

Keeping one row identity means `RowIndex`, `RowStore`, sorting, selection, and
the inspector all keep working with no special cases. A report becomes a value
in an array, exactly as the master spec promised. The cost is that a report
which genuinely needs a different grain cannot be expressed; nothing in the
eleven does.

## Architecture

No new targets. Three new files in `KodaCore`, three in `KodaUI`.

| Unit | Target | Responsibility |
|---|---|---|
| `Report`, `ReportFilter`, `ReportColumn` | `KodaCore` | The shape of a report |
| `Reports.all` | `KodaCore` | The eleven definitions |
| `Indexability` | `KodaCore` | The shared SQL expression for indexable / why not |
| `Store+Counts` | `KodaCore` | Every sidebar count in one query |
| `ReportSelection` | `KodaUI` | Which tab and filter are showing |
| `SidebarView` | `KodaUI` | Reports and their counts |
| `InspectorView` | `KodaUI` | Details, inlinks, outlinks, images for the selected row |

`KodaCore` still imports neither AppKit nor SwiftUI.

### Why the definitions live in `KodaCore`

The M2 design put column choice in the app, on the grounds that presentation is
the app's business. That was right for one hard-coded table and is wrong for
eleven generated ones: a report is about 90% SQL and 10% header text, and
splitting each definition across two modules to honour the boundary would put
the two halves out of step the first time a column changed.

The boundary that actually matters is that `KodaCore` builds and tests headless.
A struct holding a header string does not threaten that. A struct holding an
`NSTableColumn` would, and does not exist.

### `Report`

```swift
public struct ReportColumn: Sendable, Identifiable {
    public let id: String          // stable key, also the SQL alias
    public let header: String
    public let expression: String  // SQL, e.g. "f.title_length"
    public let width: Double
    public let alignment: ColumnAlignment   // .leading or .trailing, no AppKit
    public let sortable: Bool
}

public struct ReportFilter: Sendable, Identifiable {
    public let id: String
    public let name: String
    public let predicate: String   // SQL, ANDed with the report's own predicate
    public let isIssue: Bool       // issue counts are worth surfacing; "All" is not
}

public struct Report: Sendable, Identifiable {
    public let id: String
    public let name: String        // the tab label
    public let predicate: String   // what belongs in this tab at all
    public let columns: [ReportColumn]
    public let filters: [ReportFilter]
}
```

`ReportFilter.predicate` is ANDed with `Report.predicate`. Selecting the
Titles tab's "Over 60 characters" filter yields
`(internal and 200 and html) AND (f.title_length > 60)`.

Every column carries its SQL expression, so `ORDER BY` is by expression and a
sort key is only reachable if it names a column the report actually declares.
User input never reaches SQL: a click gives a column id, and an id that is not
in the report resolves to nil.

### The shared `FROM`

```sql
FROM urls u
LEFT JOIN responses r ON r.url_id = u.id
LEFT JOIN page_facts f ON f.url_id = u.id
```

One string, used by `RowIndex`, `RowStore`, and the count query. Reports that
need more — inlink counts, image alt aggregates — get it through a correlated
subquery in a column expression rather than by extending the join, so the base
query plan stays the same for all eleven.

### Indexability

Several reports need "would Google index this, and if not why", and each would
otherwise re-derive it slightly differently. It is defined once, as SQL:

| Verdict | Condition | Precedence |
|---|---|---|
| Non-indexable, redirected | status 300–399 | 1 |
| Non-indexable, client error | status 400–499 | 2 |
| Non-indexable, server error | status ≥ 500, or status 0 | 3 |
| Non-indexable, noindex | `meta_robots` or `x_robots_tag` contains `noindex` | 4 |
| Non-indexable, canonicalised | `canonical_id` is set and is not the row itself | 5 |
| Indexable | otherwise | — |

Precedence matters: a 404 that also carries a noindex is reported as a client
error, because that is the problem to fix.

### Counting for the sidebar

Eleven tabs times roughly five filters is around fifty counts. Fifty
`COUNT(*)` queries at the crawl's refresh cadence is not viable, so they are
computed in a single pass:

```sql
SELECT sum(CASE WHEN <predicate 1> THEN 1 ELSE 0 END) AS f1, ... FROM <shared from>
```

One scan, all counts. The scan is still O(rows), so during a crawl the counts
refresh at 0.5 Hz rather than the table's 2 Hz. The table is what the user is
watching; a count that is two seconds stale is not a defect, and a full scan
four times a second at 500k rows would be.

Counts refresh unconditionally once the crawl finishes, so the final numbers
are never a stale sample.

## The window

```
┌──────────────────────────────────────────────────────────┐
│ [https://example.com/  ] [Start] [Pause] [Stop]   status  │
├────────────┬─────────────────────────────────────────────┤
│ Internal   │ Address │ Status │ Title │ Len │ Indexability│
│  All   142 │ ─────────────────────────────────────────── │
│ Titles     │ ...rows...                                  │
│  Missing 3 │                                             │
│  Dupes  11 │                                             │
│ Images     ├─────────────────────────────────────────────┤
│  No alt  7 │ Details │ Inlinks │ Outlinks │ Images       │
│ ...        │ ...detail for the selected row...           │
└────────────┴─────────────────────────────────────────────┘
```

**Sidebar.** Every report, each expandable to its filters with counts. Issue
filters with a non-zero count are the point of the pane, so a count of zero is
shown greyed rather than hidden — a stable list is easier to scan than one that
reorders itself mid-crawl.

**Table.** Unchanged machinery, now driven by the selected report's columns.
Switching tab or filter rebuilds the index and clears the row cache; it is the
same path the sort already takes.

**Inspector.** Bottom pane, showing the selected row. Four sub-tabs:

| Sub-tab | Query |
|---|---|
| Details | Every field for the row, including the ones no column shows |
| Inlinks | `links` where `to_url_id` = row, with anchor text and rel |
| Outlinks | `links` where `from_url_id` = row |
| Images | `images` where `url_id` = row, with alt |

Each is a small indexed query keyed on `url_id`, run on selection, capped at
1,000 rows. A page with more than a thousand inlinks exists, and paging the
inspector is not worth it in M3b; the cap is stated in the pane rather than
silently truncating.

## The eleven reports

Filters marked with a dot are issue filters and get a sidebar count.

**Internal** — internal URLs. All · Non-indexable
**External** — external URLs, status only. All · Broken (4xx/5xx/error)
**Response Codes** — everything fetched. All · 2xx · 3xx · 4xx · 5xx · Transport error · Redirect chain (2+ hops) · Redirect loop
**Titles** — internal, 200, HTML. All · Missing · Duplicate · Over 60 · Under 30 · Multiple · Same as H1
**Meta Description** — same base. All · Missing · Duplicate · Over 155 · Under 70 · Multiple
**Headings** — same base. All · Missing H1 · Duplicate H1 · Multiple H1 · Over 70 · Missing H2
**Images** — image URLs. All · Missing alt · Alt over 100 · Over 100KB
**Canonicals** — internal, 200, HTML. All · Missing · Self-referencing · Canonicalised · To non-200
**Directives** — same base. All · noindex · nofollow · X-Robots conflict
**Hreflang** — internal with hreflang. All · Missing return link · Non-200 target · Missing x-default
**Page Depth** — internal, crawled. All · Deeper than 3 · Single inlink

"Duplicate" is exact match on the stored value, over rows that have one, in the
same crawl. "Redirect loop" is a chain that reaches a URL already in it, which
`redirect_hops` plus `redirect_target_id` can express without recursion.

## What this does not do

Charts. Export — that is M4. Custom filters or a query box. Column resizing and
reordering. Cross-crawl comparison.

Two things are inherited limitations rather than choices, and are worth naming
because M3b is where they start to show:

**Character encoding.** Bodies are decoded as UTF-8 unconditionally. A page in
a legacy encoding produces a garbled title, and a garbled title will appear in
the Titles report as a real finding when it is an artefact. Detection is M4.

**Duplicate detection is exact-match.** Two titles differing by a trailing space
are not duplicates. This is the master spec's stated v1 position, not a
regression.

## Testing

| Unit | Approach |
|---|---|
| Every report query | One fixture crawl covering every issue class; assert each filter returns exactly the rows it should. This is the bulk of the milestone's tests. |
| Every filter is valid SQL | A single test that prepares all fifty predicates against the schema. Catches a typo in a report nobody wrote a case for. |
| Indexability | Table-driven over the precedence rules, including a 404 that also carries noindex |
| Counts | The one-pass count query agrees with running each filter separately |
| `RowIndex` and `RowStore` | Existing tests, extended to a non-default report |
| Sorting | A sort key not declared by the report resolves to nil |
| Inspector | Inlinks, outlinks, and images return the right rows for a known fixture; the 1,000 cap holds |
| Sidebar | Selection state; counts render |
