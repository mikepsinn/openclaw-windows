# OpenClaw Changelog Viewer - triggered by toast button or protocol handler
$configFile = "$env:USERPROFILE\.openclaw-windows\config.json"
if (-not (Test-Path $configFile)) { Write-Host "Config not found: $configFile"; exit 1 }
$cfg = Get-Content $configFile -Raw | ConvertFrom-Json

$pkgDir = "$($cfg.npmPrefix)/lib/node_modules/$($cfg.npmPackage)"
$changelogDest = "$env:USERPROFILE\.openclaw-windows\changelog.md"

$content = wsl.exe -d $cfg.wslDistro -e bash -c "cat $pkgDir/CHANGELOG.md 2>/dev/null"
if ($content) {
    $content | Set-Content $changelogDest
    Start-Process notepad.exe $changelogDest
} else {
    Write-Host "Could not read CHANGELOG.md from $pkgDir"
}
