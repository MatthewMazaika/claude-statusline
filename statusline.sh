#!/usr/bin/env bash
# Claude Code status line (Linux/macOS). Requires jq >= 1.5.
#
# Usage:
#   <claude json> | statusline.sh    # normal: render one status line from stdin
#   statusline.sh --demo             # print the three pace states (see README)
set -u

# ── Cost-baseline state ────────────────────────────────────────────────────────
# /clear creates a new session_id (its SessionStart hook fires with the
# "SessionStart:clear" event name). cost.total_cost_usd, however, is a
# terminal-process-level accumulator that does not reset when the session_id
# changes. We persist the last-seen session_id and cost baseline so the
# displayed cost reflects only the current conversation.
_script="${BASH_SOURCE[0]:-}"
_dir="$([ -n "$_script" ] && cd "$(dirname "$_script")" 2>/dev/null && pwd || true)"
_state_file="${CLAUDE_STATUSLINE_STATE_FILE:-${_dir:+$_dir/statusline-state.json}}"
_state_file="${_state_file:-$HOME/.claude/statusline-state.json}"

_write_state() { # sid baseline
  printf '{"sessionId":"%s","costBaseline":%s}\n' "$1" "$2" \
    > "$_state_file" 2>/dev/null || true
}

# jq program kept in a variable so --demo can drive the real renderer with
# synthetic payloads — the examples can never drift from live output.
PROG='
  # round half away from zero (matches PowerShell AwayFromZero)
  def rnd: if . >= 0 then (. + 0.5 | floor) else (. - 0.5 | ceil) end;

  def fmt:
    ( . // 0 ) as $n
    | if   $n >= 1000000 then ( ($n / 100000 | rnd) ) as $t
                              | "\($t / 10 | floor).\($t % 10)M"
      elif $n >= 1000    then "\($n / 1000 | rnd)k"
      else "\($n | floor)" end;

  def fmtcost:
    ( . * 100 + 0.5 | floor ) as $cents
    | ($cents / 100 | floor | tostring) as $whole
    | (($cents % 100) | tostring) as $frac
    | "$\($whole).\(if ($frac | length) == 1 then "0\($frac)" else $frac end)";

  # repeat a space k times; the jq " " * n operator yields null for n <= 0, guard it.
  def spaces($k): if $k > 0 then (" " * $k) else "" end;

  # One bar carries both moving numbers on a shared 0-100% axis:
  #   fill (elapsed time) = how far through the window you are; its leading edge is "now"
  #   marker "○" (budget spent) = how far you have drawn the budget down
  # Marker behind the now-edge = banking budget; marker past it = overspending.
  # █ = full block (elapsed), ░ = light shade (still ahead of you).
  def gauge($spent; $elapsed; $n):
    ([0, ([$n - 1, ($spent / 100 * $n | floor)] | min)] | max) as $mark
    | [ range(0; $n) as $i
        | (($i + 0.5) / $n * 100) as $mid
        | if   $i == $mark        then "○"
          elif $mid <= $elapsed   then "█"
          else                         "░" end ]
    | "[" + add + "]";

  def ratetuple($w; $hours; $label):
    if ($w == null) or ($w.used_percentage == null) then null
    else
      ($w.used_percentage) as $spent
      | (100 - $spent | ceil) as $remaining
      # resets_at may be absent/null (the rate_limits object and each window are
      # omitted until the first API response) or point at a just-passed boundary.
      # Only draw the gauge when resets_at is a usable future timestamp; otherwise
      # show the bare remaining % (no clock data to pace against). Guards both the
      # bogus all-empty bar and the jq subtraction error null/absent would throw.
      | (($w.resets_at // 0) - $now) as $secLeft
      | if $secLeft <= 0 then "\($label):\($remaining)%"
        else
          ($hours * 3600) as $windowSecs
          | ($windowSecs - $secLeft) as $elapsedSecs
          | ( [0, ( [100, ($elapsedSecs / $windowSecs * 100)] | min )] | max ) as $elapsed
          | "\($label):\($remaining)% \(gauge($spent; $elapsed; 8))"
        end
    end;

  ( ((.cwd // "") | gsub("\\\\"; "/") | split("/") | map(select(. != ""))) ) as $segs
  | ($segs | length) as $n
  | ( if   $n >= 2 then "\($segs[$n-2])/\($segs[$n-1])"
      elif $n == 1 then $segs[0]
      else "" end ) as $dir
  | ( (.model.id // "") | sub("^claude-"; "") ) as $modelId
  | ( .effort.level // "" ) as $effort
  | ( if $effort != "" then "\($modelId)/\($effort)" else $modelId end ) as $model
  | ( (.context_window.total_input_tokens | fmt) + "/" + (.context_window.context_window_size | fmt) ) as $ctx
  | ratetuple(.rate_limits.five_hour; 5;   "5h") as $fh
  | ratetuple(.rate_limits.seven_day; 168; "7d") as $wk
  | ( ((.cost.total_cost_usd // 0)) as $c
      | if (($c * 100 + 0.5) | floor) > 0
        then ($c | fmtcost)
        else null end ) as $cost
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
  # Claude Code renders the status line with a 2-column built-in left indent that
  # is NOT reflected in COLUMNS (measured on CC 2.1.160; undocumented). Reserving
  # 4 flushes the budget cluster to a 2-column right inset that mirrors that left
  # indent — a symmetric layout, and safely clear of the last cell (writing it
  # triggers a phantom wrap). Reserving only 1 truncated cost in testing. (A
  # user-set `padding` adds further indent we cannot read, so a split may still
  # clip — accepted.)
  | ($c - 4) as $edge
  | if   $R == 0 then $left
    elif $L == 0 then
         (if ($c > 0 and $R <= $edge) then (spaces($edge - $R) + $right) else $right end)
    elif ($c > 0 and ($L + 2 + $R) <= $edge) then
         ($left + spaces($edge - $L - $R) + $right)
    else ($left + " | " + $right)
    end
'

render() { jq -r --argjson now "$1" --arg cols "${COLUMNS:-}" "$PROG"; }

if [ "${1:-}" = "--demo" ]; then
  # now=0, so resets_at == seconds left in the window. 5h=18000s, 7d=604800s.
  # The 7d window is held identical across rows so the eye tracks the 5h gauge.
  export COLUMNS="${COLUMNS:-100}"   # fixed width so the split renders; honor a caller override
  demo_row() { # $1 label  $2 used5h  $3 secLeft5h
    printf '# %s\n' "$1"
    printf '{"cwd":"/home/you/code/my-project","model":{"id":"claude-opus-4-7"},"effort":{"level":"high"},"context_window":{"total_input_tokens":12000,"context_window_size":200000},"rate_limits":{"five_hour":{"used_percentage":%s,"resets_at":%s},"seven_day":{"used_percentage":64,"resets_at":175392}},"cost":{"total_cost_usd":1.23}}' \
      "$2" "$3" | render 0
  }
  demo_row "conserving"   20 4500    # 20% spent, 75% of the window gone — marker deep inside the fill
  demo_row "on pace"      50 9000    # 50% spent, 50% gone — marker rides the leading edge
  demo_row "overspending" 75 13500   # 75% spent, 25% gone — marker stranded out in the empty
  exit 0
fi

raw="$(cat)"
[ -z "${raw//[$' \t\r\n']/}" ] && exit 0
now="${CLAUDE_STATUSLINE_NOW:-$(date +%s)}"

# Adjust cost.total_cost_usd to reflect only the current conversation.
# /clear assigns a new session_id; when we see a new id, snapshot the
# current cumulative cost as the new baseline.
_rawcost="$(printf '%s' "$raw" | jq -r 'if .cost.total_cost_usd != null then .cost.total_cost_usd else empty end' 2>/dev/null || true)"
if [ -n "$_rawcost" ]; then
  _sid="$(printf '%s' "$raw" | jq -r '.session_id // empty' 2>/dev/null || true)"
  if [ -f "$_state_file" ] && [ -s "$_state_file" ]; then
    _prev_sid="$(jq -r '.sessionId // ""' "$_state_file" 2>/dev/null || true)"
    _baseline="$(jq -r '.costBaseline // 0' "$_state_file" 2>/dev/null || printf '0')"
  else
    _prev_sid="" _baseline="0"
  fi
  if [ "${_prev_sid}" != "${_sid}" ]; then _baseline="$_rawcost"; fi
  _write_state "${_sid}" "${_baseline}"
  raw="$(printf '%s' "$raw" | jq --argjson b "${_baseline:-0}" \
    'if .cost.total_cost_usd != null then .cost.total_cost_usd = ([0, (.cost.total_cost_usd - $b)] | max) else . end')"
fi

printf '%s' "$raw" | render "$now"
