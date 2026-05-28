$ErrorActionPreference = 'Continue'
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

    # token formatter (round half away from zero for cross-platform parity)
    function Format-Tokens($n) {
        $v = [double]$n
        if ($v -ge 1000000) { return ('{0:0.0}M' -f [math]::Round($v / 1000000, 1, [MidpointRounding]::AwayFromZero)) }
        if ($v -ge 1000)    { return ('{0}k'     -f [int][math]::Round($v / 1000, 0, [MidpointRounding]::AwayFromZero)) }
        return "$([int]$v)"
    }
    $ctxStr = '{0}/{1}' -f (Format-Tokens $obj.context_window.total_input_tokens),
                             (Format-Tokens $obj.context_window.context_window_size)

    # rate-limit tuple: label:remaining%~expectedRemaining% (omit ~expected within 3%)
    function Format-RateTuple($window, $windowHours, $label) {
        if ($null -eq $window -or $null -eq $window.used_percentage) { return $null }
        $remaining    = [int][math]::Ceiling(100 - $window.used_percentage)
        # resets_at may be absent/null (the rate_limits object and each window are
        # omitted until the first API response) or point at a just-passed boundary.
        # Only compute a pace estimate when it is a usable future timestamp;
        # otherwise show the bare remaining %. Guards the bogus "~0%" that a
        # missing/past resets_at (coerced to 0 by [int64]$null) would produce.
        $resetsAt     = if ($null -ne $window.resets_at) { [int64]$window.resets_at } else { 0 }
        $secLeft      = $resetsAt - $nowEpoch
        if ($secLeft -le 0) {
            return '{0}:{1}%' -f $label, $remaining
        }
        $windowSecs   = $windowHours * 3600.0
        $elapsed      = $windowSecs - $secLeft
        $expUsed      = [math]::Max(0, [math]::Min(100, ($elapsed / $windowSecs) * 100))
        $expRemaining = [int][math]::Round(100 - $expUsed, [MidpointRounding]::AwayFromZero)
        if ([math]::Abs($remaining - $expRemaining) -ge 3) {
            return '{0}:{1}%~{2}%' -f $label, $remaining, $expRemaining
        }
        return '{0}:{1}%' -f $label, $remaining
    }

    # session cost (omit when rounded value is zero/missing)
    $costStr = $null
    if ($null -ne $obj.cost -and $null -ne $obj.cost.total_cost_usd) {
        $rounded = [math]::Round([double]$obj.cost.total_cost_usd, 2, [MidpointRounding]::AwayFromZero)
        if ($rounded -gt 0) {
            $costStr = '${0:0.00}' -f $rounded
        }
    }

    $parts = @()
    if ($dirStr) { $parts += $dirStr }
    $parts += $modelStr
    $parts += $ctxStr
    $fhStr = Format-RateTuple $obj.rate_limits.five_hour  5   '5h'
    $wkStr = Format-RateTuple $obj.rate_limits.seven_day  168 '7d'
    if ($fhStr) { $parts += $fhStr }
    if ($wkStr) { $parts += $wkStr }
    if ($costStr) { $parts += $costStr }

    Write-Output ($parts -join ' | ')
} catch {
    Write-Output "statusline err: $($_.Exception.Message)"
}
