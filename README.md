# openclaw-windows

One-command installer and system tray monitor for running [OpenClaw](https://github.com/anthropics/openclaw) on Windows via WSL2.

## Features

- **One-command install** — sets up OpenClaw in WSL, configures systemd, installs startup files
- **System tray monitor** — green/red/yellow status icon with health checks every 60s
- **Auto-restart** — automatically restarts OpenClaw if it goes down, with cooldown
- **Toast notifications** — rich Windows 10/11 toasts with action buttons (Update, Restart, View Changelog)
- **Tailscale monitoring** — tracks Tailscale connectivity for remote access
- **Conversation activity** — notifies when new messages arrive in OpenClaw sessions
- **Daily summary** — uptime, conversation count, and downtime report at 9 PM
- **Update detection** — checks for new npm versions daily, shows changelog diff
- **Config-driven** — all settings in one JSON file, no hardcoded paths

## Quick Start

```powershell
git clone https://github.com/mikepsinn/openclaw-windows.git
cd openclaw-windows
powershell -ExecutionPolicy Bypass -File install.ps1
```

## Prerequisites

- Windows 10/11 with WSL2
- A WSL distro (Ubuntu recommended): `wsl --install -d Ubuntu`
- Node.js + npm in WSL

## What the Installer Does

| Step | Action |
|------|--------|
| 1 | Checks WSL2, distro, npm |
| 2 | Installs OpenClaw via `npm install -g openclaw` (if needed) |
| 3 | Enables systemd in WSL (`/etc/wsl.conf`) |
| 4 | Sets `vmIdleTimeout=-1` in `.wslconfig` to prevent WSL shutdown |
| 5 | Creates config at `~\.openclaw-windows\config.json` |
| 6 | Copies startup files to Windows Startup folder |
| 7 | Copies action scripts for toast buttons |
| 8 | Registers `openclaw-update://`, `openclaw-restart://`, `openclaw-changelog://` protocol handlers |
| 9 | Installs [BurntToast](https://github.com/Windos/BurntToast) PowerShell module for rich toasts |
| 10 | Launches the tray monitor |

## Configuration

All settings are in `~\.openclaw-windows\config.json`:

```json
{
  "wslDistro": "Ubuntu",
  "serviceName": "openclaw",
  "servicePort": 18789,
  "webUiUrl": "https://your-machine.taile3dff1.ts.net",
  "npmPackage": "openclaw",
  "npmPrefix": "/home/user/.npm-global",
  "checkIntervalSeconds": 60,
  "autoRestart": true,
  "autoRestartCooldownSeconds": 300,
  "downtimeEscalationSeconds": 600,
  "dailySummaryHour": 21,
  "tokenJsonPath": "~/.openclaw/openclaw.json",
  "tokenJsonKey": "gateway.auth.token",
  "sessionDir": "~/.openclaw/agents/main/sessions",
  "quickLinks": [
    { "name": "Startup Folder", "path": "%APPDATA%\\Microsoft\\Windows\\Start Menu\\Programs\\Startup" }
  ]
}
```

| Key | Description |
|-----|-------------|
| `wslDistro` | WSL distribution name |
| `serviceName` | systemd service name |
| `servicePort` | Gateway port to health-check |
| `webUiUrl` | URL opened by "Open Web UI" and double-click |
| `npmPackage` | npm package name for updates |
| `npmPrefix` | npm global prefix path in WSL |
| `checkIntervalSeconds` | Seconds between health checks |
| `autoRestart` | Enable/disable auto-restart on failure |
| `autoRestartCooldownSeconds` | Minimum seconds between auto-restart attempts |
| `downtimeEscalationSeconds` | Seconds of continuous downtime before escalated notification |
| `dailySummaryHour` | Hour (0-23) to send daily summary toast |
| `tokenJsonPath` | Path in WSL to read auth token from |
| `tokenJsonKey` | JSON key path for the auth token |
| `sessionDir` | Path in WSL to session JSONL files |
| `quickLinks` | Folders shown in the tray "Open Folder" submenu |

## Tray Menu

Right-click the tray icon:

- **Status** — current health state
- **Uptime** — time since last healthy start
- **Tailscale** — VPN connectivity state
- **Update available** — appears when a new version is detected
- **Recent Messages** — last 8 user messages from the active session
- **Restart** — manually restart the service
- **Copy Auth Token** — copy gateway auth token to clipboard
- **Open Web UI** — open the web interface in browser
- **View Log** — open the health log in Notepad
- **Open Folder** — quick-access to configured directories
- **Exit Monitor** — stop the tray app

Double-click the icon to open the Web UI.

## File Layout

```
~\.openclaw-windows\
├── config.json          # Your settings
├── health.log           # Health check log (auto-rotated)
└── actions\
    ├── update.ps1       # Toast: update OpenClaw
    ├── restart.ps1      # Toast: restart service
    └── changelog.ps1    # Toast: view changelog

Startup Folder\
├── start-wsl.bat        # Entry point (runs on login)
├── start-wsl-hidden.vbs # Hides console windows
└── wsl-health-monitor.ps1  # The tray app
```

## Uninstall

```powershell
powershell -ExecutionPolicy Bypass -File uninstall.ps1
```

This removes:
- Startup folder files
- Protocol handler registry entries
- Config directory and logs

Add `-KeepConfig` to preserve your `config.json`:
```powershell
powershell -ExecutionPolicy Bypass -File uninstall.ps1 -KeepConfig
```

OpenClaw itself remains installed in WSL. To remove it:
```bash
wsl -e bash -c "npm uninstall -g openclaw"
```

## Config Backup

Back up your `config.json` to a private GitHub repo:

```powershell
# Backup
powershell -ExecutionPolicy Bypass -File backup.ps1

# Restore on a new machine
powershell -ExecutionPolicy Bypass -File backup.ps1 -Restore
```

Requires [GitHub CLI](https://cli.github.com/) (`gh`) to be installed and authenticated.

## License

MIT
