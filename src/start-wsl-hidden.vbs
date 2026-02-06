' Launch WSL persistent session + health monitor, completely hidden (no windows)
' Reads WSL distro from config.json if available, otherwise defaults to Ubuntu

Set objShell = CreateObject("WScript.Shell")
Set objFSO = CreateObject("Scripting.FileSystemObject")

' Determine config directory and distro
Dim configDir, configFile, distro
configDir = objShell.ExpandEnvironmentStrings("%USERPROFILE%") & "\.openclaw-windows"
configFile = configDir & "\config.json"
distro = "Ubuntu"

' Try to read distro from config (simple JSON parse for wslDistro)
If objFSO.FileExists(configFile) Then
    Dim content, regex, matches
    content = objFSO.OpenTextFile(configFile, 1).ReadAll()
    Set regex = New RegExp
    regex.Pattern = """wslDistro""\s*:\s*""([^""]+)"""
    Set matches = regex.Execute(content)
    If matches.Count > 0 Then
        distro = matches(0).SubMatches(0)
    End If
End If

' Keep WSL VM alive with a hidden sleep infinity
objShell.Run "wsl.exe -d " & distro & " -- bash -c ""exec sleep infinity""", 0, False

' Launch health monitor tray app (powershell -WindowStyle Hidden = no console window)
Dim startupDir
startupDir = objFSO.GetParentFolderName(WScript.ScriptFullName)
objShell.Run "powershell.exe -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & startupDir & "\wsl-health-monitor.ps1""", 0, False
