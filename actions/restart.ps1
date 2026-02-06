# OpenClaw Restart Action - triggered by toast button or protocol handler
$configFile = "$env:USERPROFILE\.openclaw-windows\config.json"
if (-not (Test-Path $configFile)) { Write-Host "Config not found: $configFile"; exit 1 }
$cfg = Get-Content $configFile -Raw | ConvertFrom-Json

Write-Host "Restarting $($cfg.serviceName) in WSL ($($cfg.wslDistro))..."
wsl.exe -d $cfg.wslDistro -e bash -c "systemctl --user restart $($cfg.serviceName)" 2>&1

Write-Host "Done. You can close this window."
