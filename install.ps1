# OpenClaw Windows Installer
# Run as: powershell -ExecutionPolicy Bypass -File install.ps1
#
# Installs and configures OpenClaw to run on Windows via WSL2 with:
# - Automatic startup via Windows Startup folder
# - System tray health monitor
# - Toast notifications with action buttons
# - Auto-restart on failure

param(
    [switch]$SkipOpenClawInstall,
    [switch]$SkipBurntToast,
    [switch]$NonInteractive
)

$ErrorActionPreference = "Stop"

$installDir = "$env:USERPROFILE\.openclaw-windows"
$configFile = "$installDir\config.json"
$startupDir = "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup"
$scriptRoot = $PSScriptRoot

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  OpenClaw Windows Installer" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# --- Step 1: Check prerequisites ---

Write-Host "[1/10] Checking prerequisites..." -ForegroundColor Yellow

# Check WSL
$wslVersion = wsl.exe --version 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Host "ERROR: WSL is not installed. Install it with: wsl --install" -ForegroundColor Red
    exit 1
}
Write-Host "  WSL: OK" -ForegroundColor Green

# Check for a distro (default Ubuntu)
# Note: wsl.exe outputs UTF-16LE with null bytes; strip them for reliable matching
$distros = (wsl.exe --list --quiet 2>&1) -replace "`0", ""
$defaultDistro = "Ubuntu"
if ($distros -notmatch "Ubuntu") {
    $available = ($distros -split "`n" | Where-Object { $_.Trim() }) -join ", "
    if ($available) {
        Write-Host "  Available distros: $available" -ForegroundColor Yellow
        if (-not $NonInteractive) {
            $defaultDistro = Read-Host "  Enter WSL distro name to use (default: Ubuntu)"
            if (-not $defaultDistro) { $defaultDistro = "Ubuntu" }
        }
    } else {
        Write-Host "ERROR: No WSL distros found. Install Ubuntu with: wsl --install -d Ubuntu" -ForegroundColor Red
        exit 1
    }
}
Write-Host "  WSL distro: $defaultDistro" -ForegroundColor Green

# Check distro responds
$wslCheck = wsl.exe -d $defaultDistro -e bash -c "echo ok" 2>&1
if ($wslCheck -ne "ok") {
    Write-Host "ERROR: WSL distro '$defaultDistro' is not responding" -ForegroundColor Red
    exit 1
}
Write-Host "  WSL responds: OK" -ForegroundColor Green

# Check npm in WSL
$npmCheck = wsl.exe -d $defaultDistro -e bash -c "command -v npm" 2>&1
if (-not $npmCheck) {
    Write-Host "WARNING: npm not found in WSL. OpenClaw requires Node.js + npm." -ForegroundColor Yellow
    Write-Host "  Install with: wsl -d $defaultDistro -e bash -c 'curl -fsSL https://deb.nodesource.com/setup_lts.x | sudo -E bash - && sudo apt-get install -y nodejs'" -ForegroundColor Yellow
    if (-not $NonInteractive) {
        $proceed = Read-Host "  Continue anyway? (y/N)"
        if ($proceed -ne "y") { exit 1 }
    }
} else {
    Write-Host "  npm: OK" -ForegroundColor Green
}

# --- Step 2: Install OpenClaw in WSL ---

Write-Host ""
Write-Host "[2/10] Checking OpenClaw installation..." -ForegroundColor Yellow

if (-not $SkipOpenClawInstall) {
    $ocCheck = wsl.exe -d $defaultDistro -e bash -c "command -v openclaw 2>/dev/null" 2>&1
    if ($ocCheck) {
        $ocVersion = wsl.exe -d $defaultDistro -e bash -c "openclaw --version 2>/dev/null" 2>&1
        Write-Host "  OpenClaw already installed: $ocVersion" -ForegroundColor Green
    } else {
        Write-Host "  Installing OpenClaw via npm..." -ForegroundColor Yellow
        wsl.exe -d $defaultDistro -e bash -c "npm install -g openclaw 2>&1"
        if ($LASTEXITCODE -ne 0) {
            Write-Host "WARNING: npm install -g openclaw failed. You may need to configure npm prefix." -ForegroundColor Yellow
        } else {
            Write-Host "  OpenClaw installed" -ForegroundColor Green
        }
    }
} else {
    Write-Host "  Skipped (--SkipOpenClawInstall)" -ForegroundColor Gray
}

# --- Step 3: Check systemd ---

Write-Host ""
Write-Host "[3/10] Checking WSL systemd..." -ForegroundColor Yellow

$systemdEnabled = wsl.exe -d $defaultDistro -e bash -c "grep -q 'systemd=true' /etc/wsl.conf 2>/dev/null && echo yes" 2>&1
if ($systemdEnabled -ne "yes") {
    Write-Host "  Systemd is not enabled in WSL." -ForegroundColor Yellow
    Write-Host "  Adding [boot] systemd=true to /etc/wsl.conf..." -ForegroundColor Yellow
    wsl.exe -d $defaultDistro -u root -e bash -c @"
if [ -f /etc/wsl.conf ]; then
    if ! grep -q '\[boot\]' /etc/wsl.conf; then
        echo -e '\n[boot]\nsystemd=true' >> /etc/wsl.conf
    elif ! grep -q 'systemd=true' /etc/wsl.conf; then
        sed -i '/\[boot\]/a systemd=true' /etc/wsl.conf
    fi
else
    echo -e '[boot]\nsystemd=true' > /etc/wsl.conf
fi
"@ 2>&1
    Write-Host "  Systemd enabled. WSL will need a restart (wsl --shutdown)." -ForegroundColor Yellow
} else {
    Write-Host "  Systemd: enabled" -ForegroundColor Green
}

# --- Step 4: Configure .wslconfig ---

Write-Host ""
Write-Host "[4/10] Checking .wslconfig (VM idle timeout)..." -ForegroundColor Yellow

$wslconfigPath = "$env:USERPROFILE\.wslconfig"
$needsVmTimeout = $true

if (Test-Path $wslconfigPath) {
    $wslconfigContent = Get-Content $wslconfigPath -Raw
    if ($wslconfigContent -match "vmIdleTimeout\s*=\s*-1") {
        $needsVmTimeout = $false
        Write-Host "  vmIdleTimeout=-1 already set" -ForegroundColor Green
    }
}

if ($needsVmTimeout) {
    if (Test-Path $wslconfigPath) {
        $existingContent = Get-Content $wslconfigPath -Raw
        if ($existingContent -match "\[wsl2\]") {
            # Add under existing [wsl2] section
            $existingContent = $existingContent -replace "(\[wsl2\])", "`$1`nvmIdleTimeout=-1"
            $existingContent | Set-Content $wslconfigPath
        } else {
            # Append new section
            Add-Content $wslconfigPath "`n[wsl2]`nvmIdleTimeout=-1"
        }
    } else {
        "[wsl2]`nvmIdleTimeout=-1" | Set-Content $wslconfigPath
    }
    Write-Host "  Set vmIdleTimeout=-1 in .wslconfig" -ForegroundColor Green
}

# --- Step 5: Create config directory and config.json ---

Write-Host ""
Write-Host "[5/10] Setting up config..." -ForegroundColor Yellow

if (-not (Test-Path $installDir)) {
    New-Item -Path $installDir -ItemType Directory -Force | Out-Null
}

if (Test-Path $configFile) {
    Write-Host "  Config already exists at $configFile" -ForegroundColor Green
    Write-Host "  Keeping existing config (edit manually if needed)" -ForegroundColor Gray
} else {
    # Read example config and customize
    $exampleConfig = Get-Content "$scriptRoot\config.example.json" -Raw | ConvertFrom-Json

    $exampleConfig.wslDistro = $defaultDistro

    # Try to detect npm prefix
    $detectedPrefix = wsl.exe -d $defaultDistro -e bash -c "npm config get prefix 2>/dev/null" 2>&1
    if ($detectedPrefix -and $detectedPrefix.Trim() -ne "") {
        $exampleConfig.npmPrefix = $detectedPrefix.Trim()
        Write-Host "  Detected npm prefix: $($exampleConfig.npmPrefix)" -ForegroundColor Green
    }

    # Try to detect Tailscale hostname for webUiUrl
    $tsHostname = wsl.exe -d $defaultDistro -e bash -c "tailscale status --json 2>/dev/null | jq -r '.Self.DNSName // empty' | sed 's/\.$//' " 2>&1
    if ($tsHostname -and $tsHostname.Trim() -ne "") {
        $exampleConfig.webUiUrl = "https://$($tsHostname.Trim())"
        Write-Host "  Detected Tailscale hostname: $($exampleConfig.webUiUrl)" -ForegroundColor Green
    }

    # Try to detect WSL username for npm prefix path
    $wslUser = wsl.exe -d $defaultDistro -e bash -c "whoami" 2>&1
    if ($wslUser) {
        $wslUser = $wslUser.Trim()
        Write-Host "  WSL user: $wslUser" -ForegroundColor Green
    }

    if (-not $NonInteractive) {
        Write-Host ""
        Write-Host "  Current config values:" -ForegroundColor Cyan
        Write-Host "    wslDistro:  $($exampleConfig.wslDistro)"
        Write-Host "    npmPrefix:  $($exampleConfig.npmPrefix)"
        Write-Host "    webUiUrl:   $($exampleConfig.webUiUrl)"
        Write-Host "    servicePort: $($exampleConfig.servicePort)"
        Write-Host ""
        $customize = Read-Host "  Edit any values? (y/N)"
        if ($customize -eq "y") {
            $input = Read-Host "    Web UI URL [$($exampleConfig.webUiUrl)]"
            if ($input) { $exampleConfig.webUiUrl = $input }
            $input = Read-Host "    Service port [$($exampleConfig.servicePort)]"
            if ($input) { $exampleConfig.servicePort = [int]$input }
            $input = Read-Host "    npm prefix [$($exampleConfig.npmPrefix)]"
            if ($input) { $exampleConfig.npmPrefix = $input }
        }
    }

    $exampleConfig | ConvertTo-Json -Depth 5 | Set-Content $configFile
    Write-Host "  Config written to $configFile" -ForegroundColor Green
}

# --- Step 6: Install startup files ---

Write-Host ""
Write-Host "[6/10] Installing startup files..." -ForegroundColor Yellow

# Backup existing scripts before overwriting
$backupDir = "$installDir\backup"
$existingScripts = @("start-wsl.bat", "start-wsl-hidden.vbs", "wsl-health-monitor.ps1")
$hasExisting = $existingScripts | Where-Object { Test-Path (Join-Path $startupDir $_) }
if ($hasExisting) {
    if (-not (Test-Path $backupDir)) { New-Item -Path $backupDir -ItemType Directory -Force | Out-Null }
    foreach ($f in $hasExisting) {
        Copy-Item (Join-Path $startupDir $f) (Join-Path $backupDir $f) -Force
    }
    Write-Host "  Backed up existing scripts to $backupDir" -ForegroundColor Gray
}

Copy-Item "$scriptRoot\src\start-wsl.bat" "$startupDir\start-wsl.bat" -Force
Copy-Item "$scriptRoot\src\start-wsl-hidden.vbs" "$startupDir\start-wsl-hidden.vbs" -Force
Copy-Item "$scriptRoot\src\wsl-health-monitor.ps1" "$startupDir\wsl-health-monitor.ps1" -Force

Write-Host "  Copied to: $startupDir" -ForegroundColor Green
Write-Host "    - start-wsl.bat" -ForegroundColor Gray
Write-Host "    - start-wsl-hidden.vbs" -ForegroundColor Gray
Write-Host "    - wsl-health-monitor.ps1" -ForegroundColor Gray

# --- Step 7: Install action scripts ---

Write-Host ""
Write-Host "[7/10] Installing action scripts..." -ForegroundColor Yellow

$actionsDir = "$installDir\actions"
if (-not (Test-Path $actionsDir)) {
    New-Item -Path $actionsDir -ItemType Directory -Force | Out-Null
}

Copy-Item "$scriptRoot\actions\update.ps1" "$actionsDir\update.ps1" -Force
Copy-Item "$scriptRoot\actions\restart.ps1" "$actionsDir\restart.ps1" -Force
Copy-Item "$scriptRoot\actions\changelog.ps1" "$actionsDir\changelog.ps1" -Force

Write-Host "  Copied to: $actionsDir" -ForegroundColor Green

# --- Step 8: Register protocol handlers ---

Write-Host ""
Write-Host "[8/10] Registering protocol handlers..." -ForegroundColor Yellow

$protocols = @(
    @{ Name = "openclaw-update";    Script = "$actionsDir\update.ps1";    Visible = $true },
    @{ Name = "openclaw-restart";   Script = "$actionsDir\restart.ps1";   Visible = $true },
    @{ Name = "openclaw-changelog"; Script = "$actionsDir\changelog.ps1"; Visible = $false }
)

foreach ($proto in $protocols) {
    $regPath = "HKCU:\Software\Classes\$($proto.Name)"
    New-Item -Path $regPath -Force | Out-Null
    Set-ItemProperty -Path $regPath -Name "(Default)" -Value "URL:$($proto.Name)"
    Set-ItemProperty -Path $regPath -Name "URL Protocol" -Value ""
    New-Item -Path "$regPath\shell\open\command" -Force | Out-Null
    if ($proto.Visible) {
        Set-ItemProperty -Path "$regPath\shell\open\command" -Name "(Default)" -Value "powershell.exe -ExecutionPolicy Bypass -NoExit -Command `"& '$($proto.Script)'`""
    } else {
        Set-ItemProperty -Path "$regPath\shell\open\command" -Name "(Default)" -Value "powershell.exe -ExecutionPolicy Bypass -WindowStyle Hidden -Command `"& '$($proto.Script)'`""
    }
    Write-Host "  Registered: $($proto.Name)://" -ForegroundColor Green
}

# Clean up legacy action scripts directory if it exists
$legacyActions = "$env:USERPROFILE\.openclaw-actions"
if (Test-Path $legacyActions) {
    Remove-Item $legacyActions -Recurse -Force
    Write-Host "  Cleaned up legacy actions dir: $legacyActions" -ForegroundColor Gray
}

# --- Step 9: Install BurntToast ---

Write-Host ""
Write-Host "[9/10] Checking BurntToast module..." -ForegroundColor Yellow

if (-not $SkipBurntToast) {
    $bt = Get-Module -ListAvailable BurntToast -ErrorAction SilentlyContinue
    if ($bt) {
        Write-Host "  BurntToast already installed: v$($bt.Version)" -ForegroundColor Green
    } else {
        Write-Host "  Installing BurntToast for rich toast notifications..." -ForegroundColor Yellow
        try {
            Install-Module BurntToast -Scope CurrentUser -Force -AllowClobber
            Write-Host "  BurntToast installed" -ForegroundColor Green
        } catch {
            Write-Host "  WARNING: Could not install BurntToast. Falling back to balloon tips." -ForegroundColor Yellow
            Write-Host "  Install manually: Install-Module BurntToast -Scope CurrentUser" -ForegroundColor Gray
        }
    }
} else {
    Write-Host "  Skipped (--SkipBurntToast)" -ForegroundColor Gray
}

# --- Step 10: Launch ---

Write-Host ""
Write-Host "[10/10] Starting OpenClaw monitor..." -ForegroundColor Yellow

# Kill any running health monitor before starting fresh
Get-Process powershell, pwsh -ErrorAction SilentlyContinue | Where-Object {
    try {
        (Get-CimInstance Win32_Process -Filter "ProcessId=$($_.Id)" -ErrorAction SilentlyContinue).CommandLine -match "wsl-health-monitor"
    } catch { $false }
} | ForEach-Object {
    Write-Host "  Stopping old health monitor (PID $($_.Id))..." -ForegroundColor Yellow
    Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue
}

# Start the VBS launcher (starts WSL keep-alive + tray monitor)
Start-Process wscript.exe -ArgumentList "//nologo `"$startupDir\start-wsl-hidden.vbs`""

Write-Host "  Tray monitor launched (look for the icon in your system tray)" -ForegroundColor Green

# --- Done ---

Write-Host ""
Write-Host "========================================" -ForegroundColor Green
Write-Host "  Installation Complete!" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
Write-Host ""
Write-Host "What was installed:" -ForegroundColor Cyan
Write-Host "  Config:   $configFile"
Write-Host "  Actions:  $actionsDir\"
Write-Host "  Startup:  $startupDir\"
Write-Host "  Registry: HKCU:\Software\Classes\openclaw-*"
Write-Host ""
Write-Host "Next steps:" -ForegroundColor Cyan
Write-Host "  1. The tray icon should appear shortly (gray -> green when healthy)"
Write-Host "  2. Edit $configFile to customize settings"
Write-Host "  3. The monitor auto-starts on login via the Startup folder"
Write-Host "  4. Back up config: powershell -ExecutionPolicy Bypass -File backup.ps1" -ForegroundColor Gray
Write-Host ""
Write-Host "To uninstall: powershell -ExecutionPolicy Bypass -File uninstall.ps1" -ForegroundColor Gray
Write-Host ""
Read-Host "Press Enter to close this window"
