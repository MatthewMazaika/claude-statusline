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

# --- Split cases (right-aligned; fail until statusline.sh implements it) ---
run_case "wide-split"       120 0 "$J_FULL"  "$(split "$LEFT" 32 "$RFULL")"
run_case "margin-1col"       90 0 "$J_FULL"  "$(split "$LEFT" 2  "$RFULL")"
run_case "bare-window-split" 120 0 "$J_BARE" "$(split "$LEFT" 54 "$RBARE")"

# --- Fallback / characterization cases (green against today's renderer) ---
run_case "narrow-fallback"   80 0 "$J_FULL"   "$LEFT | $RFULL"
run_case "nocols-fallback"   "" 0 "$J_FULL"   "$LEFT | $RFULL"
run_case "empty-right"      120 0 "$J_NORATE" "$LEFT"

echo "----"
echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
