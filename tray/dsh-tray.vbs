' dsh-tray.vbs - launch the tray without a console window.
' Every path is derived from the environment, so the folder can sit anywhere in
' the user profile. Keep this file pure ASCII: cscript reads it as ANSI.

Set sh  = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

base  = sh.ExpandEnvironmentStrings("%LOCALAPPDATA%") & "\dsh"
pwsh7 = sh.ExpandEnvironmentStrings("%LOCALAPPDATA%") & "\Microsoft\WindowsApps\pwsh.exe"

If fso.FileExists(pwsh7) Then
  exe = """" & pwsh7 & """ -Sta -NoProfile -ExecutionPolicy Bypass"
Else
  exe = "powershell.exe -Sta -NoProfile -ExecutionPolicy Bypass"
End If

script = base & "\dsh-tray.ps1"

If Not fso.FileExists(script) Then
  MsgBox "dsh-tray.ps1 not found:" & vbCrLf & script, 16, "DeepSeek Harness"
  WScript.Quit 1
End If

sh.Run exe & " -File """ & script & """", 0, False
