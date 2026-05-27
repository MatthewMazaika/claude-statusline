# Installer for claude-statusline (Windows). Idempotent.
# Works two ways:
#   from a clone:    .\install.ps1                 (copies the sibling statusline.ps1)
#   piped remotely:  irm .../install.ps1 | iex     (fetches statusline.ps1)
$ErrorActionPreference = 'Stop'

$rawBase = 'https://raw.githubusercontent.com/MatthewMazaika/claude-statusline/main'

$claudeDir = Join-Path $env:USERPROFILE '.claude'
if (-not (Test-Path $claudeDir)) { New-Item -ItemType Directory -Path $claudeDir | Out-Null }
$dest = Join-Path $claudeDir 'statusline.ps1'

# Dual-mode: copy the sibling script when run from a clone, otherwise fetch it.
$localScript = $null
$scriptPath = $MyInvocation.MyCommand.Path
if ($scriptPath) {
    $candidate = Join-Path (Split-Path -Parent $scriptPath) 'statusline.ps1'
    if (Test-Path $candidate) { $localScript = $candidate }
}

if ($localScript) {
    Copy-Item -Path $localScript -Destination $dest -Force
    Write-Host "Installed statusline.ps1 (from clone) -> $dest"
} else {
    Invoke-WebRequest -Uri "$rawBase/statusline.ps1" -OutFile $dest -UseBasicParsing
    Write-Host "Installed statusline.ps1 (fetched) -> $dest"
}

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
Write-Host "settings.json statusLine.command = $cmd"
