# Claude Code status line (Windows / PowerShell).
#
# Usage:
#   <claude json> | statusline.ps1    # normal: render one status line from stdin
#   statusline.ps1 --demo             # print the three pace states (see README)
$ErrorActionPreference = 'Continue'

# Block-drawing glyphs need a UTF-8 console or they render as mojibake.
try { [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new() } catch {}

# token formatter (round half away from zero for cross-platform parity)
function Format-Tokens($n) {
    $v = [double]$n
    if ($v -ge 1000000) { return ('{0:0.0}M' -f [math]::Round($v / 1000000, 1, [MidpointRounding]::AwayFromZero)) }
    if ($v -ge 1000)    { return ('{0}k'     -f [int][math]::Round($v / 1000, 0, [MidpointRounding]::AwayFromZero)) }
    return "$([int]$v)"
}

# One bar carries both moving numbers on a shared 0-100% axis:
#   fill (elapsed time) = how far through the window you are; its leading edge is "now"
#   marker "○" (budget spent) = how far you have drawn the budget down
# Marker behind the now-edge = banking budget; marker past it = overspending.
function Format-Gauge($spentPct, $elapsedPct, $n) {
    $full  = [char]0x2588   # full block  (elapsed)
    $light = [char]0x2591   # light shade (still ahead of you)
    $mk    = [char]0x25CB   # ring marker (budget spent)
    $mark = [int][math]::Floor($spentPct / 100.0 * $n)
    if ($mark -gt ($n - 1)) { $mark = $n - 1 }
    if ($mark -lt 0)        { $mark = 0 }
    $bar = ''
    for ($i = 0; $i -lt $n; $i++) {
        $mid = ($i + 0.5) / $n * 100
        if     ($i -eq $mark)      { $bar += $mk }
        elseif ($mid -le $elapsedPct) { $bar += $full }
        else                       { $bar += $light }
    }
    return "[$bar]"
}

# rate-limit field: label:remaining% [gauge]
function Format-RateTuple($window, $windowHours, $label, $nowEpoch) {
    if ($null -eq $window -or $null -eq $window.used_percentage) { return $null }
    $spent     = [double]$window.used_percentage
    $remaining = [int][math]::Ceiling(100 - $spent)
    # resets_at may be absent/null (the rate_limits object and each window are
    # omitted until the first API response) or point at a just-passed boundary.
    # Only draw the gauge when resets_at is a usable future timestamp; otherwise
    # show the bare remaining % (no clock data to pace against).
    $resetsAt  = if ($null -ne $window.resets_at) { [int64]$window.resets_at } else { 0 }
    $secLeft   = $resetsAt - $nowEpoch
    if ($secLeft -le 0) {
        return '{0}:{1}%' -f $label, $remaining
    }
    $windowSecs  = $windowHours * 3600.0
    $elapsedSecs = $windowSecs - $secLeft
    $elapsed     = [math]::Max(0, [math]::Min(100, ($elapsedSecs / $windowSecs) * 100))
    return '{0}:{1}% {2}' -f $label, $remaining, (Format-Gauge $spent $elapsed 8)
}

function Render-Status($obj, $nowEpoch) {
    # workspace: last 2 path segments of cwd, forward-slash normalized
    $dirStr = ''
    if ($obj.cwd) {
        $segs = ($obj.cwd -replace '\\', '/') -split '/' | Where-Object { $_ -ne '' }
        if ($segs.Count -ge 2) { $dirStr = '{0}/{1}' -f $segs[-2], $segs[-1] }
        elseif ($segs.Count -eq 1) { $dirStr = $segs[0] }
    }

    # model, with /effort suffix when the current model exposes a reasoning effort level
    $modelStr = $obj.model.id -replace '^claude-', ''
    if ($obj.effort.level) { $modelStr = '{0}/{1}' -f $modelStr, $obj.effort.level }

    $ctxStr = '{0}/{1}' -f (Format-Tokens $obj.context_window.total_input_tokens),
                             (Format-Tokens $obj.context_window.context_window_size)

    # session cost (omit when rounded value is zero/missing)
    $costStr = $null
    if ($null -ne $obj.cost -and $null -ne $obj.cost.total_cost_usd) {
        $rounded = [math]::Round([double]$obj.cost.total_cost_usd, 2, [MidpointRounding]::AwayFromZero)
        if ($rounded -gt 0) { $costStr = '${0:0.00}' -f $rounded }
    }

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
    # The CC `padding` setting (an indent we cannot read) may clip a split line by
    # a few columns — accepted limitation.
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
}

# --demo: drive the real renderer with synthetic payloads so the documented
# examples can never drift from live output. now=0, so resets_at == seconds left
# in the window (5h=18000s). The 7d window is held identical across rows.
if ($args -contains '--demo' -or $args -contains '-demo') {
    function Demo-Row($label, $used5h, $secLeft5h) {
        $json = '{"cwd":"/home/you/code/my-project","model":{"id":"claude-opus-4-7"},"effort":{"level":"high"},"context_window":{"total_input_tokens":12000,"context_window_size":200000},"rate_limits":{"five_hour":{"used_percentage":' + $used5h + ',"resets_at":' + $secLeft5h + '},"seven_day":{"used_percentage":64,"resets_at":175392}},"cost":{"total_cost_usd":1.23}}'
        $o = $json | ConvertFrom-Json
        return '{0,-13} {1}' -f $label, (Render-Status $o 0)
    }
    Write-Output (Demo-Row 'conserving'   20 4500)    # 20% spent, 75% of the window gone — marker deep inside the fill
    Write-Output (Demo-Row 'on pace'      50 9000)    # 50% spent, 50% gone — marker rides the leading edge
    Write-Output (Demo-Row 'overspending' 75 13500)   # 75% spent, 25% gone — marker stranded out in the empty
    return
}

try {
    $raw = [Console]::In.ReadToEnd()
    if (-not $raw.Trim()) { return }
    $obj = $raw | ConvertFrom-Json

    # now (epoch seconds): test override or real UTC
    if ($env:CLAUDE_STATUSLINE_NOW) {
        $nowEpoch = [int64]$env:CLAUDE_STATUSLINE_NOW
    } else {
        $nowEpoch = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    }

    Write-Output (Render-Status $obj $nowEpoch)
} catch {
    Write-Output "statusline err: $($_.Exception.Message)"
}
