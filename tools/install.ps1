param(
  [string]$Root = '',
  [string]$Distro = '',
  [string]$User = '',
  [switch]$ForceConfig,
  [switch]$SkipShortcut,
  [switch]$SkipVerify
)

$ErrorActionPreference = 'Stop'

# Installs the tray, the WSL helper scripts and the systemd user unit, then
# prints one line per step. Idempotent: run it again after a git pull.
# Nothing here starts or stops the service; that is switch.ps1 / the tray.

$repo = Split-Path $PSScriptRoot -Parent
if (-not $Root) { $Root = Join-Path $env:LOCALAPPDATA 'dsh' }

function Step([string]$Text) { Write-Output ('== ' + $Text) }
function Ok([string]$Text) { Write-Output ('   ok   ' + $Text) }
function Warn([string]$Text) { Write-Output ('   warn ' + $Text) }

function Wsl([string]$Command) {
  $out = & wsl.exe -d $script:Distro -u $script:LinuxUser -- bash -lc $Command 2>&1
  return @{ Code = $LASTEXITCODE; Text = (($out | Out-String).Trim()) }
}

# --- resolve the machine profile -------------------------------------------
$cfgRepo = Join-Path $repo 'tray\dsh-tray.config.json'
$cfgDst = Join-Path $Root 'dsh-tray.config.json'
$cfgPath = $null
if (Test-Path $cfgDst) { $cfgPath = $cfgDst } elseif (Test-Path $cfgRepo) { $cfgPath = $cfgRepo }
$cfg = $null
if ($cfgPath) { $cfg = Get-Content -Raw -Encoding UTF8 $cfgPath | ConvertFrom-Json }
if (-not $Distro) { if ($cfg -and $cfg.distro) { $Distro = $cfg.distro } else { $Distro = 'Ubuntu-24.04' } }
if (-not $User) { if ($cfg -and $cfg.user) { $User = $cfg.user } else { $User = $env:USERNAME.ToLower() } }
$script:Distro = $Distro
$script:LinuxUser = $User
$unit = 'dsh-web'
$port = 3080
if ($cfg -and $cfg.unit) { $unit = [string]$cfg.unit }
if ($cfg -and $cfg.port) { $port = [int]$cfg.port }

Step ('install into ' + $Root)
Ok ('distro=' + $Distro + ' user=' + $User + ' unit=' + $unit + ' port=' + $port)

$probe = Wsl 'echo ok'
if ($probe.Code -ne 0) { throw ('WSL distro/user not reachable: ' + $probe.Text) }
Ok 'wsl distro reachable'

# --- Windows side -----------------------------------------------------------
New-Item -ItemType Directory -Force -Path $Root | Out-Null
foreach ($f in @('dsh-tray.ps1', 'dsh-tray.vbs', 'dsh-icon.ico', 'dsh-labels.json')) {
  Copy-Item (Join-Path $repo ('tray\' + $f)) (Join-Path $Root $f) -Force
  Ok ('copied ' + $f)
}
if ((-not (Test-Path $cfgDst)) -or $ForceConfig) {
  Copy-Item $cfgRepo $cfgDst -Force
  Ok 'copied dsh-tray.config.json'
} else {
  Ok 'kept existing dsh-tray.config.json'
}
if (Test-Path (Join-Path $Root 'tray.log')) {
  # A stale log from the previous install makes "did it start?" ambiguous.
  Move-Item -Force (Join-Path $Root 'tray.log') (Join-Path $Root ('tray.log.' + (Get-Date -Format 'yyyyMMdd-HHmmss')))
}

# --- WSL side ---------------------------------------------------------------
$wslHome = '\\wsl.localhost\' + $Distro + '\home\' + $User
$binDir = Join-Path $wslHome 'bin'
$unitDir = Join-Path $wslHome '.config\systemd\user'
New-Item -ItemType Directory -Force -Path $binDir | Out-Null
New-Item -ItemType Directory -Force -Path $unitDir | Out-Null
Copy-Item (Join-Path $repo 'wsl\*.sh') $binDir -Force
Copy-Item (Join-Path $repo 'systemd\dsh-web.service') $unitDir -Force
Ok 'copied wsl scripts and unit file'

# The tray probes config.port while the unit listens on DSH_PORT; a silent
# mismatch would look like "port busy" forever.
$unitText = Get-Content -Raw (Join-Path $repo 'systemd\dsh-web.service')
$pm = [regex]::Match($unitText, 'DSH_PORT=(\d+)')
if ($pm.Success -and [int]$pm.Groups[1].Value -ne $port) {
  Warn ('unit DSH_PORT=' + $pm.Groups[1].Value + ' differs from config.port=' + $port + '; edit Environment=DSH_PORT in ' + $unitDir + '\' + $unit + '.service, then run install again')
}

$linuxHome = '/home/' + $User
$r = Wsl ('chmod 755 ' + $linuxHome + '/bin/dsh-*.sh')
if ($r.Code -ne 0) { throw ('chmod failed: ' + $r.Text) }
Ok 'chmod 755 dsh-*.sh'

$r = Wsl ('loginctl enable-linger ' + $User)
if ($r.Code -ne 0) { Warn ('enable-linger failed: ' + $r.Text) } else { Ok 'linger enabled' }

$r = Wsl 'systemctl --user daemon-reload'
if ($r.Code -ne 0) { throw ('daemon-reload failed: ' + $r.Text) }
$r = Wsl ('systemctl --user enable ' + $unit)
if ($r.Code -ne 0) { Warn ('enable failed: ' + $r.Text) } else { Ok ('enabled ' + $unit) }

$st = Wsl ('systemd-analyze verify ' + $linuxHome + '/.config/systemd/user/' + $unit + '.service 2>&1')
if ($st.Code -ne 0) { Warn ('systemd-analyze verify: ' + $st.Text) } else { Ok 'unit file verified' }

# --- shortcut ---------------------------------------------------------------
if (-not $SkipShortcut) {
  & (Join-Path $PSScriptRoot 'deploy-shortcut.ps1') -Root $Root | Out-Null
  Ok 'desktop shortcut refreshed'
}

# --- deployment record ------------------------------------------------------
$git = ''
try { $git = (& git -C $repo rev-parse --short HEAD 2>$null) } catch { }
if (-not $git) {
  # git on a UNC work tree can refuse ("dubious ownership"); read the ref directly
  # so deployed.json still records which revision was installed.
  try {
    $headFile = Join-Path $repo '.git\HEAD'
    if (Test-Path $headFile) {
      $head = (Get-Content -Raw $headFile).Trim()
      if ($head -match '^ref:\s*(.+)$') {
        $refFile = Join-Path $repo ('.git\' + ($Matches[1] -replace '/', '\'))
        if (Test-Path $refFile) { $git = (Get-Content -Raw $refFile).Trim().Substring(0, 7) }
      } elseif ($head -match '^[0-9a-f]{40}') {
        $git = $head.Substring(0, 7)
      }
    }
  } catch { }
}
$files = @{}
foreach ($f in @('dsh-tray.ps1', 'dsh-tray.vbs', 'dsh-labels.json', 'dsh-tray.config.json')) {
  $p = Join-Path $Root $f
  if (Test-Path $p) { $files[$f] = (Get-FileHash -Algorithm SHA256 $p).Hash.ToLower() }
}
$record = @{
  installedAt = (Get-Date).ToString('o')
  revision    = $git
  distro      = $Distro
  user        = $User
  unit        = $unit
  port        = $port
  files       = $files
} | ConvertTo-Json -Depth 4
[System.IO.File]::WriteAllText((Join-Path $Root 'deployed.json'), $record)
Ok 'wrote deployed.json'

Step 'done'
if (-not $SkipVerify) {
  & (Join-Path $PSScriptRoot 'verify-tray.ps1') -Root $Root -Distro $Distro -User $User
  exit $LASTEXITCODE
}
exit 0
