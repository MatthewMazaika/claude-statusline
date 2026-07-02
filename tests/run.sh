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

# Disable auto-update: these scripts run straight from the repo checkout, and
# several cases below don't pin CLAUDE_STATUSLINE_NOW (real wall-clock "now"
# with no prior state file reads as "due"). Without this, a test run can spawn
# a real background fetch that overwrites the checked-out statusline.sh/.ps1
# with whatever is currently published at the v2 tag.
export CLAUDE_STATUSLINE_NO_UPDATE=1

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

_cost_check() { # label  got  expected_substr
  local label="$1" got="$2" expected="$3"
  if [ -z "$expected" ]; then
    if printf '%s' "$got" | grep -qE '\$[0-9]'; then
      fail=$((fail+1)); printf 'FAIL [%s] %s\n  want: no cost token\n  got:  |%s|\n' "$label" "$name" "$got"
    else pass=$((pass+1)); fi
  else
    if printf '%s' "$got" | grep -qF "$expected"; then
      pass=$((pass+1))
    else
      fail=$((fail+1)); printf 'FAIL [%s] %s\n  want output containing |%s|\n  got:  |%s|\n' "$label" "$name" "$expected" "$got"
    fi
  fi
}

run_cost_case() { # name  state_json  json  expected_substr ('' = expect no cost token)
  local name="$1" state="$2" json="$3" expected="$4" got
  printf '%s' "$state" > "$CLAUDE_STATUSLINE_STATE_FILE"
  got="$(printf '%s' "$json" | bash "$sh_script")"; _cost_check sh "$got" "$expected"
  if [ "$have_pwsh" = 1 ]; then
    printf '%s' "$state" > "$CLAUDE_STATUSLINE_STATE_FILE"
    got="$(printf '%s' "$json" | pwsh -NoProfile -File "$ps_script")"; _cost_check ps "$got" "$expected"
  fi
}

# Minimal JSONs for cost-state tests (no rate limits, small ctx keeps output short)
J_A123='{"session_id":"sess-A","context_window":{"total_input_tokens":100,"context_window_size":200000},"cost":{"total_cost_usd":1.23}}'
J_B000='{"session_id":"sess-B","context_window":{"total_input_tokens":100,"context_window_size":200000},"cost":{"total_cost_usd":1.23}}'
J_B027='{"session_id":"sess-B","context_window":{"total_input_tokens":100,"context_window_size":200000},"cost":{"total_cost_usd":1.50}}'

# Within the same session: full accumulated cost is shown
run_cost_case "within-session"        '{"sessionId":"sess-A","costBaseline":0}'    "$J_A123" '$1.23'
# /clear (new session_id, same terminal total): baseline resets to rawCost → $0 hidden
run_cost_case "clear-resets-display"  '{"sessionId":"sess-A","costBaseline":0}'    "$J_B000" ''
# After /clear, as the new session accumulates cost: delta is shown
run_cost_case "post-clear-accumulate" '{"sessionId":"sess-B","costBaseline":1.23}' "$J_B027" '$0.27'

# ── Auto-update contract tests ─────────────────────────────────────────────────
# Exercise `--update-worker` directly (never the throttle/spawn path — that's
# just timestamp arithmetic and a real fire-and-forget background process,
# not worth making async/flaky in CI). Both curl and Invoke-WebRequest accept
# file:// URIs, so these run fully offline and deterministically. Each case
# operates on a throwaway copy of the script in its own scratch dir — never
# the tracked file — because this exact mechanism already overwrote the
# checked-out statusline.sh once during this feature's own development.

update_test_dir="$(mktemp -d)"
trap 'rm -f "$CLAUDE_STATUSLINE_STATE_FILE"; rm -rf "$update_test_dir"' EXIT

# file:// URI from an absolute path. mingw curl (Windows/git-bash dev boxes)
# needs a Windows-style C:/... path in the URI even though bash itself works
# in POSIX-style /tmp/... paths; cygpath bridges that when present. On real
# POSIX systems (CI's ubuntu-latest) there is no cygpath and the path is
# already URI-ready as-is.
_file_uri() { # abs_path
  if command -v cygpath >/dev/null 2>&1; then
    printf 'file:///%s' "$(cygpath -m "$1")"
  else
    printf 'file://%s' "$1"
  fi
}

_sha() { sha256sum "$1" 2>/dev/null | cut -d' ' -f1; }

_check_update_case() { # label  dir  copy  before  after  expect(replace|reject)
  local label="$1" dir="$2" copy="$3" before="$4" after="$5" expect="$6" extra
  if [ "$expect" = "replace" ] && [ "$after" = "$before" ]; then
    fail=$((fail+1)); printf 'FAIL [update] %s: expected replace, file unchanged\n' "$label"
  elif [ "$expect" = "reject" ] && [ "$after" != "$before" ]; then
    fail=$((fail+1)); printf 'FAIL [update] %s: expected reject, file WAS changed\n' "$label"
  else
    pass=$((pass+1))
  fi
  extra="$(find "$dir" -mindepth 1 ! -name "$(basename "$copy")" | wc -l)"
  if [ "$extra" -gt 0 ]; then
    fail=$((fail+1)); printf 'FAIL [update] %s: leftover temp file(s) in %s\n' "$label" "$dir"
  fi
}

run_update_case_sh() { # label  fixture_uri  expect(replace|reject)
  local label="$1" uri="$2" expect="$3" dir copy before after
  dir="$(mktemp -d "$update_test_dir/case.XXXXXX")"
  copy="$dir/statusline.sh"
  cp "$sh_script" "$copy"
  before="$(_sha "$copy")"
  CLAUDE_STATUSLINE_UPDATE_URL="$uri" bash "$copy" --update-worker >/dev/null 2>&1
  after="$(_sha "$copy")"
  _check_update_case "sh:$label" "$dir" "$copy" "$before" "$after" "$expect"
}

run_update_case_ps() { # label  fixture_uri  expect(replace|reject)
  [ "$have_pwsh" = 1 ] || return 0
  local label="$1" uri="$2" expect="$3" dir copy before after
  dir="$(mktemp -d "$update_test_dir/pscase.XXXXXX")"
  copy="$dir/statusline.ps1"
  cp "$ps_script" "$copy"
  before="$(_sha "$copy")"
  CLAUDE_STATUSLINE_UPDATE_URL="$uri" pwsh -NoProfile -File "$copy" --update-worker >/dev/null 2>&1
  after="$(_sha "$copy")"
  _check_update_case "ps:$label" "$dir" "$copy" "$before" "$after" "$expect"
}

# Fixtures, generated fresh each run so "identical" always matches whatever
# the tracked scripts currently contain.
sh_fixture_new="$update_test_dir/new.sh"
{ printf '#!/usr/bin/env bash\n# FIXTURE-CONTRACT-TEST-NEW-VERSION\n'; printf 'x%.0s' $(seq 1 220); printf '\n'; } > "$sh_fixture_new"
sh_fixture_garbage="$update_test_dir/garbage.sh"
printf 'Not Found' > "$sh_fixture_garbage"
sh_fixture_identical="$update_test_dir/identical.sh"
cp "$sh_script" "$sh_fixture_identical"

ps_fixture_new="$update_test_dir/new.ps1"
{ printf '# Claude Code status line (Windows / PowerShell).\n# FIXTURE-CONTRACT-TEST-NEW-VERSION\n'; printf 'x%.0s' $(seq 1 220); printf '\n'; } > "$ps_fixture_new"
ps_fixture_garbage="$update_test_dir/garbage.ps1"
printf 'Not Found' > "$ps_fixture_garbage"
ps_fixture_identical="$update_test_dir/identical.ps1"
cp "$ps_script" "$ps_fixture_identical"

offline_uri="$(_file_uri "$update_test_dir/does-not-exist-$$.sh")"

run_update_case_sh "replace-on-newer-fixture" "$(_file_uri "$sh_fixture_new")"      "replace"
run_update_case_sh "noop-on-identical"        "$(_file_uri "$sh_fixture_identical")" "reject"
run_update_case_sh "reject-garbage-response"  "$(_file_uri "$sh_fixture_garbage")"   "reject"
run_update_case_sh "reject-unreachable-url"   "$offline_uri"                        "reject"

run_update_case_ps "replace-on-newer-fixture" "$(_file_uri "$ps_fixture_new")"      "replace"
run_update_case_ps "noop-on-identical"        "$(_file_uri "$ps_fixture_identical")" "reject"
run_update_case_ps "reject-wrong-header"      "$(_file_uri "$ps_fixture_garbage")"   "reject"
run_update_case_ps "reject-unreachable-url"   "$offline_uri"                        "reject"

echo "----"
echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
