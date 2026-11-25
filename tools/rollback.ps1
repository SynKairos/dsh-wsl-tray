param(
  [string]$Root = '',
  [string]$Distro = '',
  [string]$User = '',
  [string]$Backup = ''
)

$ErrorActionPreference = 'Stop'

# Reverts switch.ps1: stops and disables the systemd unit, restores the files
# from the newest (or the given) backup directory and relaunches the old tray.
# The unit file stays on disk, disabled, so a later switch.ps1 is quick.

if (-not $Root) { $Root = Join-Path $env:LOCALAPPDATA 'dsh' }

function Step([string]$Text) { Write-Output ('== ' + $Text) }
function Ok([string]$Text) { Write-Output ('   ok   ' + $Text) }
function Warn([string]$Text) { Write-Output ('   warn ' + $Text) }

function Wsl([string]$Command) {
  $out = & wsl.exe -d $script:Distro -u $script:LinuxUser -- bash -lc $Command 2>&1
  return @{ Code = $LASTEXITCODE; Text = (($out | Out-String).Trim()) }
}

$cfgPath = Join-Path $Root 'dsh-tray.config.json'
if (-not (Test-Path $cfgPath)) { $cfgPath = Join-Path $PSScriptRoot '..\tray\dsh-tray.config.json' }
$cfg = $null
if (Test-Path $cfgPath) { $cfg = Get-Content -Raw -Encoding UTF8 $cfgPath | ConvertFrom-Json }
if (-not $Distro) { if ($cfg -and $cfg.distro) { $Distro = $cfg.distro } else { $Distro = 'Ubuntu-24.04' } }
if (-not $User) { if ($cfg -and $cfg.user) { $User = $cfg.user } else { $User = $env:USERNAME.ToLower() } }
$script:Distro = $Distro
$script:LinuxUser = $User

if (-not $Backup) {
  $backupRoot = Join-Path $Root 'backup'
  $dirs = @(Get-ChildItem -Directory $backupRoot -ErrorAction SilentlyContinue | Sort-Object Name -Descending)
  if ($dirs.Count -eq 0) { throw ('no backup directory under ' + $backupRoot + '; pass -Backup <dir>') }
  $Backup = $dirs[0].FullName
}
if (-not (Test-Path $Backup)) { throw ('backup not found: ' + $Backup) }

Step ('rollback from ' + $Backup)

foreach ($p in @(Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -match 'dsh-tray\.ps1' })) {
  try { Stop-Process -Id $p.ProcessId -Force -ErrorAction Stop; Ok ('stopped tray pid ' + $p.ProcessId) } catch { Warn ('could not stop tray pid ' + $p.ProcessId) }
}

Step 'stop and disable the systemd unit'
$r = Wsl 'systemctl --user disable --now dsh-web'
if ($r.Code -ne 0) { Warn ('disable failed: ' + $r.Text) } else { Ok 'unit stopped and disabled' }

Step 'restore windows files'
foreach ($f in @('dsh-tray.ps1', 'dsh-tray.vbs', 'dsh-labels.json', 'dsh-tray.config.json')) {
  $src = Join-Path $Backup $f
  if (Test-Path $src) { Copy-Item $src (Join-Path $Root $f) -Force; Ok ('restored ' + $f) }
}

Step 'restore wsl scripts'
$wslHome = '\\wsl.localhost\' + $Distro + '\home\' + $User
try {
  $sh = @(Get-ChildItem (Join-Path $Backup 'dsh-*.sh') -ErrorAction Stop)
  foreach ($f in $sh) { Copy-Item $f.FullName (Join-Path $wslHome 'bin') -Force }
  $r = Wsl ('chmod 755 /home/' + $User + '/bin/dsh-*.sh')
  if ($r.Code -ne 0) { Warn ('chmod failed: ' + $r.Text) } else { Ok ('restored ' + $sh.Count + ' script(s)') }
} catch {
  Warn ('no wsl scripts in the backup; the new ones stay in place')
}

Step 'relaunch the legacy tray'
Start-Process -FilePath (Join-Path $env:WINDIR 'System32\wscript.exe') -ArgumentList ('"' + (Join-Path $Root 'dsh-tray.vbs') + '"')
Ok 'legacy tray started (it will start dsh itself)'
Step 'done'
