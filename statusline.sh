#!/usr/bin/env bash
# Claude Code status line (Linux/macOS). Requires jq >= 1.5.
set -u

raw="$(cat)"
[ -z "${raw//[$' \t\r\n']/}" ] && exit 0

now="${CLAUDE_STATUSLINE_NOW:-$(date +%s)}"

printf '%s' "$raw" | jq -r --argjson now "$now" '
  # round half away from zero (matches PowerShell AwayFromZero)
  def rnd: if . >= 0 then (. + 0.5 | floor) else (. - 0.5 | ceil) end;

  def fmt:
    ( . // 0 ) as $n
    | if   $n >= 1000000 then ( ($n / 100000 | rnd) ) as $t
                              | "\($t / 10 | floor).\($t % 10)M"
      elif $n >= 1000    then "\($n / 1000 | rnd)k"
      else "\($n | floor)" end;

  def ratetuple($w; $hours; $label):
    if ($w == null) or ($w.used_percentage == null) then null
    else
      (100 - $w.used_percentage | ceil) as $remaining
      # resets_at may be absent/null (the rate_limits object and each window are
      # omitted until the first API response) or point at a just-passed boundary.
      # Only compute a pace estimate when it is a usable future timestamp;
      # otherwise show the bare remaining %. Guards both the bogus "~0%" and the
      # jq subtraction error that null/absent resets_at would otherwise throw.
      | (($w.resets_at // 0) - $now) as $secLeft
      | if $secLeft <= 0 then "\($label):\($remaining)%"
        else
          ($hours * 3600) as $windowSecs
          | ($windowSecs - $secLeft) as $elapsed
          | ( [0, ( [100, ($elapsed / $windowSecs * 100)] | min )] | max ) as $expUsed
          | (100 - $expUsed | rnd) as $expRemaining
          | ( ($remaining - $expRemaining) | if . < 0 then -. else . end ) as $delta
          | if $delta >= 3 then "\($label):\($remaining)%~\($expRemaining)%"
            else "\($label):\($remaining)%" end
        end
    end;

  ( ((.cwd // "") | gsub("\\\\"; "/") | split("/") | map(select(. != ""))) ) as $segs
  | ($segs | length) as $n
  | ( if   $n >= 2 then "\($segs[$n-2])/\($segs[$n-1])"
      elif $n == 1 then $segs[0]
      else "" end ) as $dir
  | ( (.model.id // "") | sub("^claude-"; "") ) as $model
  | ( (.context_window.total_input_tokens | fmt) + "/" + (.context_window.context_window_size | fmt) ) as $ctx
  | ratetuple(.rate_limits.five_hour; 5;   "5h") as $fh
  | ratetuple(.rate_limits.seven_day; 168; "1W") as $wk
  | ( (if $dir != "" then [$dir] else [] end) + [$model, $ctx]
      + (if $fh != null then [$fh] else [] end)
      + (if $wk != null then [$wk] else [] end) )
  | join(" | ")
'
