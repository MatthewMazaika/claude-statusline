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

# Isolate cost state so the live state file can't contaminate test output.
export CLAUDE_STATUSLINE_STATE_FILE
CLAUDE_STATUSLINE_STATE_FILE="$(mktemp)"
trap 'rm -f "$CLAUDE_STATUSLINE_STATE_FILE"' EXIT

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

# --- Split cases (right-aligned) ---
# The budget cluster flushes to COLUMNS-4: CC indents the status line 3 columns
# (built-in, not in COLUMNS) and keeps the last column blank, so usable = cols-4.
# Gap math (audit): pad = (cols-4) - L - R, with L=42, Rfull=45, Rbare=23.
run_case "wide-split"        120 0 "$J_FULL"  "$(split "$LEFT" 29 "$RFULL")"  # 116-42-45
run_case "margin-fit"         93 0 "$J_FULL"  "$(split "$LEFT" 2  "$RFULL")"  # 89-42-45, just fits
run_case "margin-just-under"  92 0 "$J_FULL"  "$LEFT | $RFULL"                # 89 > 88 -> fallback
run_case "bare-window-split" 120 0 "$J_BARE"  "$(split "$LEFT" 51 "$RBARE")"  # 116-42-23

# --- Fallback / characterization cases (green against today's renderer) ---
run_case "narrow-fallback"   80 0 "$J_FULL"   "$LEFT | $RFULL"
run_case "nocols-fallback"   "" 0 "$J_FULL"   "$LEFT | $RFULL"
run_case "empty-right"      120 0 "$J_NORATE" "$LEFT"

# ── Cost-reset tests (PowerShell only — bash statusline.sh omits cost) ────────
# These exercise the state-file logic that resets cost on /clear.
# /clear creates a new session_id (Claude Code fires SessionStart:clear and
# assigns a fresh UUID); cost.total_cost_usd is a terminal-process accumulator
# that does NOT reset. We snapshot the accumulated cost as the new baseline so
# the displayed value reflects only the current conversation.

run_cost_ps() { # name  state_json  json  expected_substr ('' = expect no cost token)
  [ "$have_pwsh" = 1 ] || return
  local name="$1" state="$2" json="$3" expected="$4"
  printf '%s' "$state" > "$CLAUDE_STATUSLINE_STATE_FILE"
  local got
  got="$(printf '%s' "$json" | pwsh -NoProfile -File "$ps_script")"
  if [ -z "$expected" ]; then
    if printf '%s' "$got" | grep -qE '\$[0-9]'; then
      fail=$((fail+1))
      printf 'FAIL [ps] %s\n  want: no cost token\n  got:  |%s|\n' "$name" "$got"
    else
      pass=$((pass+1))
    fi
  else
    if printf '%s' "$got" | grep -qF "$expected"; then
      pass=$((pass+1))
    else
      fail=$((fail+1))
      printf 'FAIL [ps] %s\n  want output containing |%s|\n  got:  |%s|\n' "$name" "$expected" "$got"
    fi
  fi
}

# Minimal JSONs for cost-state tests (no rate limits, small ctx keeps output short)
J_A123='{"session_id":"sess-A","context_window":{"total_input_tokens":100,"context_window_size":200000},"cost":{"total_cost_usd":1.23}}'
J_B000='{"session_id":"sess-B","context_window":{"total_input_tokens":100,"context_window_size":200000},"cost":{"total_cost_usd":1.23}}'
J_B027='{"session_id":"sess-B","context_window":{"total_input_tokens":100,"context_window_size":200000},"cost":{"total_cost_usd":1.50}}'

# Within the same session: full accumulated cost is shown
run_cost_ps "within-session"        '{"sessionId":"sess-A","costBaseline":0}'    "$J_A123" '$1.23'
# /clear (new session_id, same terminal total): baseline resets to rawCost → $0 hidden
run_cost_ps "clear-resets-display"  '{"sessionId":"sess-A","costBaseline":0}'    "$J_B000" ''
# After /clear, as the new session accumulates cost: delta is shown
run_cost_ps "post-clear-accumulate" '{"sessionId":"sess-B","costBaseline":1.23}' "$J_B027" '$0.27'

echo "----"
echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
