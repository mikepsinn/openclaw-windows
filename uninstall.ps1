# OpenClaw Windows Uninstaller
# Run as: powershell -ExecutionPolicy Bypass -File uninstall.ps1

param(
    [switch]$KeepConfig,
    [switch]$Force
)

$ErrorActionPreference = "Continue"

$installDir = "$env:USERPROFILE\.openclaw-windows"
$startupDir = "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup"

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  OpenClaw Windows Uninstaller" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

if (-not $Force) {
    $confirm = Read-Host "This will remove OpenClaw Windows monitor files. Continue? (y/N)"
    if ($confirm -ne "y") {
        Write-Host "Cancelled." -ForegroundColor Yellow
        exit 0
    }
}

# --- Stop running monitor ---

Write-Host ""
Write-Host "[1/5] Stopping running monitor..." -ForegroundColor Yellow

$procs = Get-Process powershell, pwsh -ErrorAction SilentlyContinue |
    Where-Object {
        try {
            $_.MainModule.FileName -and
            (Get-WmiObject Win32_Process -Filter "ProcessId=$($_.Id)" -ErrorAction SilentlyContinue).CommandLine -match "wsl-health-monitor"
        } catch { $false }
    }

if ($procs) {
    $procs | Stop-Process -Force -ErrorAction SilentlyContinue
    Write-Host "  Stopped health monitor process(es)" -ForegroundColor Green
} else {
    Write-Host "  No running monitor found" -ForegroundColor Gray
}

# Also kill hidden WSL sleep infinity
$wslProcs = Get-Process wsl -ErrorAction SilentlyContinue
Write-Host "  (WSL processes left running - use 'wsl --shutdown' to stop WSL)" -ForegroundColor Gray

# --- Remove startup files ---

Write-Host ""
Write-Host "[2/5] Removing startup files..." -ForegroundColor Yellow

$startupFiles = @("start-wsl.bat", "start-wsl-hidden.vbs", "wsl-health-monitor.ps1")
foreach ($f in $startupFiles) {
    $path = Join-Path $startupDir $f
    if (Test-Path $path) {
        Remove-Item $path -Force
        Write-Host "  Removed: $path" -ForegroundColor Green
    } else {
        Write-Host "  Not found: $f" -ForegroundColor Gray
    }
}

# --- Remove registry entries ---

Write-Host ""
Write-Host "[3/5] Removing protocol handlers..." -ForegroundColor Yellow

$protocols = @("openclaw-update", "openclaw-restart", "openclaw-changelog")
foreach ($proto in $protocols) {
    $regPath = "HKCU:\Software\Classes\$proto"
    if (Test-Path $regPath) {
        Remove-Item $regPath -Recurse -Force
        Write-Host "  Removed: $proto://" -ForegroundColor Green
    } else {
        Write-Host "  Not found: $proto" -ForegroundColor Gray
    }
}

# --- Remove action scripts ---

Write-Host ""
Write-Host "[4/5] Removing action scripts..." -ForegroundColor Yellow

$actionsDir = "$installDir\actions"
if (Test-Path $actionsDir) {
    Remove-Item $actionsDir -Recurse -Force
    Write-Host "  Removed: $actionsDir" -ForegroundColor Green
} else {
    Write-Host "  Not found: $actionsDir" -ForegroundColor Gray
}

# Also remove legacy action dir
$legacyActions = "$env:USERPROFILE\.openclaw-actions"
if (Test-Path $legacyActions) {
    Remove-Item $legacyActions -Recurse -Force
    Write-Host "  Removed legacy: $legacyActions" -ForegroundColor Green
}

# --- Remove config (optional) ---

Write-Host ""
Write-Host "[5/5] Cleaning up config directory..." -ForegroundColor Yellow

if ($KeepConfig) {
    Write-Host "  Keeping config at $installDir (--KeepConfig)" -ForegroundColor Gray
} else {
    if (Test-Path $installDir) {
        Remove-Item $installDir -Recurse -Force
        Write-Host "  Removed: $installDir" -ForegroundColor Green
    } else {
        Write-Host "  Not found: $installDir" -ForegroundColor Gray
    }
}

# Also remove legacy log file
$legacyLog = "$env:USERPROFILE\.openclaw-health.log"
if (Test-Path $legacyLog) {
    Remove-Item $legacyLog -Force
    Write-Host "  Removed legacy log: $legacyLog" -ForegroundColor Green
}

# --- Done ---

Write-Host ""
Write-Host "========================================" -ForegroundColor Green
Write-Host "  Uninstall Complete" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
Write-Host ""
Write-Host "Note: OpenClaw itself is still installed in WSL." -ForegroundColor Gray
Write-Host "To remove it: wsl -e bash -c 'npm uninstall -g openclaw'" -ForegroundColor Gray
Write-Host "To stop WSL:  wsl --shutdown" -ForegroundColor Gray
Write-Host ""
