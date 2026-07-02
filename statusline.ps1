# Claude Code status line (Windows / PowerShell).
#
# Usage:
#   <claude json> | statusline.ps1    # normal: render one status line from stdin
#   statusline.ps1 --demo             # print the three pace states (see README)
$ErrorActionPreference = 'Continue'

# Block-drawing glyphs need a UTF-8 console or they render as mojibake.
try { [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new() } catch {}

# ── Cost-baseline state ────────────────────────────────────────────────────────
# /clear creates a new session_id (its SessionStart hook fires with the
# "SessionStart:clear" event name). cost.total_cost_usd, however, is a
# terminal-process-level accumulator that does not reset when the session_id
# changes. We persist the last-seen session_id and cost baseline so the
# displayed cost reflects only the current conversation.
#
# State file lives next to the script so it survives across invocations without
# any environment-variable dependency.
$StateFile = if ($env:CLAUDE_STATUSLINE_STATE_FILE) {
    $env:CLAUDE_STATUSLINE_STATE_FILE
} elseif ($PSCommandPath) {
    Join-Path (Split-Path -Parent $PSCommandPath) 'statusline-state.json'
} else {
    "$env:USERPROFILE\.claude\statusline-state.json"
}

function Read-CostState {
    try {
        if (Test-Path $StateFile) { return Get-Content $StateFile -Raw | ConvertFrom-Json }
    } catch {}
    return [PSCustomObject]@{ sessionId = ''; costBaseline = 0.0 }
}

function Write-CostState($sid, $baseline) {
    try {
        [ordered]@{ sessionId = $sid; costBaseline = $baseline } |
            ConvertTo-Json -Compress | Set-Content $StateFile -Encoding UTF8
    } catch {}
}

# ── Auto-update state ────────────────────────────────────────────────────────
# Silent, throttled, self-contained: no installer/cron/hook changes. At most
# once per CLAUDE_STATUSLINE_UPDATE_INTERVAL (default 24h), a normal
# invocation spawns a fully detached re-invocation of this same file with
# --update-worker, which fetches the latest v2 script and atomically replaces
# it if different. Mirrors the cost-state file's directory-adjacent,
# env-override-able placement above.
$Self = $PSCommandPath
$UpdateStateFile = if ($env:CLAUDE_STATUSLINE_UPDATE_STATE_FILE) {
    $env:CLAUDE_STATUSLINE_UPDATE_STATE_FILE
} elseif ($Self) {
    Join-Path (Split-Path -Parent $Self) 'statusline-update-state.json'
} else {
    "$env:USERPROFILE\.claude\statusline-update-state.json"
}

function Invoke-UpdateWorker {
    if (-not $Self) { return }
    $tmp = $null
    try {
        $url = if ($env:CLAUDE_STATUSLINE_UPDATE_URL) { $env:CLAUDE_STATUSLINE_UPDATE_URL } else { 'https://raw.githubusercontent.com/MatthewMazaika/claude-statusline/v2/statusline.ps1' }
        $tmp = "$Self.$PID.tmp"
        Invoke-WebRequest -Uri $url -OutFile $tmp -TimeoutSec 10 -UseBasicParsing -ErrorAction Stop
        $newContent = Get-Content -Raw -Path $tmp -ErrorAction Stop
        # Sanity: non-empty, looks like our script, not a truncated/error
        # response (e.g. a GitHub error page). Guards the deployed file from
        # ever being observed in a half-written or garbage state.
        if (-not $newContent -or $newContent.Length -lt 200 -or -not $newContent.TrimStart().StartsWith('#')) {
            Remove-Item -Path $tmp -Force -ErrorAction SilentlyContinue
            return
        }
        $current = if (Test-Path $Self) { Get-Content -Raw -Path $Self } else { '' }
        if ($newContent -eq $current) {
            Remove-Item -Path $tmp -Force -ErrorAction SilentlyContinue
        } else {
            Move-Item -Path $tmp -Destination $Self -Force
        }
    } catch {
        if ($tmp) { Remove-Item -Path $tmp -Force -ErrorAction SilentlyContinue }
    }
}

function Invoke-ScheduleUpdateIfDue($nowEpoch) {
    if ($env:CLAUDE_STATUSLINE_NO_UPDATE) { return }
    if (-not $Self) { return }
    $interval = if ($env:CLAUDE_STATUSLINE_UPDATE_INTERVAL) { [int]$env:CLAUDE_STATUSLINE_UPDATE_INTERVAL } else { 86400 }
    $last = 0
    if (Test-Path $UpdateStateFile) {
        try { $last = [int64]((Get-Content -Raw -Path $UpdateStateFile | ConvertFrom-Json).lastCheck) } catch { $last = 0 }
    }
    if (($nowEpoch - $last) -lt $interval) { return }
    try {
        [ordered]@{ lastCheck = $nowEpoch } | ConvertTo-Json -Compress | Set-Content $UpdateStateFile -Encoding UTF8
        Start-Process -FilePath 'powershell' -ArgumentList @('-NoProfile', '-NonInteractive', '-WindowStyle', 'Hidden', '-File', $Self, '--update-worker') -WindowStyle Hidden -ErrorAction Stop | Out-Null
    } catch {}
}

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

    # Claude Code indents the status line 2 columns (built-in, not in COLUMNS;
    # measured on CC 2.1.160). Reserving 4 flushes the budget cluster to a 2-column
    # right inset mirroring that left indent — symmetric, and clear of the last
    # cell (phantom wrap). Reserving only 1 truncated cost in testing. A user-set
    # `padding` adds further indent we cannot read, so a split may still clip.
    $edge = $cols - 4
    if ($right.Length -eq 0) { return $left }
    if ($left.Length -eq 0) {
        if ($cols -gt 0 -and $right.Length -le $edge) {
            return (' ' * ($edge - $right.Length)) + $right
        }
        return $right
    }
    if ($cols -gt 0 -and (($left.Length + 2 + $right.Length) -le $edge)) {
        $pad = $edge - $left.Length - $right.Length
        return $left + (' ' * $pad) + $right
    }
    return $left + ' | ' + $right
}

# --demo: drive the real renderer with synthetic payloads so the documented
# examples can never drift from live output. now=0, so resets_at == seconds left
# in the window (5h=18000s). The 7d window is held identical across rows.
if ($args -contains '--demo' -or $args -contains '-demo') {
    $env:COLUMNS = if ($env:COLUMNS) { $env:COLUMNS } else { '100' }  # fixed width so the split renders
    function Demo-Row($label, $used5h, $secLeft5h) {
        $json = '{"cwd":"/home/you/code/my-project","model":{"id":"claude-opus-4-7"},"effort":{"level":"high"},"context_window":{"total_input_tokens":12000,"context_window_size":200000},"rate_limits":{"five_hour":{"used_percentage":' + $used5h + ',"resets_at":' + $secLeft5h + '},"seven_day":{"used_percentage":64,"resets_at":175392}},"cost":{"total_cost_usd":1.23}}'
        $o = $json | ConvertFrom-Json
        return "# $label`n" + (Render-Status $o 0)
    }
    Write-Output (Demo-Row 'conserving'   20 4500)    # 20% spent, 75% of the window gone — marker deep inside the fill
    Write-Output (Demo-Row 'on pace'      50 9000)    # 50% spent, 50% gone — marker rides the leading edge
    Write-Output (Demo-Row 'overspending' 75 13500)   # 75% spent, 25% gone — marker stranded out in the empty
    return
}

if ($args -contains '--update-worker') {
    Invoke-UpdateWorker
    return
}

# now (epoch seconds): test override or real UTC. Resolved once, outside the
# try/catch below, so a malformed-input error still leaves it set for the
# auto-update throttle check at the bottom.
$nowEpoch = if ($env:CLAUDE_STATUSLINE_NOW) { [int64]$env:CLAUDE_STATUSLINE_NOW } else { [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() }

try {
    $raw = [Console]::In.ReadToEnd()
    if (-not $raw.Trim()) { return }
    $obj = $raw | ConvertFrom-Json

    # Adjust cost.total_cost_usd to reflect only the current conversation.
    # /clear assigns a new session_id; when we see a new id, snapshot the
    # current cumulative cost as the new baseline.
    $sid     = [string]($obj.session_id)
    $rawCost = if ($null -ne $obj.cost -and $null -ne $obj.cost.total_cost_usd) {
                   [double]$obj.cost.total_cost_usd } else { 0.0 }
    $st      = Read-CostState
    $baseline = if ($st.sessionId -ne $sid) { $rawCost } else { [double]$st.costBaseline }
    Write-CostState $sid $baseline

    if ($null -ne $obj.cost -and $null -ne $obj.cost.total_cost_usd) {
        $obj.cost.total_cost_usd = [math]::Max(0.0, $rawCost - $baseline)
    }

    Write-Output (Render-Status $obj $nowEpoch)
} catch {
    Write-Output "statusline err: $($_.Exception.Message)"
}

Invoke-ScheduleUpdateIfDue $nowEpoch
