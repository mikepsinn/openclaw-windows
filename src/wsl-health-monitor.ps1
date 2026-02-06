# WSL/OpenClaw Health Monitor - System Tray App
# Config-driven persistent tray icon with status, context menu, auto-restart, and toast notifications

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Import-Module BurntToast -ErrorAction SilentlyContinue

# --- Load config ---

$configDir = "$env:USERPROFILE\.openclaw-windows"
$configFile = "$configDir\config.json"

if (-not (Test-Path $configFile)) {
    [System.Windows.Forms.MessageBox]::Show(
        "Config file not found at $configFile`nRun install.ps1 first.",
        "OpenClaw Monitor", "OK", "Error") | Out-Null
    exit 1
}

$cfg = Get-Content $configFile -Raw | ConvertFrom-Json

$distro             = $cfg.wslDistro
$serviceName        = $cfg.serviceName
$servicePort        = $cfg.servicePort
$webUiUrl           = $cfg.webUiUrl
$npmPackage         = $cfg.npmPackage
$npmPrefix          = $cfg.npmPrefix
$checkInterval      = $cfg.checkIntervalSeconds
$autoRestart        = $cfg.autoRestart
$autoRestartCooldown = $cfg.autoRestartCooldownSeconds
$downtimeEscalation = $cfg.downtimeEscalationSeconds
$dailySummaryHour   = $cfg.dailySummaryHour
$tokenJsonPath      = $cfg.tokenJsonPath
$tokenJsonKey       = $cfg.tokenJsonKey
$sessionDir         = $cfg.sessionDir

$logFile = "$configDir\health.log"
$maxLogLines = 500
$updateCheckInterval = 86400
$actionDir = "$configDir\actions"

# Derived paths
$npmPkgDir = "$npmPrefix/lib/node_modules/$npmPackage"

$script:lastState = "unknown"
$script:lastReason = ""
$script:healthySince = $null
$script:downSince = $null
$script:escalationSent = $false
$script:lastAutoRestart = [datetime]::MinValue
$script:lastUpdateCheck = [datetime]::MinValue
$script:updateAvailable = $null
$script:lastSessionFile = ""
$script:lastMessageCount = 0
$script:lastTailscaleState = "unknown"
$script:dailySummarySentDate = ""
$script:dailyConversationCount = 0
$script:dailyDowntimeMinutes = 0
$script:lastCheckWasDown = $false

# --- Icon generation (no external .ico files needed) ---

function New-StatusIcon([string]$color) {
    $bmp = New-Object System.Drawing.Bitmap(16, 16)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = "AntiAlias"
    switch ($color) {
        "green"  { $brush = [System.Drawing.Brushes]::LimeGreen }
        "red"    { $brush = [System.Drawing.Brushes]::Red }
        "yellow" { $brush = [System.Drawing.Brushes]::Gold }
        default  { $brush = [System.Drawing.Brushes]::Gray }
    }
    $g.FillEllipse($brush, 1, 1, 14, 14)
    $g.DrawEllipse([System.Drawing.Pens]::Black, 1, 1, 14, 14)
    $g.Dispose()
    $icon = [System.Drawing.Icon]::FromHandle($bmp.GetHicon())
    return $icon
}

$iconGreen  = New-StatusIcon "green"
$iconRed    = New-StatusIcon "red"
$iconYellow = New-StatusIcon "yellow"
$iconGray   = New-StatusIcon "gray"

# --- Logging with rotation ---

function Write-Log($msg) {
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "$ts $msg" | Add-Content $logFile
}

function Invoke-LogRotation {
    if (Test-Path $logFile) {
        $lines = @(Get-Content $logFile)
        if ($lines.Count -gt $maxLogLines) {
            $lines | Select-Object -Last $maxLogLines | Set-Content $logFile
            Write-Log "LOG: Rotated log (trimmed to last $maxLogLines lines)"
        }
    }
}

# --- Uptime formatting ---

function Get-UptimeString {
    if (-not $script:healthySince) { return "" }
    $span = (Get-Date) - $script:healthySince
    if ($span.TotalMinutes -lt 2) { return "$([int]$span.TotalSeconds)s" }
    if ($span.TotalHours -lt 1) { return "$([int]$span.TotalMinutes)m" }
    if ($span.TotalDays -lt 1) { return "{0}h {1}m" -f [int][math]::Floor($span.TotalHours), $span.Minutes }
    return "{0}d {1}h" -f [int][math]::Floor($span.TotalDays), $span.Hours
}

function Format-TimeSpan([timespan]$span) {
    if ($span.TotalMinutes -lt 1) { return "$([int]$span.TotalSeconds)s" }
    if ($span.TotalHours -lt 1) { return "$([int]$span.TotalMinutes)m" }
    if ($span.TotalDays -lt 1) { return "{0}h {1}m" -f [int][math]::Floor($span.TotalHours), $span.Minutes }
    return "{0}d {1}h" -f [int][math]::Floor($span.TotalDays), $span.Hours
}

# --- Toast notifications (BurntToast for rich toasts, balloon for lightweight) ---

$script:monitorScript = $MyInvocation.MyCommand.Path
$script:hasBurntToast = $null -ne (Get-Module BurntToast -ErrorAction SilentlyContinue)

function Send-RichToast {
    param(
        [string]$Title,
        [string]$Message,
        [string]$Type = "Info",
        [switch]$Persistent,
        [hashtable[]]$Buttons
    )

    if ($script:hasBurntToast) {
        $textItems = @(
            New-BTText -Text $Title
            New-BTText -Text $Message
        )

        $btButtons = @()
        foreach ($btn in $Buttons) {
            switch ($btn.Action) {
                "update" {
                    $btButtons += New-BTButton -Content $btn.Label -Arguments "openclaw-update" -ActivationType Protocol
                }
                "restart" {
                    $btButtons += New-BTButton -Content $btn.Label -Arguments "openclaw-restart" -ActivationType Protocol
                }
                "changelog" {
                    $btButtons += New-BTButton -Content $btn.Label -Arguments "openclaw-changelog" -ActivationType Protocol
                }
                "dismiss" {
                    $btButtons += New-BTButton -Content $btn.Label -DismissButton
                }
                "webui" {
                    $btButtons += New-BTButton -Content $btn.Label -Arguments $webUiUrl -ActivationType Protocol
                }
            }
        }

        $params = @{
            Text = @($Title, $Message)
            AppLogo = $null
        }

        if ($btButtons.Count -gt 0) {
            $params.Button = $btButtons
        }

        if ($Persistent) {
            $params.SnoozeAndDismiss = $false
            $audio = New-BTAudio -Silent
            $binding = New-BTBinding -Children $textItems
            $visual = New-BTVisual -BindingGeneric $binding
            $toastParams = @{
                Visual = $visual
                Audio = $audio
                Duration = "Long"
            }
            if ($btButtons.Count -gt 0) {
                $actions = New-BTAction -Buttons $btButtons
                $toastParams.Actions = $actions
            }
            $content = New-BTContent @toastParams
            Submit-BTNotification -Content $content
        } else {
            New-BurntToastNotification @params
        }
    } else {
        $iconType = switch ($Type) { "Error" { "Error" } "Warning" { "Warning" } default { "Info" } }
        $trayIcon.BalloonTipTitle = $Title
        $trayIcon.BalloonTipText = $Message
        $trayIcon.BalloonTipIcon = $iconType
        $trayIcon.ShowBalloonTip(15000)
    }
}

# Register protocol handlers for toast button actions
function Register-ToastActions {
    if (-not (Test-Path $actionDir)) { New-Item -Path $actionDir -ItemType Directory -Force | Out-Null }

    # Copy action scripts from install location if they exist, otherwise create inline
    $updateScript = "$actionDir\update.ps1"
    $restartScript = "$actionDir\restart.ps1"
    $changelogScript = "$actionDir\changelog.ps1"

    # Only create if not already present (install.ps1 puts them here)
    if (-not (Test-Path $updateScript)) {
        @"
`$cfg = Get-Content "$configFile" -Raw | ConvertFrom-Json
wsl.exe -d `$cfg.wslDistro -e bash -c "npm update -g `$(`$cfg.npmPackage) 2>&1" | Out-Null
wsl.exe -d `$cfg.wslDistro -e bash -c "systemctl --user restart `$(`$cfg.serviceName)" 2>&1
"@ | Set-Content $updateScript
    }

    if (-not (Test-Path $restartScript)) {
        @"
`$cfg = Get-Content "$configFile" -Raw | ConvertFrom-Json
wsl.exe -d `$cfg.wslDistro -e bash -c "systemctl --user restart `$(`$cfg.serviceName)" 2>&1
"@ | Set-Content $restartScript
    }

    if (-not (Test-Path $changelogScript)) {
        @"
`$cfg = Get-Content "$configFile" -Raw | ConvertFrom-Json
`$pkgDir = "`$(`$cfg.npmPrefix)/lib/node_modules/`$(`$cfg.npmPackage)"
`$changelogDest = "$configDir\changelog.md"
`$content = wsl.exe -d `$cfg.wslDistro -e bash -c "cat `$pkgDir/CHANGELOG.md 2>/dev/null"
if (`$content) {
    `$content | Set-Content `$changelogDest
    Start-Process notepad.exe `$changelogDest
}
"@ | Set-Content $changelogScript
    }

    # Register URI protocol handlers
    $protocols = @(
        @{ Name = "openclaw-update";    Script = $updateScript;    Visible = $true },
        @{ Name = "openclaw-restart";   Script = $restartScript;   Visible = $true },
        @{ Name = "openclaw-changelog"; Script = $changelogScript; Visible = $false }
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
    }
}

Register-ToastActions

# --- Build tray icon and context menu ---

$trayIcon = New-Object System.Windows.Forms.NotifyIcon
$trayIcon.Icon = $iconGray
$trayIcon.Text = "OpenClaw: starting..."
$trayIcon.Visible = $true

$contextMenu = New-Object System.Windows.Forms.ContextMenuStrip

# Status (disabled, info only)
$menuStatus = New-Object System.Windows.Forms.ToolStripMenuItem
$menuStatus.Text = "Status: starting..."
$menuStatus.Enabled = $false
$contextMenu.Items.Add($menuStatus) | Out-Null

# Uptime (disabled, info only)
$menuUptime = New-Object System.Windows.Forms.ToolStripMenuItem
$menuUptime.Text = "Uptime: --"
$menuUptime.Enabled = $false
$contextMenu.Items.Add($menuUptime) | Out-Null

# Tailscale status (disabled, info only)
$menuTailscale = New-Object System.Windows.Forms.ToolStripMenuItem
$menuTailscale.Text = "Tailscale: --"
$menuTailscale.Enabled = $false
$contextMenu.Items.Add($menuTailscale) | Out-Null

# Update available (hidden by default)
$menuUpdate = New-Object System.Windows.Forms.ToolStripMenuItem
$menuUpdate.Text = "Update available!"
$menuUpdate.ForeColor = [System.Drawing.Color]::DarkOrange
$menuUpdate.Visible = $false
$menuUpdate.Add_Click({
    Write-Log "USER: Update requested from tray menu"
    $menuUpdate.Text = "Updating..."
    wsl.exe -d $distro -e bash -c "npm update -g $npmPackage 2>&1" | Out-Null
    wsl.exe -d $distro -e bash -c "systemctl --user restart $serviceName" 2>&1 | Out-Null
    $menuUpdate.Visible = $false
    $script:updateAvailable = $null
    Write-Log "USER: Update + restart complete"
})
$contextMenu.Items.Add($menuUpdate) | Out-Null

$contextMenu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null

# Recent conversations submenu (only if sessionDir is configured)
$menuConversations = $null
if ($sessionDir) {
    $menuConversations = New-Object System.Windows.Forms.ToolStripMenuItem
    $menuConversations.Text = "Recent Messages"
    $contextMenu.Items.Add($menuConversations) | Out-Null
    $contextMenu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null
}

# Restart service
$menuRestart = New-Object System.Windows.Forms.ToolStripMenuItem
$menuRestart.Text = "Restart $serviceName"
$menuRestart.Add_Click({
    Write-Log "USER: Restart requested from tray menu"
    $menuStatus.Text = "Status: restarting..."
    $trayIcon.Icon = $iconYellow
    $trayIcon.Text = "OpenClaw: restarting..."
    wsl.exe -d $distro -e bash -c "systemctl --user restart $serviceName" 2>&1 | Out-Null
    Write-Log "USER: Restart command sent"
})
$contextMenu.Items.Add($menuRestart) | Out-Null

# Copy auth token (only if tokenJsonPath is configured)
if ($tokenJsonPath) {
    $menuCopyToken = New-Object System.Windows.Forms.ToolStripMenuItem
    $menuCopyToken.Text = "Copy Auth Token"
    $menuCopyToken.Add_Click({
        $jqFilter = ".$tokenJsonKey // empty"
        $token = wsl.exe -d $distro -e bash -c "cat $tokenJsonPath 2>/dev/null | jq -r '$jqFilter'"
        if ($token) {
            [System.Windows.Forms.Clipboard]::SetText($token.Trim())
            $trayIcon.BalloonTipTitle = "Token Copied"
            $trayIcon.BalloonTipText = "Auth token copied to clipboard"
            $trayIcon.BalloonTipIcon = "Info"
            $trayIcon.ShowBalloonTip(3000)
        } else {
            $trayIcon.BalloonTipTitle = "Token Error"
            $trayIcon.BalloonTipText = "Could not read auth token from config"
            $trayIcon.BalloonTipIcon = "Warning"
            $trayIcon.ShowBalloonTip(5000)
        }
    })
    $contextMenu.Items.Add($menuCopyToken) | Out-Null
}

# Open Web UI (only if webUiUrl is configured)
if ($webUiUrl) {
    $menuOpenUI = New-Object System.Windows.Forms.ToolStripMenuItem
    $menuOpenUI.Text = "Open Web UI"
    $menuOpenUI.Add_Click({
        Start-Process $webUiUrl
    })
    $contextMenu.Items.Add($menuOpenUI) | Out-Null
}

# View Log
$menuViewLog = New-Object System.Windows.Forms.ToolStripMenuItem
$menuViewLog.Text = "View Log"
$menuViewLog.Add_Click({
    Start-Process notepad.exe $logFile
})
$contextMenu.Items.Add($menuViewLog) | Out-Null

$contextMenu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null

# Quick-access folders submenu (from config)
if ($cfg.quickLinks -and $cfg.quickLinks.Count -gt 0) {
    $menuFolders = New-Object System.Windows.Forms.ToolStripMenuItem
    $menuFolders.Text = "Open Folder"

    foreach ($link in $cfg.quickLinks) {
        $item = New-Object System.Windows.Forms.ToolStripMenuItem
        $item.Text = $link.name
        $expandedPath = [System.Environment]::ExpandEnvironmentVariables($link.path)
        $item.Add_Click({ Start-Process explorer.exe $expandedPath }.GetNewClosure())
        $menuFolders.DropDownItems.Add($item) | Out-Null
    }

    # Always add startup folder and health log
    $startupPath = "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup"
    $itemStartup = New-Object System.Windows.Forms.ToolStripMenuItem
    $itemStartup.Text = "Startup Folder"
    $itemStartup.Add_Click({ Start-Process explorer.exe $startupPath }.GetNewClosure())
    $menuFolders.DropDownItems.Add($itemStartup) | Out-Null

    $itemLog = New-Object System.Windows.Forms.ToolStripMenuItem
    $itemLog.Text = "Health Log"
    $itemLog.Add_Click({ Start-Process explorer.exe $logFile }.GetNewClosure())
    $menuFolders.DropDownItems.Add($itemLog) | Out-Null

    $contextMenu.Items.Add($menuFolders) | Out-Null
    $contextMenu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null
}

# Exit
$menuExit = New-Object System.Windows.Forms.ToolStripMenuItem
$menuExit.Text = "Exit Monitor"
$menuExit.Add_Click({
    Write-Log "USER: Exit requested from tray menu"
    $trayIcon.Visible = $false
    $trayIcon.Dispose()
    [System.Windows.Forms.Application]::Exit()
})
$contextMenu.Items.Add($menuExit) | Out-Null

$trayIcon.ContextMenuStrip = $contextMenu

# Double-click tray icon opens the web UI
if ($webUiUrl) {
    $trayIcon.Add_DoubleClick({
        Start-Process $webUiUrl
    })
}

# --- Refresh recent conversations submenu ---

function Update-ConversationsMenu {
    if (-not $menuConversations) { return }
    $menuConversations.DropDownItems.Clear()

    $messages = wsl.exe -d $distro -e bash -c @"
LATEST=`$(ls -t $sessionDir/*.jsonl 2>/dev/null | head -1)
if [ -n "`$LATEST" ]; then
    cat "`$LATEST" | jq -r 'select(.message.role == "user") | .message.content[0].text // empty' 2>/dev/null | tail -8
fi
"@ 2>&1

    if ($messages) {
        $lines = @($messages -split "`n" | Where-Object { $_.Trim() })
        if ($lines.Count -eq 0) {
            $empty = New-Object System.Windows.Forms.ToolStripMenuItem
            $empty.Text = "(no messages)"
            $empty.Enabled = $false
            $menuConversations.DropDownItems.Add($empty) | Out-Null
        } else {
            foreach ($line in $lines) {
                $display = if ($line.Length -gt 80) { $line.Substring(0, 77) + "..." } else { $line }
                $item = New-Object System.Windows.Forms.ToolStripMenuItem
                $item.Text = $display
                $item.Enabled = $false
                $menuConversations.DropDownItems.Add($item) | Out-Null
            }
        }
    } else {
        $empty = New-Object System.Windows.Forms.ToolStripMenuItem
        $empty.Text = "(could not read sessions)"
        $empty.Enabled = $false
        $menuConversations.DropDownItems.Add($empty) | Out-Null
    }
}

if ($menuConversations) {
    $menuConversations.Add_DropDownOpening({ Update-ConversationsMenu })
}

# --- Auto-restart logic ---

function Invoke-AutoRestart([string]$reason) {
    if (-not $autoRestart) { return $false }

    $now = Get-Date
    $elapsed = ($now - $script:lastAutoRestart).TotalSeconds
    if ($elapsed -lt $autoRestartCooldown) {
        $remaining = [int]($autoRestartCooldown - $elapsed)
        Write-Log "AUTO-RESTART: Skipped (cooldown, ${remaining}s remaining)"
        return $false
    }

    Write-Log "AUTO-RESTART: Attempting restart (reason: $reason)"
    $trayIcon.Icon = $iconYellow
    $trayIcon.Text = "OpenClaw: auto-restarting..."
    $menuStatus.Text = "Status: auto-restarting..."

    wsl.exe -d $distro -e bash -c "systemctl --user restart $serviceName" 2>&1 | Out-Null
    $script:lastAutoRestart = $now
    Write-Log "AUTO-RESTART: Restart command sent, will recheck next cycle"
    return $true
}

# --- Downtime escalation ---

function Check-DowntimeEscalation {
    if (-not $script:downSince) { return }
    if ($script:escalationSent) { return }

    $downtime = (Get-Date) - $script:downSince
    if ($downtime.TotalSeconds -ge $downtimeEscalation) {
        $downtimeStr = Format-TimeSpan $downtime
        $msg = "OpenClaw has been down for $downtimeStr! Auto-restart has not resolved the issue. Reason: $($script:lastReason)"
        Write-Log "ESCALATION: $msg"
        Send-RichToast -Title "OpenClaw DOWN $downtimeStr" `
            -Message $msg `
            -Type "Error" -Persistent `
            -Buttons @(
                @{ Label = "Restart Now"; Action = "restart" },
                @{ Label = "Open Web UI"; Action = "webui" },
                @{ Label = "Dismiss"; Action = "dismiss" }
            )
        $script:escalationSent = $true
    }
}

# --- Conversation activity monitor ---

function Check-ConversationActivity {
    if (-not $sessionDir) { return }

    $result = wsl.exe -d $distro -e bash -c @"
LATEST=`$(ls -t $sessionDir/*.jsonl 2>/dev/null | head -1)
if [ -n "`$LATEST" ]; then
    COUNT=`$(cat "`$LATEST" | jq -r 'select(.message.role == "user") | .message.content[0].text // empty' 2>/dev/null | grep -c .)
    LAST_MSG=`$(cat "`$LATEST" | jq -r 'select(.message.role == "user") | .message.content[0].text // empty' 2>/dev/null | tail -1)
    echo "`$LATEST|`$COUNT|`$LAST_MSG"
fi
"@ 2>&1

    if (-not $result -or $result -notmatch '\|') { return }

    $parts = $result -split '\|', 3
    $sessionFile = $parts[0].Trim()
    $msgCount = 0
    [int]::TryParse($parts[1].Trim(), [ref]$msgCount) | Out-Null
    $lastMsg = if ($parts.Count -ge 3) { $parts[2].Trim() } else { "" }

    # New session started
    if ($sessionFile -ne $script:lastSessionFile -and $script:lastSessionFile -ne "") {
        $script:dailyConversationCount++
        $preview = if ($lastMsg.Length -gt 60) { $lastMsg.Substring(0, 57) + "..." } else { $lastMsg }
        Write-Log "ACTIVITY: New conversation started - '$preview'"
        $trayIcon.BalloonTipTitle = "New Conversation"
        $trayIcon.BalloonTipText = if ($preview) { $preview } else { "Someone started chatting with OpenClaw" }
        $trayIcon.BalloonTipIcon = "Info"
        $trayIcon.ShowBalloonTip(8000)
    }
    # New message in existing session
    elseif ($sessionFile -eq $script:lastSessionFile -and $msgCount -gt $script:lastMessageCount -and $script:lastMessageCount -gt 0) {
        $newMsgs = $msgCount - $script:lastMessageCount
        if ($newMsgs -ge 1) {
            $preview = if ($lastMsg.Length -gt 60) { $lastMsg.Substring(0, 57) + "..." } else { $lastMsg }
            Write-Log "ACTIVITY: $newMsgs new message(s) - '$preview'"
            if ($script:lastMessageCount -eq 0 -or $newMsgs -eq 1) {
                $trayIcon.BalloonTipTitle = "New Message"
                $trayIcon.BalloonTipText = if ($preview) { $preview } else { "New message received" }
                $trayIcon.BalloonTipIcon = "Info"
                $trayIcon.ShowBalloonTip(5000)
            }
        }
    }

    $script:lastSessionFile = $sessionFile
    $script:lastMessageCount = $msgCount
}

# --- Tailscale connectivity check ---

function Check-Tailscale {
    $tsStatus = wsl.exe -d $distro -e bash -c "tailscale status --json 2>/dev/null | jq -r '.BackendState // empty'" 2>&1
    $tsState = if ($tsStatus) { $tsStatus.Trim() } else { "unknown" }

    if ($tsState -eq "Running") {
        $menuTailscale.Text = "Tailscale: connected"
    } else {
        $menuTailscale.Text = "Tailscale: $tsState"
    }

    if ($tsState -ne $script:lastTailscaleState) {
        if ($tsState -ne "Running" -and $script:lastTailscaleState -ne "unknown") {
            Write-Log "TAILSCALE: State changed to '$tsState' (was '$($script:lastTailscaleState)')"
            $trayIcon.BalloonTipTitle = "Tailscale Disconnected"
            $trayIcon.BalloonTipText = "Tailscale state: $tsState. Remote access may be unavailable."
            $trayIcon.BalloonTipIcon = "Warning"
            $trayIcon.ShowBalloonTip(15000)
        }
        elseif ($tsState -eq "Running" -and $script:lastTailscaleState -ne "unknown") {
            Write-Log "TAILSCALE: Reconnected (was '$($script:lastTailscaleState)')"
            $trayIcon.BalloonTipTitle = "Tailscale Connected"
            $trayIcon.BalloonTipText = "Tailscale is back online. Remote access restored."
            $trayIcon.BalloonTipIcon = "Info"
            $trayIcon.ShowBalloonTip(8000)
        }
        $script:lastTailscaleState = $tsState
    }
}

# --- Daily summary ---

function Check-DailySummary {
    $now = Get-Date
    $today = $now.ToString("yyyy-MM-dd")

    if ($today -ne $script:dailySummarySentDate -and $script:dailySummarySentDate -ne "" -and $now.Hour -lt $dailySummaryHour) {
        $script:dailyConversationCount = 0
        $script:dailyDowntimeMinutes = 0
    }

    if ($now.Hour -ge $dailySummaryHour -and $today -ne $script:dailySummarySentDate) {
        $uptimeStr = Get-UptimeString
        $uptimePart = if ($uptimeStr) { "Uptime: $uptimeStr" } else { "Uptime: N/A" }
        $convPart = "$($script:dailyConversationCount) conversation(s) today"
        $downtimePart = if ($script:dailyDowntimeMinutes -gt 0) { ", $($script:dailyDowntimeMinutes)m downtime" } else { ", no downtime" }

        $summary = "$uptimePart, $convPart$downtimePart"
        Write-Log "DAILY SUMMARY: $summary"
        $trayIcon.BalloonTipTitle = "OpenClaw Daily Summary"
        $trayIcon.BalloonTipText = $summary
        $trayIcon.BalloonTipIcon = "Info"
        $trayIcon.ShowBalloonTip(10000)

        $script:dailySummarySentDate = $today
    }
}

# --- Update check ---

function Get-ChangelogSummary {
    $summary = wsl.exe -d $distro -e bash -c @"
PKG_DIR=$npmPkgDir
CHANGELOG="`$PKG_DIR/CHANGELOG.md"
CURRENT=`$(cat "`$PKG_DIR/package.json" 2>/dev/null | jq -r '.version // empty')
LATEST=`$(npm view $npmPackage version 2>/dev/null)

if [ -z "`$CURRENT" ] || [ -z "`$LATEST" ] || [ "`$CURRENT" = "`$LATEST" ]; then
    exit 0
fi

if [ ! -f "`$CHANGELOG" ]; then
    exit 0
fi

sed -n "/^## .*`$LATEST/,/^## .*`$CURRENT/p" "`$CHANGELOG" | grep -E '^[-*]' | head -6
"@ 2>&1

    if ($summary) {
        $lines = @($summary -split "`n" | Where-Object { $_.Trim() } | Select-Object -First 4)
        if ($lines.Count -gt 0) {
            return ($lines -join "`n")
        }
    }
    return $null
}

function Check-ForUpdate {
    $now = Get-Date
    if (($now - $script:lastUpdateCheck).TotalSeconds -lt $updateCheckInterval) { return }
    $script:lastUpdateCheck = $now

    $outdated = wsl.exe -d $distro -e bash -c "npm outdated -g $npmPackage 2>/dev/null | tail -1" 2>&1
    if ($outdated -and $outdated -match $npmPackage) {
        if (-not $script:updateAvailable) {
            $script:updateAvailable = $outdated.Trim()
            $menuUpdate.Text = "Update available: $($script:updateAvailable)"
            $menuUpdate.Visible = $true
            Write-Log "UPDATE: $($script:updateAvailable)"

            $changelogSummary = Get-ChangelogSummary
            $toastMessage = $script:updateAvailable
            if ($changelogSummary) {
                $toastMessage = "$($script:updateAvailable)`n$changelogSummary"
            }

            Send-RichToast -Title "OpenClaw Update Available" `
                -Message $toastMessage `
                -Type "Info" -Persistent `
                -Buttons @(
                    @{ Label = "Update Now"; Action = "update" },
                    @{ Label = "View Changes"; Action = "changelog" },
                    @{ Label = "Dismiss"; Action = "dismiss" }
                )
        }
    } else {
        $menuUpdate.Visible = $false
        $script:updateAvailable = $null
    }
}

# --- Health check logic ---

function Update-Status([string]$status, [string]$reason) {
    if ($status -eq "ok" -and -not $script:healthySince) {
        $script:healthySince = Get-Date
    } elseif ($status -ne "ok") {
        $script:healthySince = $null
    }

    if ($status -eq "down") {
        if (-not $script:downSince) {
            $script:downSince = Get-Date
            $script:escalationSent = $false
        }
        $script:dailyDowntimeMinutes += [int]($checkInterval / 60)
    } else {
        $script:downSince = $null
        $script:escalationSent = $false
    }

    $uptimeStr = Get-UptimeString
    if ($status -eq "ok") {
        $trayIcon.Icon = $iconGreen
        $tooltipUptime = if ($uptimeStr) { " (up $uptimeStr)" } else { "" }
        $trayIcon.Text = "OpenClaw: healthy$tooltipUptime"
        $menuStatus.Text = "Status: healthy"
        $menuUptime.Text = if ($uptimeStr) { "Uptime: $uptimeStr" } else { "Uptime: just started" }
    }
    elseif ($status -eq "down") {
        $trayIcon.Icon = $iconRed
        $shortReason = if ($reason.Length -gt 60) { $reason.Substring(0, 60) + "..." } else { $reason }
        $trayIcon.Text = "OpenClaw: DOWN"
        $menuStatus.Text = "Status: DOWN - $shortReason"
        $menuUptime.Text = "Uptime: --"
    }

    if ($status -ne $script:lastState) {
        if ($status -eq "down") {
            Write-Log "ALERT: $reason"
            $trayIcon.BalloonTipTitle = "OpenClaw Down"
            $trayIcon.BalloonTipText = $reason
            $trayIcon.BalloonTipIcon = "Error"
            $trayIcon.ShowBalloonTip(15000)
        }
        elseif ($script:lastState -eq "down") {
            Write-Log "RECOVERED: OpenClaw is back up"
            $trayIcon.BalloonTipTitle = "OpenClaw Recovered"
            $trayIcon.BalloonTipText = "Gateway is back online"
            $trayIcon.BalloonTipIcon = "Info"
            $trayIcon.ShowBalloonTip(10000)
        }
        elseif ($script:lastState -eq "unknown" -and $status -eq "ok") {
            Write-Log "OK: Initial check passed - OpenClaw is healthy"
            Send-RichToast -Title "OpenClaw Ready" `
                -Message "Gateway is up and accepting connections" `
                -Type "Info" `
                -Buttons @(
                    @{ Label = "Open Web UI"; Action = "webui" },
                    @{ Label = "Dismiss"; Action = "dismiss" }
                )
        }
        $script:lastState = $status
        $script:lastReason = $reason
    }
}

function Run-HealthCheck {
    $status = "ok"
    $reason = ""
    $wslUp = $false

    # Check 1: Is WSL running?
    $wslStatus = wsl.exe -d $distro -e bash -c "echo ok" 2>&1
    if ($wslStatus -ne "ok") {
        $status = "down"
        $reason = "WSL $distro is not running"
    }
    else {
        $wslUp = $true
        # Check 2: Is the service active?
        $svcStatus = wsl.exe -d $distro -e bash -c "systemctl --user is-active $serviceName 2>/dev/null"
        if ($svcStatus -ne "active") {
            $status = "down"
            $failReason = wsl.exe -d $distro -e bash -c "systemctl --user status $serviceName --no-pager 2>&1 | head -3"
            $reason = "$serviceName service is $svcStatus. $failReason"
        }
        else {
            # Check 3: Is the gateway port listening?
            $portCheck = wsl.exe -d $distro -e bash -c "ss -tlnp 2>/dev/null | grep -q $servicePort && echo listening"
            if ($portCheck -ne "listening") {
                $status = "down"
                $reason = "$serviceName running but port $servicePort not listening"
            }
        }
    }

    # Auto-restart on failure (if WSL is up but service is down)
    if ($status -eq "down" -and $wslUp) {
        Invoke-AutoRestart $reason
    }

    Update-Status $status $reason

    # Additional checks only when WSL is reachable
    if ($wslUp) {
        if ($status -eq "down") {
            Check-DowntimeEscalation
        }
        Check-Tailscale
        if ($status -eq "ok") {
            Check-ConversationActivity
            Check-ForUpdate
        }
        Check-DailySummary
    }
}

# --- Startup ---

Invoke-LogRotation
Write-Log "Health monitor started (tray app), waiting 45s for WSL boot..."

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = $checkInterval * 1000
$timer.Add_Tick({ Run-HealthCheck })

# Initial check after 45s delay
$startupTimer = New-Object System.Windows.Forms.Timer
$startupTimer.Interval = 45000
$startupTimer.Add_Tick({
    $startupTimer.Stop()
    $startupTimer.Dispose()
    Write-Log "Initial wait complete, beginning health checks"
    Run-HealthCheck
    $timer.Start()
})
$startupTimer.Start()

# Run the Windows Forms message loop (keeps tray icon alive and responsive)
[System.Windows.Forms.Application]::Run()
