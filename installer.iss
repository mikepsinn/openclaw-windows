#ifndef MyAppVersion
  #define MyAppVersion "0.0.0"
#endif

#define MyAppName "OpenClaw Windows"
#define MyAppPublisher "OpenClaw"
#define MyAppURL "https://github.com/peterb/openclaw-windows"

[Setup]
AppId={{E8F1A3B7-5C2D-4F6E-9A1B-3D7C8E2F4A5B}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
AppPublisherURL={#MyAppURL}
AppSupportURL={#MyAppURL}
DefaultDirName={localappdata}\{#MyAppName}
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
OutputBaseFilename=openclaw-windows-setup-{#MyAppVersion}
Compression=lzma
SolidCompression=yes
WizardStyle=modern

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Files]
Source: "src\*"; DestDir: "{app}\src"; Flags: ignoreversion recursesubdirs
Source: "actions\*"; DestDir: "{app}\actions"; Flags: ignoreversion recursesubdirs
Source: "install.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "uninstall.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "config.example.json"; DestDir: "{app}"; Flags: ignoreversion
Source: "backup.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "README.md"; DestDir: "{app}"; Flags: ignoreversion
Source: "LICENSE"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{group}\OpenClaw Monitor"; Filename: "wscript.exe"; Parameters: "//nologo ""{app}\src\start-wsl-hidden.vbs"""; Comment: "Start the OpenClaw health monitor"
Name: "{group}\Reconfigure OpenClaw"; Filename: "powershell.exe"; Parameters: "-ExecutionPolicy Bypass -File ""{app}\install.ps1"""; Comment: "Re-run the OpenClaw configuration wizard"

[Run]
Filename: "powershell.exe"; Parameters: "-ExecutionPolicy Bypass -File ""{app}\install.ps1"""; Description: "Configure OpenClaw (sets up WSL, creates config)"; Flags: postinstall nowait skipifsilent

[UninstallRun]
Filename: "powershell.exe"; Parameters: "-ExecutionPolicy Bypass -File ""{app}\uninstall.ps1"" -Force"; Flags: runhidden waituntilterminated
