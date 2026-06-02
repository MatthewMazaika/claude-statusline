# Right-align the budget cluster

## Goal

Split the status line into two semantic groups and pin the budget group to the
right edge of the terminal:

- **Left — identity:** what I'm working on. `dir | model | context`
- **Right — budget:** how my limits and money are doing. `5h gauge | 7d gauge | cost`

The split is the point; right-alignment is how it's made stable. Pinning the
budget cluster to the right edge gives the eye a consistent place to land for
the at-a-glance numbers, no matter how long the directory/model path on the left
runs.

```
code/my-project | opus-4-7/high | 12k/200k        5h:80% [█○████░░] | 7d:36% [█████○░░] | $1.23
deep/nested/path | opus-4-7/high | 80k/200k       5h:80% [█○████░░] | 7d:36% [█████○░░] | $1.23
                                                  └─ budget cluster flushed to the right edge
```

## Why this shape

Claude Code has **no native right-alignment** (unlike Copilot CLI), so the
mechanism is ours: CC sets the `COLUMNS` env var (v2.1.153+) to the terminal
width before running the statusline command, and we pad the seam between the two
clusters with spaces to flush the budget group right.

The load-bearing decision is the **fit-check**: we right-align *only* when the
whole line provably fits within the terminal. CC's behavior when a statusline
overflows is undocumented (the docs only say "may truncate or wrap awkwardly"),
so rather than risk a worse render than today, the design refuses to overflow in
split mode and falls back to the current single-line `join(" | ")` whenever the
split wouldn't fit or the width is unknown. The feature is therefore strictly
additive: in the common wide-terminal case it right-aligns; everywhere else it
reproduces today's output verbatim.

**Alignment is right-edge, not fixed-column.** The budget cluster's *last*
character (cost's final digit) is pinned to the edge; the cluster's left edge —
where the `5h` gauge starts — floats by a few columns as `%`/cost digit-widths
change, as cost appears/disappears, or as a window renders bare without a gauge.
True fixed-column alignment (padding each field to a max width so the gauge never
moves) was considered and rejected: it costs internal padding and width for a
stability the right-edge approach already delivers where it matters (the right
edge), and "the gauge drifts a couple columns" is an acceptable cost for the
simpler renderer.

## Layout & seam

- **Left cluster:** `(dir if non-empty) + [model, ctx]`, joined by `" | "`.
- **Right cluster:** `(5h if present) + (7d if present) + (cost if present)`,
  joined by `" | "`.
- The single `" | "` separator that today sits at the identity↔budget seam is
  replaced by the space-gap in split mode. All *within-cluster* separators stay
  `" | "`.
- The existing field-presence logic splits cleanly along the seam — no field
  straddles it, so the same conditional-inclusion rules that exist today carry
  over unchanged into the two clusters.

## Width measurement

Every field today is single-width text — the gauge glyphs `○` (U+25CB),
`█` (U+2588), `░` (U+2591) are each one BMP codepoint and one terminal cell, and
there are no ANSI color codes. So character count equals on-screen width:

- jq: `length` (counts Unicode codepoints).
- PowerShell: `.Length` (UTF-16 code units; all glyphs are BMP = 1 unit each).

**Assumption to guard:** this equality breaks if colored/ANSI output is ever
added. A comment at each measurement site must note that ANSI stripping would be
required first. Out of scope here.

## The split/fallback decision

Inputs: `left` string and its length `L`; `right` string and its length `R`;
`cols` = `COLUMNS` (empty if CC < v2.1.153). Constant `MIN_GAP = 2`.

Evaluated in order:

1. `cols` empty / not a positive integer → **fallback** (covers old CC).
2. `right` empty (no windows *and* no cost) → emit `left` alone (identical to today).
3. `left` empty (no dir) → flush `right` right anyway.
4. `L + MIN_GAP + R > cols - 1` → **fallback**. Clusters plus a 2-space minimum
   gap don't fit inside the usable width. `cols - 1` reserves the trailing column
   (writing into the last cell triggers a phantom wrap on some terminals).
5. Otherwise → **split**: `pad = (cols - 1) - L - R` spaces between clusters.
   Rule 4 guarantees `pad ≥ MIN_GAP`.

`MIN_GAP = 2` is the smallest gap that still reads as two groups; below it the
visual-separation goal fails anyway, so the explicit `" | "` seam (fallback) is
the better render.

**Fallback output is byte-for-byte today's output** — the same field list run
through `join(" | ")`. There is exactly one code path producing the current
format and it is reused verbatim.

## Overflow stance

- **Split mode never overflows** — by construction (the fit-check is the guard).
- **Fallback inherits today's overflow behavior untouched** — whatever CC does
  with an over-wide line, it already does now; we emit the identical string.

## Files to change

- **`statusline.sh`** — split the final pipeline (currently one array →
  `join(" | ")`) into two cluster arrays, then apply the decision above using
  `$cols`. The `render()` wrapper gains `--arg cols "${COLUMNS:-}"` alongside the
  existing `--argjson now`.
- **`statusline.ps1`** — mirror: two-cluster build + decision, reading
  `$env:COLUMNS`, measuring with `.Length`.
- **`--demo`** — set a fixed `COLUMNS` (90) so the demo renders the split rather
  than silently hitting fallback and printing the old format. Resolve the
  `%-13s` row-label offset by dropping the inline label in split-demo (label via
  a preceding echo/comment line instead).
- **`README.md`** — update the top-line example and the demo block to show the
  new right-aligned default (last-touch consistency).
- **Tests** — no harness exists today; add golden-output assertions driving the
  renderer with fixed `CLAUDE_STATUSLINE_NOW` + `COLUMNS`. Cases: wide→split,
  narrow→fallback, no-`COLUMNS`→fallback, empty-right→left-only, the 1-col right
  margin, and the bare-window (no-gauge) right cluster.

## Verification to perform during implementation

- **`COLUMNS` in non-interactive bash.** bash does not set `COLUMNS` itself in
  scripts; the design relies on CC exporting it into the environment where
  `${COLUMNS:-}` reads it. The CC docs say it sets the var, but confirm
  empirically that a non-interactive bash actually sees it. The fallback covers
  us if it's ever empty, so this is a quality check, not a blocker.

## Documented limitations

- **`padding` setting offset.** If the user sets the statusline `padding` option
  in `settings.json`, CC indents our output by an amount the script cannot read,
  so a split line measured against `cols` may clip a few columns past the edge.
  Uncommon; failure mode is a mild wrap; no clean in-script detection. Noted in a
  code comment rather than defended against an unknown offset.
- **Threshold flicker.** Near a full-width terminal, a line that just fits in
  split mode can tip into fallback when a `%` gains a digit or cost first appears,
  flipping the seam between a space-gap and `" | "`. Rare, self-correcting, and
  fallback is still readable.
