$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$claudeDir = Join-Path $env:USERPROFILE '.claude'
if (-not (Test-Path $claudeDir)) { New-Item -ItemType Directory -Path $claudeDir | Out-Null }

$dest = Join-Path $claudeDir 'statusline.ps1'
Copy-Item -Path (Join-Path $scriptDir 'statusline.ps1') -Destination $dest -Force

$destFwd = $dest -replace '\\', '/'
$cmd = "powershell -NoProfile -NonInteractive -File $destFwd"

$settingsPath = Join-Path $claudeDir 'settings.json'
if (Test-Path $settingsPath) {
    $json = Get-Content -Raw -Path $settingsPath | ConvertFrom-Json
} else {
    $json = [PSCustomObject]@{}
}

$entry = [PSCustomObject]@{ type = 'command'; command = $cmd }
if ($json.PSObject.Properties.Name -contains 'statusLine') {
    $json.statusLine = $entry
} else {
    $json | Add-Member -NotePropertyName statusLine -NotePropertyValue $entry
}

[System.IO.File]::WriteAllText($settingsPath, ($json | ConvertTo-Json -Depth 10))
Write-Host "Installed statusline.ps1 -> $dest"
Write-Host "settings.json statusLine.command = $cmd"
