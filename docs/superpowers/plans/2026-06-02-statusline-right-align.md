# Right-aligned budget cluster — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Pin the budget fields (5h gauge, 7d gauge, cost) to the terminal's right edge while keeping identity fields (dir, model, context) on the left — falling back to today's single-line `join(" | ")` whenever the split won't fit or the terminal width is unknown.

**Architecture:** Both renderers build a `left` and a `right` cluster string, measure each, read `COLUMNS`, and pad the seam with spaces to flush `right` to column `COLUMNS-1` — but only when `left + 2-space gap + right` fits inside `COLUMNS-1`. Otherwise they emit the current `left | right` join byte-for-byte. The two scripts are independent reimplementations (bash+jq, pure PowerShell); a single shared test runner pins both to one table of expected output so they can't drift.

**Tech Stack:** bash + jq ≥ 1.5 (`statusline.sh`), PowerShell (`statusline.ps1`), a bash test runner (`tests/run.sh`).

**Spec:** `docs/superpowers/specs/2026-06-02-statusline-right-align-design.md`

---

## File structure

- `statusline.sh` — modify: add a `spaces` jq def; restructure the final pipeline into `left`/`right` clusters + the split/fallback decision; `render()` passes `--arg cols`; `--demo` sets `COLUMNS` and prints labels on their own line.
- `statusline.ps1` — modify: mirror the cluster build + decision in `Render-Status`; `--demo` mirrors the label/width change.
- `tests/run.sh` — create: thin shared-contract runner. Defines cases inline (no framework), runs each through `statusline.sh` and — when `pwsh` exists — `statusline.ps1`, comparing both to the same expected line.
- `README.md` — modify: intro example shows the right-aligned default; one sentence on the right-edge budget cluster.

All expected strings below were captured from the **current** renderer (so fallback/field formatting is real) and the split targets computed from the spec's formula. Reference values for the demo payload at `now=0`:

- `LEFT` = `code/my-project | opus-4-7/high | 12k/200k` (42 chars)
- `RFULL` = `5h:80% [█○████░░] | 7d:36% [█████○░░] | $1.23` (45 chars)
- `RBARE` = `5h:80% | 7d:36% | $1.23` (23 chars; windows with a past/absent `resets_at` render gaugeless)
- Pad for a split = `(COLUMNS - 1) - LEFT_len - RIGHT_len`.

---

## Task 1: Shared-contract test runner (regression guard)

Create the runner with the three **fallback** cases first — these pass against the *unmodified* scripts, proving the harness works and pinning today's behavior before any change.

**Files:**
- Create: `tests/run.sh`

- [ ] **Step 1: Create `tests/run.sh`**

```bash
#!/usr/bin/env bash
# Shared behavioral contract for both renderers.
#
# Each case is rendered by statusline.sh AND (when pwsh is installed)
# statusline.ps1, and both must produce the SAME expected line. That shared
# expectation is the drift-killer: two hand-maintained implementations pinned
# to one table. pwsh is skipped (with a notice) when absent so the suite runs
# on a bare dev box; CI installs pwsh to enforce cross-platform parity.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"
sh_script="$root/statusline.sh"
ps_script="$root/statusline.ps1"

have_pwsh=0
if command -v pwsh >/dev/null 2>&1; then
  have_pwsh=1
else
  echo "note: pwsh not found — running statusline.sh only (PowerShell parity unchecked)"
fi

pass=0 fail=0

# Right-aligned expectation, built the way the spec defines it: left, then N
# spaces, then right. N is an explicit golden integer per case (audit it by eye).
gap()   { printf '%*s' "$1" ''; }
split() { printf '%s%s%s' "$1" "$(gap "$2")" "$3"; }

run_case() { # name  cols  now  json  expected
  local name="$1" cols="$2" now="$3" json="$4" expected="$5" got
  got="$(printf '%s' "$json" | COLUMNS="$cols" CLAUDE_STATUSLINE_NOW="$now" bash "$sh_script")"
  if [ "$got" = "$expected" ]; then pass=$((pass+1)); else
    fail=$((fail+1)); printf 'FAIL [sh] %s\n  want: |%s|\n  got:  |%s|\n' "$name" "$expected" "$got"
  fi
  if [ "$have_pwsh" = 1 ]; then
    got="$(printf '%s' "$json" | COLUMNS="$cols" CLAUDE_STATUSLINE_NOW="$now" pwsh -NoProfile -File "$ps_script")"
    if [ "$got" = "$expected" ]; then pass=$((pass+1)); else
      fail=$((fail+1)); printf 'FAIL [ps] %s\n  want: |%s|\n  got:  |%s|\n' "$name" "$expected" "$got"
    fi
  fi
}

LEFT='code/my-project | opus-4-7/high | 12k/200k'
RFULL='5h:80% [█○████░░] | 7d:36% [█████○░░] | $1.23'
RBARE='5h:80% | 7d:36% | $1.23'

J_FULL='{"cwd":"/home/you/code/my-project","model":{"id":"claude-opus-4-7"},"effort":{"level":"high"},"context_window":{"total_input_tokens":12000,"context_window_size":200000},"rate_limits":{"five_hour":{"used_percentage":20,"resets_at":4500},"seven_day":{"used_percentage":64,"resets_at":175392}},"cost":{"total_cost_usd":1.23}}'
J_BARE='{"cwd":"/home/you/code/my-project","model":{"id":"claude-opus-4-7"},"effort":{"level":"high"},"context_window":{"total_input_tokens":12000,"context_window_size":200000},"rate_limits":{"five_hour":{"used_percentage":20,"resets_at":0},"seven_day":{"used_percentage":64,"resets_at":0}},"cost":{"total_cost_usd":1.23}}'
J_NORATE='{"cwd":"/home/you/code/my-project","model":{"id":"claude-opus-4-7"},"effort":{"level":"high"},"context_window":{"total_input_tokens":12000,"context_window_size":200000},"cost":{"total_cost_usd":0}}'

# now=0 throughout: resets_at then equals the seconds left in each window.

# --- Fallback / characterization cases (green against today's renderer) ---
run_case "narrow-fallback"   80 0 "$J_FULL"   "$LEFT | $RFULL"
run_case "nocols-fallback"   "" 0 "$J_FULL"   "$LEFT | $RFULL"
run_case "empty-right"      120 0 "$J_NORATE" "$LEFT"

echo "----"
echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
```

- [ ] **Step 2: Make it executable and run it**

Run:
```bash
chmod +x tests/run.sh && bash tests/run.sh
```
Expected (on this dev box, no pwsh):
```
note: pwsh not found — running statusline.sh only (PowerShell parity unchecked)
----
pass=3 fail=0
```

- [ ] **Step 3: Commit**

```bash
git add tests/run.sh
git commit -m "test: shared-contract runner pinning current statusline output"
```

---

## Task 2: Right-align in `statusline.sh`

Add the three split cases (they fail first), then implement the split.

**Files:**
- Modify: `tests/run.sh` (add split cases)
- Modify: `statusline.sh` (jq `spaces` def, final pipeline, `render()`)

- [ ] **Step 1: Add the failing split cases to `tests/run.sh`**

Insert these three lines immediately **before** the `# --- Fallback` comment block:

```bash
# --- Split cases (right-aligned; fail until statusline.sh implements it) ---
run_case "wide-split"       120 0 "$J_FULL"  "$(split "$LEFT" 32 "$RFULL")"
run_case "margin-1col"       90 0 "$J_FULL"  "$(split "$LEFT" 2  "$RFULL")"
run_case "bare-window-split" 120 0 "$J_BARE" "$(split "$LEFT" 54 "$RBARE")"
```

Gap math (audit): wide `119-42-45=32`; margin `89-42-45=2` (total 89, leaving column 90 empty); bare `119-42-23=54`.

- [ ] **Step 2: Run to verify the split cases fail**

Run: `bash tests/run.sh`
Expected: `pass=3 fail=3` — the three split cases FAIL (current `statusline.sh` ignores `COLUMNS` and emits the `|`-join); the three fallback cases still pass.

- [ ] **Step 3: Add the `spaces` jq def**

In `statusline.sh`, immediately after the `def fmtcost: ... ;` block (ends at the line with `"$\($whole).\(...)";`), add:

```jq
  # repeat a space k times; jq's "x" * n yields null for n <= 0, so guard it.
  def spaces($k): if $k > 0 then (" " * $k) else "" end;
```

- [ ] **Step 4: Replace the final pipeline**

Replace this current trailing block of `PROG` (the part that starts with `| ( (if $dir != "" ...` and ends with `| join(" | ")`):

```jq
  | ( (if $dir != "" then [$dir] else [] end) + [$model, $ctx]
      + (if $fh   != null then [$fh]   else [] end)
      + (if $wk   != null then [$wk]   else [] end)
      + (if $cost != null then [$cost] else [] end) )
  | join(" | ")
```

with:

```jq
  # Identity cluster (left) and budget cluster (right). The seam between them is
  # a space-gap in split mode, the literal " | " in fallback. Width math uses
  # `length` (codepoint count) because every field is single-cell text with no
  # ANSI codes — if colored output is ever added, strip ANSI before measuring.
  | ( ((if $dir != "" then [$dir] else [] end) + [$model, $ctx]) | join(" | ") ) as $left
  | ( ((if $fh != null then [$fh] else [] end)
       + (if $wk != null then [$wk] else [] end)
       + (if $cost != null then [$cost] else [] end)) | join(" | ") ) as $right
  | ($left  | length) as $L
  | ($right | length) as $R
  | (($cols | tonumber?) // 0) as $c   # COLUMNS; 0 when empty/non-numeric (old CC)
  # Flush right to column $c-1 (the last cell is reserved: writing into it
  # triggers a phantom wrap on some terminals). If CC's `padding` setting is set
  # we cannot see that indent, so a split line may clip a few columns — accepted.
  | if   $R == 0 then $left
    elif $L == 0 then
         (if ($c > 0 and $R <= ($c - 1)) then (spaces(($c - 1) - $R) + $right) else $right end)
    elif ($c > 0 and ($L + 2 + $R) <= ($c - 1)) then
         ($left + spaces(($c - 1) - $L - $R) + $right)
    else ($left + " | " + $right)
    end
```

- [ ] **Step 5: Pass `COLUMNS` into jq from `render()`**

Change:
```bash
render() { jq -r --argjson now "$1" "$PROG"; }
```
to:
```bash
render() { jq -r --argjson now "$1" --arg cols "${COLUMNS:-}" "$PROG"; }
```

(The live path `printf '%s' "$raw" | render "$now"` needs no change — `render` reads `COLUMNS` from the environment Claude Code sets.)

- [ ] **Step 6: Run the suite — all sh cases pass**

Run: `bash tests/run.sh`
Expected: `pass=6 fail=0`.

- [ ] **Step 7: Commit**

```bash
git add statusline.sh tests/run.sh
git commit -m "feat: right-align the budget cluster in statusline.sh"
```

---

## Task 3: Mirror the split in `statusline.ps1`

`pwsh` is not on this dev box, so the runner can't exercise PowerShell locally — the parity check runs wherever `pwsh` exists (CI). Implement the exact mirror; verify by reading against the jq logic.

**Files:**
- Modify: `statusline.ps1` (`Render-Status` tail)

- [ ] **Step 1: Replace the `$parts` tail of `Render-Status`**

Replace this current block (from `$parts = @()` through `return ($parts -join ' | ')`):

```powershell
    $parts = @()
    if ($dirStr) { $parts += $dirStr }
    $parts += $modelStr
    $parts += $ctxStr
    $fhStr = Format-RateTuple $obj.rate_limits.five_hour  5   '5h' $nowEpoch
    $wkStr = Format-RateTuple $obj.rate_limits.seven_day  168 '7d' $nowEpoch
    if ($fhStr) { $parts += $fhStr }
    if ($wkStr) { $parts += $wkStr }
    if ($costStr) { $parts += $costStr }

    return ($parts -join ' | ')
```

with:

```powershell
    # Identity cluster (left); budget cluster (right). Mirrors statusline.sh.
    # .Length is the cell count because every field is single-cell BMP text with
    # no ANSI codes — if colored output is ever added, strip ANSI before measuring.
    $leftParts = @()
    if ($dirStr) { $leftParts += $dirStr }
    $leftParts += $modelStr
    $leftParts += $ctxStr
    $left = $leftParts -join ' | '

    $fhStr = Format-RateTuple $obj.rate_limits.five_hour  5   '5h' $nowEpoch
    $wkStr = Format-RateTuple $obj.rate_limits.seven_day  168 '7d' $nowEpoch
    $rightParts = @()
    if ($fhStr)   { $rightParts += $fhStr }
    if ($wkStr)   { $rightParts += $wkStr }
    if ($costStr) { $rightParts += $costStr }
    $right = $rightParts -join ' | '

    $cols = 0
    if ($env:COLUMNS -match '^\d+$') { $cols = [int]$env:COLUMNS }

    # Flush right to column $cols-1 (reserve the last cell against phantom wrap).
    # CC's `padding` setting (an indent we cannot read) may clip a split line by a
    # few columns — accepted limitation.
    if ($right.Length -eq 0) { return $left }
    if ($left.Length -eq 0) {
        if ($cols -gt 0 -and $right.Length -le ($cols - 1)) {
            return (' ' * (($cols - 1) - $right.Length)) + $right
        }
        return $right
    }
    if ($cols -gt 0 -and (($left.Length + 2 + $right.Length) -le ($cols - 1))) {
        $pad = ($cols - 1) - $left.Length - $right.Length
        return $left + (' ' * $pad) + $right
    }
    return $left + ' | ' + $right
```

- [ ] **Step 2: Lint-check by eye against the jq logic**

Confirm line-by-line that the four branches match Task 2 Step 4: empty-right → `$left`; empty-left → flush-or-bare; fits → `$left + pad + $right` with `pad = (cols-1)-L-R`; else → `$left + ' | ' + $right`. Confirm `' ' * 0` is safe (PowerShell yields `''`) and that the guards keep `$pad` ≥ 0.

- [ ] **Step 3: If `pwsh` is available, run the suite; otherwise note the skip**

Run: `bash tests/run.sh`
Expected with pwsh: `pass=12 fail=0` (6 cases × 2 renderers). Expected without pwsh: `pass=6 fail=0` plus the skip notice — PowerShell parity is enforced in CI.

- [ ] **Step 4: Commit**

```bash
git add statusline.ps1
git commit -m "feat: right-align the budget cluster in statusline.ps1 (parity)"
```

---

## Task 4: Update `--demo` in both scripts

The demo must feed a fixed width so it renders the split (otherwise it silently falls back and the documented examples drift). `COLUMNS=100` gives a legible gap (at 90 the clusters nearly touch). Drop the inline `%-13s` label — it would offset the right edge — and print each label on its own line.

**Files:**
- Modify: `statusline.sh` (`--demo` block)
- Modify: `statusline.ps1` (`--demo` block)

- [ ] **Step 1: Rewrite the `statusline.sh` demo block**

Replace the current `demo_row()` definition and its three calls (keep the surrounding `if [ "${1:-}" = "--demo" ]; then` / `exit 0` and the leading comment) with:

```bash
  export COLUMNS="${COLUMNS:-100}"   # fixed width so the split renders; honor a caller override
  demo_row() { # $1 label  $2 used5h  $3 secLeft5h
    printf '# %s\n' "$1"
    printf '{"cwd":"/home/you/code/my-project","model":{"id":"claude-opus-4-7"},"effort":{"level":"high"},"context_window":{"total_input_tokens":12000,"context_window_size":200000},"rate_limits":{"five_hour":{"used_percentage":%s,"resets_at":%s},"seven_day":{"used_percentage":64,"resets_at":175392}},"cost":{"total_cost_usd":1.23}}' \
      "$2" "$3" | render 0
  }
  demo_row "conserving"   20 4500    # 20% spent, 75% of the window gone — marker deep inside the fill
  demo_row "on pace"      50 9000    # 50% spent, 50% gone — marker rides the leading edge
  demo_row "overspending" 75 13500   # 75% spent, 25% gone — marker stranded out in the empty
```

- [ ] **Step 2: Run the sh demo and eyeball the split**

Run: `bash statusline.sh --demo`
Expected: three `# label` lines, each followed by a status line whose budget cluster (`5h:… | 7d:… | $1.23`) is flushed right with a clear gap after `12k/200k`. The three budget clusters align on their right edge.

- [ ] **Step 3: Rewrite the `statusline.ps1` demo block**

Replace the current `Demo-Row` function and its three `Write-Output` calls with:

```powershell
    $env:COLUMNS = if ($env:COLUMNS) { $env:COLUMNS } else { '100' }
    function Demo-Row($label, $used5h, $secLeft5h) {
        $json = '{"cwd":"/home/you/code/my-project","model":{"id":"claude-opus-4-7"},"effort":{"level":"high"},"context_window":{"total_input_tokens":12000,"context_window_size":200000},"rate_limits":{"five_hour":{"used_percentage":' + $used5h + ',"resets_at":' + $secLeft5h + '},"seven_day":{"used_percentage":64,"resets_at":175392}},"cost":{"total_cost_usd":1.23}}'
        $o = $json | ConvertFrom-Json
        return "# $label`n" + (Render-Status $o 0)
    }
    Write-Output (Demo-Row 'conserving'   20 4500)    # 20% spent, 75% of the window gone — marker deep inside the fill
    Write-Output (Demo-Row 'on pace'      50 9000)    # 50% spent, 50% gone — marker rides the leading edge
    Write-Output (Demo-Row 'overspending' 75 13500)   # 75% spent, 25% gone — marker stranded out in the empty
```

- [ ] **Step 4: Commit**

```bash
git add statusline.sh statusline.ps1
git commit -m "feat: --demo renders the right-aligned split at a fixed width"
```

---

## Task 5: Update the README

Show the right-aligned default in the intro and name the behavior once. Keep edits minimal — README copy is value-prose and will get a section review; do not rewrite untouched prose.

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Update the intro example (line ~6)**

Replace:
```
code/my-project | opus-4-7/high | 12k/200k | 5h:80% [█○████░░] | 7d:36% [█████○░░] | $1.23
```
with (budget cluster flushed right):
```
code/my-project | opus-4-7/high | 12k/200k        5h:80% [█○████░░] | 7d:36% [█████○░░] | $1.23
```

- [ ] **Step 2: Name the right-edge behavior in the description (lines ~9–10)**

Replace:
```
Directory, model and reasoning effort, context used, your two usage windows, and session
cost. The usage windows are the part worth learning — see below.
```
with:
```
Directory, model and reasoning effort, and context used sit on the left; your two usage
windows and session cost sit at the right edge, so the budget read lands in the same place
however long the path on the left runs (they fold back inline on a narrow terminal). The
usage windows are the part worth learning — see below.
```

- [ ] **Step 3: Verify the README renders sensibly**

Run: `sed -n '1,12p' README.md`
Expected: the intro example shows the gap before `5h:`, and the description names the left/right split.

- [ ] **Step 4: Commit**

```bash
git add README.md
git commit -m "docs: show the right-aligned default in the README intro"
```

---

## Task 6: Final verification and draft PR

**Files:** none (verification + PR)

- [ ] **Step 1: Full suite green**

Run: `bash tests/run.sh`
Expected: `fail=0` (sh on this box; sh+ps in CI).

- [ ] **Step 2: Confirm the live (non-demo) path still falls back when narrow**

Run:
```bash
printf '{"cwd":"/home/you/code/my-project","model":{"id":"claude-opus-4-7"},"effort":{"level":"high"},"context_window":{"total_input_tokens":12000,"context_window_size":200000},"rate_limits":{"five_hour":{"used_percentage":20,"resets_at":4500},"seven_day":{"used_percentage":64,"resets_at":175392}},"cost":{"total_cost_usd":1.23}}' | COLUMNS=80 CLAUDE_STATUSLINE_NOW=0 bash statusline.sh
```
Expected: the today's-format `|`-join (no right-alignment) — fallback confirmed.

- [ ] **Step 3: Record the `COLUMNS` empirical finding**

The spec's open verification item — that a non-interactive bash sees the `COLUMNS` Claude Code sets — was confirmed during planning (`COLUMNS=120 bash -c 'echo $COLUMNS'` → `120`, and the runner exercises the env-var read on every case). Note this in the PR description so the spec's verification item is closed.

- [ ] **Step 4: Open the draft PR**

Use the `sdlc:pr-review-prep` flow to create a **draft** PR from `feat/right-align-usage`. Summary points for the description: right-aligned budget cluster with width-driven fit-check and byte-identical fallback; shared test runner pinning both renderers; `COLUMNS` read confirmed; documented limitations (`padding` offset, threshold flicker).

---

## Notes for the implementer

- **Parity is the rule.** Any change to the split/fallback logic in one script must land in the other in the same task, and the shared runner is the proof. Do not let the two drift.
- **No new dependency.** `statusline.ps1` stays pure PowerShell; `statusline.sh` stays bash+jq. Unifying them into one jq core was considered and deliberately deferred (it would make jq a Windows dependency).
- **Width math assumes single-cell, uncolored text.** The guard comments added in Tasks 2 and 3 are load-bearing — honor them if color is ever introduced.
