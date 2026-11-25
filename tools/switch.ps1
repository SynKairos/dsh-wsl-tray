param(
  [string]$Root = '',
  [string]$Distro = '',
  [string]$User = '',
  [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

# One-time cutover from the legacy tray (which owned the dsh process) to the
# systemd-backed layout. It backs everything up first, so rollback.ps1 can undo
# it. This stops the running dsh, which ends any open agent session: run it
# when no long task is in flight.

$repo = Split-Path $PSScriptRoot -Parent
if (-not $Root) { $Root = Join-Path $env:LOCALAPPDATA 'dsh' }

function Step([string]$Text) { Write-Output ('== ' + $Text) }
function Ok([string]$Text) { Write-Output ('   ok   ' + $Text) }
function Warn([string]$Text) { Write-Output ('   warn ' + $Text) }
function Say([string]$Text) { Write-Output ('   ' + $Text) }

function Wsl([string]$Command) {
  $out = & wsl.exe -d $script:Distro -u $script:LinuxUser -- bash -lc $Command 2>&1
  return @{ Code = $LASTEXITCODE; Text = (($out | Out-String).Trim()) }
}

$cfgPath = Join-Path $Root 'dsh-tray.config.json'
if (-not (Test-Path $cfgPath)) { $cfgPath = Join-Path $repo 'tray\dsh-tray.config.json' }
$cfg = Get-Content -Raw -Encoding UTF8 $cfgPath | ConvertFrom-Json
if (-not $Distro) { if ($cfg.distro) { $Distro = $cfg.distro } else { $Distro = 'Ubuntu-24.04' } }
if (-not $User) { if ($cfg.user) { $User = $cfg.user } else { $User = $env:USERNAME.ToLower() } }
$port = 3080
if ($cfg.port) { $port = [int]$cfg.port }
$unit = 'dsh-web'
if ($cfg.unit) { $unit = [string]$cfg.unit }
$script:Distro = $Distro
$script:LinuxUser = $User

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$backup = Join-Path $Root ('backup\' + $stamp)

Step 'preflight'
$probe = Wsl 'echo ok'
if ($probe.Code -ne 0) { throw ('WSL distro/user not reachable: ' + $probe.Text) }
Ok ('distro=' + $Distro + ' user=' + $User + ' port=' + $port + ' unit=' + $unit)

$trayProc = @(Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -match 'dsh-tray\.ps1' })
Ok ('legacy tray processes: ' + $trayProc.Count)

if ($DryRun) {
  Say ('dry run: would back up to ' + $backup)
  Say 'dry run: would run install.ps1'
  Say 'dry run: would stop the legacy tray and the dsh it owns'
  Say ('dry run: would systemctl --user start ' + $unit)
  Say 'dry run: would relaunch the tray'
  exit 0
}

# --- backup ---------------------------------------------------------------
Step ('backup to ' + $backup)
New-Item -ItemType Directory -Force -Path $backup | Out-Null
foreach ($f in @('dsh-tray.ps1', 'dsh-tray.vbs', 'dsh-labels.json', 'dsh-tray.config.json')) {
  $p = Join-Path $Root $f
  if (Test-Path $p) { Copy-Item $p $backup -Force }
}
$wslHome = '\\wsl.localhost\' + $Distro + '\home\' + $User
try {
  Copy-Item (Join-Path $wslHome 'bin\dsh-*.sh') $backup -Force
  Ok 'windows + wsl scripts backed up'
} catch {
  Warn ('wsl script backup incomplete: ' + $_.Exception.Message)
}

# --- install new layout ----------------------------------------------------
Step 'install'
& (Join-Path $PSScriptRoot 'install.ps1') -Root $Root -Distro $Distro -User $User -SkipVerify
if ($LASTEXITCODE -ne 0) { throw 'install.ps1 failed' }

# --- stop the legacy service ----------------------------------------------
Step 'stop legacy tray + dsh'
foreach ($p in $trayProc) {
  try { Stop-Process -Id $p.ProcessId -Force -ErrorAction Stop; Ok ('stopped tray pid ' + $p.ProcessId) } catch { Warn ('could not stop tray pid ' + $p.ProcessId) }
}
$killCmd = 'for p in $(ss -lntpH "sport = :' + $port + '" | grep -oE "pid=[0-9]+" | cut -d= -f2 | sort -u); do kill "$p" 2>/dev/null; done; true'
[void](Wsl $killCmd)
$deadline = (Get-Date).AddSeconds(20)
while ((Get-Date) -lt $deadline) {
  $c = New-Object System.Net.Sockets.TcpClient
  try {
    $ar = $c.BeginConnect('127.0.0.1', $port, $null, $null)
    if (-not $ar.AsyncWaitHandle.WaitOne(300, $false)) { break }
    $c.EndConnect($ar)
  } catch { break } finally { $c.Close() }
  Start-Sleep -Milliseconds 300
}
Ok 'legacy instance is down'

# --- start the unit -------------------------------------------------------
Step ('start ' + $unit)
$r = Wsl ('systemctl --user start ' + $unit)
if ($r.Code -ne 0) {
  Warn ('start failed: ' + $r.Text + ' -- run rollback.ps1 if the old layout is still wanted')
  exit 1
}
$deadline = (Get-Date).AddSeconds(90)
$up = $false
while ((Get-Date) -lt $deadline -and -not $up) {
  $c = New-Object System.Net.Sockets.TcpClient
  try {
    $ar = $c.BeginConnect('127.0.0.1', $port, $null, $null)
    if ($ar.AsyncWaitHandle.WaitOne(300, $false)) { $c.EndConnect($ar); $up = $true }
  } catch { } finally { $c.Close() }
  if (-not $up) { Start-Sleep -Milliseconds 500 }
}
if (-not $up) {
  Warn ('port never came up; check ' + (Join-Path $Root 'tray.log') + ' and: journalctl --user -u ' + $unit)
  exit 1
}
Ok ('listening on 127.0.0.1:' + $port)

# --- relaunch the tray ----------------------------------------------------
Step 'relaunch tray'
$exe = Join-Path $env:WINDIR 'System32\wscript.exe'
Start-Process -FilePath $exe -ArgumentList ('"' + (Join-Path $Root 'dsh-tray.vbs') + '"')
Ok 'tray started (click the icon to open the UI with a fresh token)'
Step 'done'
