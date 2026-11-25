$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

# Creates the desktop shortcut that starts the tray through wscript (no console).
# All paths come from the environment; nothing is machine-specific.

$root    = Join-Path $env:LOCALAPPDATA 'dsh'
$desktop = [Environment]::GetFolderPath('Desktop')
$lnk     = Join-Path $desktop 'DeepSeek Harness.lnk'
$icon    = Join-Path $root 'dsh-icon.ico'
$vbs     = Join-Path $root 'dsh-tray.vbs'

foreach ($f in @($icon, $vbs)) {
  if (-not (Test-Path $f)) { throw "missing: $f" }
}

$wsh = New-Object -ComObject WScript.Shell
$sc  = $wsh.CreateShortcut($lnk)
$sc.TargetPath       = Join-Path $env:WINDIR 'System32\wscript.exe'
$sc.Arguments        = '"' + $vbs + '"'
$sc.WorkingDirectory = $env:USERPROFILE
$sc.IconLocation     = "$icon,0"
$sc.Description      = 'DeepSeek Harness (WSL) - tray launcher'
$sc.WindowStyle      = 1
$sc.Save()

$v = $wsh.CreateShortcut($lnk)
@(
  "lnk=$lnk",
  "exists=$(Test-Path $lnk)",
  "target=$($v.TargetPath)",
  "arguments=$($v.Arguments)",
  "icon=$($v.IconLocation)",
  "vbs_exists=$(Test-Path $vbs)",
  "ps1_exists=$(Test-Path (Join-Path $root 'dsh-tray.ps1'))",
  "labels_exists=$(Test-Path (Join-Path $root 'dsh-labels.json'))"
)
