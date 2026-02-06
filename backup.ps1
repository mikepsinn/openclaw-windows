# OpenClaw Config Backup
# Run as: powershell -ExecutionPolicy Bypass -File backup.ps1
#         powershell -ExecutionPolicy Bypass -File backup.ps1 -Restore

param(
    [switch]$Restore
)

$ErrorActionPreference = "Stop"

$installDir = "$env:USERPROFILE\.openclaw-windows"
$configFile = "$installDir\config.json"
$repoName = "openclaw-config"
$syncDir = "$env:TEMP\openclaw-config-sync"

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
if ($Restore) {
    Write-Host "  OpenClaw Config Restore" -ForegroundColor Cyan
} else {
    Write-Host "  OpenClaw Config Backup" -ForegroundColor Cyan
}
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# --- Step 1: Check prerequisites ---

Write-Host "[1/4] Checking prerequisites..." -ForegroundColor Yellow

# Check gh CLI
$ghPath = Get-Command gh -ErrorAction SilentlyContinue
if (-not $ghPath) {
    Write-Host "  ERROR: GitHub CLI (gh) is not installed." -ForegroundColor Red
    Write-Host "  Install with: winget install --id GitHub.cli" -ForegroundColor Gray
    exit 1
}
Write-Host "  gh CLI: OK" -ForegroundColor Green

# Check gh auth
$authStatus = gh auth status 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Host "  ERROR: GitHub CLI is not authenticated." -ForegroundColor Red
    Write-Host "  Run: gh auth login" -ForegroundColor Gray
    exit 1
}
Write-Host "  gh auth: OK" -ForegroundColor Green

# Get GitHub username
$ghUser = gh api user --jq ".login" 2>&1
if ($LASTEXITCODE -ne 0 -or -not $ghUser) {
    Write-Host "  ERROR: Could not determine GitHub username." -ForegroundColor Red
    Write-Host "  Run: gh auth login" -ForegroundColor Gray
    exit 1
}
$ghUser = $ghUser.Trim()
Write-Host "  GitHub user: $ghUser" -ForegroundColor Green

$fullRepoName = "$ghUser/$repoName"

if ($Restore) {
    # =====================
    # RESTORE FLOW
    # =====================

    # --- Step 2: Check backup repo exists ---

    Write-Host ""
    Write-Host "[2/4] Checking backup repo..." -ForegroundColor Yellow

    gh repo view $fullRepoName 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  ERROR: Backup repo '$fullRepoName' not found." -ForegroundColor Red
        Write-Host "  Run backup.ps1 first to create it." -ForegroundColor Gray
        exit 1
    }
    Write-Host "  Repo exists: $fullRepoName" -ForegroundColor Green

    # --- Step 3: Clone or pull ---

    Write-Host ""
    Write-Host "[3/4] Syncing backup repo..." -ForegroundColor Yellow

    if (Test-Path "$syncDir\.git") {
        Write-Host "  Pulling latest..." -ForegroundColor Gray
        git -C $syncDir pull --quiet 2>&1 | Out-Null
    } else {
        if (Test-Path $syncDir) { Remove-Item $syncDir -Recurse -Force }
        Write-Host "  Cloning $fullRepoName..." -ForegroundColor Gray
        gh repo clone $fullRepoName $syncDir -- --quiet 2>&1 | Out-Null
    }
    Write-Host "  Sync complete" -ForegroundColor Green

    # --- Step 4: Restore config ---

    Write-Host ""
    Write-Host "[4/4] Restoring config..." -ForegroundColor Yellow

    $sourceFile = "$syncDir\config.json"
    if (-not (Test-Path $sourceFile)) {
        Write-Host "  ERROR: No config.json found in backup repo." -ForegroundColor Red
        exit 1
    }

    # Ensure install dir exists
    if (-not (Test-Path $installDir)) {
        New-Item -Path $installDir -ItemType Directory -Force | Out-Null
        Write-Host "  Created: $installDir" -ForegroundColor Gray
    }

    # Back up existing config if present
    if (Test-Path $configFile) {
        $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
        $bakFile = "$configFile.bak.$timestamp"
        Copy-Item $configFile $bakFile -Force
        Write-Host "  Existing config backed up to: $bakFile" -ForegroundColor Gray
    }

    Copy-Item $sourceFile $configFile -Force
    Write-Host "  Restored: $configFile" -ForegroundColor Green

} else {
    # =====================
    # BACKUP FLOW
    # =====================

    # Check config.json exists
    if (-not (Test-Path $configFile)) {
        Write-Host "  ERROR: Config file not found at $configFile" -ForegroundColor Red
        Write-Host "  Run install.ps1 first to create it." -ForegroundColor Gray
        exit 1
    }
    Write-Host "  Config file: OK" -ForegroundColor Green

    # --- Step 2: Ensure backup repo exists ---

    Write-Host ""
    Write-Host "[2/4] Ensuring backup repo..." -ForegroundColor Yellow

    gh repo view $fullRepoName 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  Creating private repo: $fullRepoName..." -ForegroundColor Gray
        gh repo create $repoName --private --description "OpenClaw config backup (auto-managed by backup.ps1)" 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Host "  ERROR: Failed to create repo." -ForegroundColor Red
            exit 1
        }
        Write-Host "  Created: $fullRepoName" -ForegroundColor Green
    } else {
        Write-Host "  Repo exists: $fullRepoName" -ForegroundColor Green
    }

    # --- Step 3: Clone or pull ---

    Write-Host ""
    Write-Host "[3/4] Syncing backup repo..." -ForegroundColor Yellow

    if (Test-Path "$syncDir\.git") {
        Write-Host "  Pulling latest..." -ForegroundColor Gray
        git -C $syncDir pull --quiet 2>&1 | Out-Null
    } else {
        if (Test-Path $syncDir) { Remove-Item $syncDir -Recurse -Force }
        Write-Host "  Cloning $fullRepoName..." -ForegroundColor Gray
        gh repo clone $fullRepoName $syncDir -- --quiet 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            # New empty repo — initialize locally
            New-Item -Path $syncDir -ItemType Directory -Force | Out-Null
            git -C $syncDir init --quiet 2>&1 | Out-Null
            git -C $syncDir remote add origin "https://github.com/$fullRepoName.git" 2>&1 | Out-Null
        }
    }
    Write-Host "  Sync complete" -ForegroundColor Green

    # --- Step 4: Copy, commit, push ---

    Write-Host ""
    Write-Host "[4/4] Backing up config..." -ForegroundColor Yellow

    # Copy config.json
    Copy-Item $configFile "$syncDir\config.json" -Force

    # Create .gitignore if missing
    $gitignorePath = "$syncDir\.gitignore"
    if (-not (Test-Path $gitignorePath)) {
        @"
# Sensitive — never back up
openclaw.json
*.log
sessions/
"@ | Set-Content $gitignorePath
        Write-Host "  Created .gitignore" -ForegroundColor Gray
    }

    # Create README if missing
    $readmePath = "$syncDir\README.md"
    if (-not (Test-Path $readmePath)) {
        @"
# openclaw-config

Private backup of OpenClaw Windows configuration.

Managed automatically by ``backup.ps1`` in [openclaw-windows](https://github.com/mikepsinn/openclaw-windows).
"@ | Set-Content $readmePath
        Write-Host "  Created README.md" -ForegroundColor Gray
    }

    # Check for changes
    git -C $syncDir add -A 2>&1 | Out-Null
    $status = git -C $syncDir status --porcelain 2>&1
    if (-not $status) {
        Write-Host "  Config unchanged, nothing to push." -ForegroundColor Gray
    } else {
        $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        git -C $syncDir commit -m "Backup config.json — $timestamp" --quiet 2>&1 | Out-Null
        git -C $syncDir push --quiet 2>&1
        if ($LASTEXITCODE -ne 0) {
            # First push to empty repo may need branch setup
            git -C $syncDir push -u origin HEAD --quiet 2>&1 | Out-Null
        }
        Write-Host "  Pushed to $fullRepoName" -ForegroundColor Green
    }
}

# --- Done ---

Write-Host ""
Write-Host "========================================" -ForegroundColor Green
if ($Restore) {
    Write-Host "  Restore Complete!" -ForegroundColor Green
} else {
    Write-Host "  Backup Complete!" -ForegroundColor Green
}
Write-Host "========================================" -ForegroundColor Green
Write-Host ""
if ($Restore) {
    Write-Host "Config restored to: $configFile" -ForegroundColor Gray
} else {
    Write-Host "Repo: https://github.com/$fullRepoName" -ForegroundColor Gray
    Write-Host "To restore: powershell -ExecutionPolicy Bypass -File backup.ps1 -Restore" -ForegroundColor Gray
}
Write-Host ""
