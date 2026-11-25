param(
  [string]$Root = '',
  [string]$Distro = '',
  [string]$User = ''
)

$ErrorActionPreference = 'Continue'

# Post-install checks that need no GUI, no right-click and no service restart.
# Prints one line per item and exits non-zero when anything failed.
#   -Root <dir>  check a staged tree instead of %LOCALAPPDATA%\dsh

if (-not $Root) { $Root = Join-Path $env:LOCALAPPDATA 'dsh' }

$ps1 = Join-Path $Root 'dsh-tray.ps1'
$json = Join-Path $Root 'dsh-labels.json'
$ico = Join-Path $Root 'dsh-icon.ico'
$cfgPath = Join-Path $Root 'dsh-tray.config.json'
$out = @()
$fail = 0

function Check([string]$Text) { $script:out += $Text }

# --- config ---------------------------------------------------------------
$cfg = $null
if (-not (Test-Path $cfgPath)) {
  Check 'config=missing'
  $fail++
} else {
  try {
    $cfg = Get-Content -Raw -Encoding UTF8 $cfgPath | ConvertFrom-Json
    Check ('config=OK port=' + $cfg.port + ' unit=' + $cfg.unit + ' distro=' + $cfg.distro)
    if ([int]$cfg.port -lt 1 -or [int]$cfg.port -gt 65535) { Check 'config_port=OUT_OF_RANGE'; $fail++ }
    if ($cfg.unit -notmatch '^[A-Za-z0-9_.@-]+$') { Check 'config_unit=ILLEGAL'; $fail++ }
    if (-not $cfg.logPath) { Check 'config_logPath=EMPTY'; $fail++ }
  } catch {
    Check ('config=FAILED ' + $_.Exception.Message)
    $fail++
  }
}
if (-not $Distro) { if ($cfg -and $cfg.distro) { $Distro = $cfg.distro } else { $Distro = 'Ubuntu-24.04' } }
if (-not $User) { if ($cfg -and $cfg.user) { $User = $cfg.user } else { $User = $env:USERNAME.ToLower() } }
$unit = 'dsh-web'
$port = 3080
if ($cfg -and $cfg.unit) { $unit = [string]$cfg.unit }
if ($cfg -and $cfg.port) { $port = [int]$cfg.port }

# --- 1 syntax parse -------------------------------------------------------
$errs = $null; $tokens = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($ps1, [ref]$tokens, [ref]$errs)
if ($errs -and $errs.Count -gt 0) {
  Check 'parse=FAILED'
  foreach ($e in $errs) { Check ('  L' + $e.Extent.StartLineNumber + ' ' + $e.Message) }
  $fail++
} else {
  Check ('parse=OK tokens=' + $tokens.Count)
}

# --- 2 non-ASCII bytes ----------------------------------------------------
$nonAscii = 0
foreach ($b in [System.IO.File]::ReadAllBytes($ps1)) { if ($b -gt 127) { $nonAscii++ } }
Check ('non_ascii=' + $nonAscii)
if ($nonAscii -ne 0) { $fail++ }

# --- 3 labels -------------------------------------------------------------
try {
  $L = Get-Content -Raw -Encoding UTF8 $json | ConvertFrom-Json
  $need = @('appName', 'tooltip', 'windowMarker', 'menuOpen', 'menuRestart', 'menuStop', 'menuLog',
    'statusRunning', 'statusStopped', 'statusStarting', 'statusStopping', 'statusFailed',
    'statusStopFailed', 'hintPortBusy', 'hintStartFail', 'hintStopFail', 'hintNoToken',
    'hintLinger', 'hintNoUnit', 'menuExit', 'confirmStopHint', 'confirmOk',
    'confirmStopKeepHint', 'confirmStopKeepOk', 'confirmRestartHint', 'confirmRestartOk', 'confirmCancel')
  $miss = @()
  foreach ($k in $need) { if (-not $L.$k) { $miss += $k } }
  if ($miss.Count -gt 0) { Check ('labels=MISSING ' + ($miss -join ',')); $fail++ }
  else { Check 'labels=OK' }
} catch {
  Check ('labels=FAILED ' + $_.Exception.Message); $fail++
}

# --- 4 icon ---------------------------------------------------------------
try {
  Add-Type -AssemblyName System.Drawing
  $i = New-Object System.Drawing.Icon($ico)
  Check ('icon=OK ' + $i.Width + 'x' + $i.Height)
  $i.Dispose()
} catch { Check ('icon=FAILED ' + $_.Exception.Message); $fail++ }

# --- 5 token reachable (len only, never the value) ------------------------
$logLinux = [string]$cfg.logPath
if (-not $logLinux) { $logLinux = '~/.local/state/dsh-web.log' }
if ($logLinux.StartsWith('~')) { $logLinux = '/home/' + $User + $logLinux.Substring(1) }
$unc = '\\wsl.localhost\' + $Distro + '\' + ($logLinux.TrimStart('/') -replace '/', '\')
try {
  $reach = Test-Path $unc
  Check ('unc_log=' + $reach)
  if ($reach) {
    $tk = $null
    $lines = @(Get-Content -Tail 200 $unc)
    $start = 0
    for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i] -match '\[boot\]') { $start = $i } }
    for ($i = $start; $i -lt $lines.Count; $i++) {
      $m = [regex]::Match($lines[$i], 'token=([A-Za-z0-9_\-]+)')
      if ($m.Success) { $tk = $m.Groups[1].Value }
    }
    if ($tk) { Check ('token_parse=OK len=' + $tk.Length) } else { Check 'token_parse=EMPTY (no token after the last [boot] marker)'; $fail++ }
  } else { $fail++ }
} catch { Check ('unc_log=ERROR ' + $_.Exception.Message); $fail++ }

# --- 6 port ---------------------------------------------------------------
$c = $null
$up = $false
try {
  $c = New-Object System.Net.Sockets.TcpClient
  $r = $c.BeginConnect('127.0.0.1', $port, $null, $null)
  $up = $r.AsyncWaitHandle.WaitOne(800, $false)
  if ($up) { $c.EndConnect($r) }
} catch { $up = $false }
finally { if ($c) { try { $c.Close() } catch { } } }
Check ('port' + $port + '_up=' + $up)

$owner = 'unknown'
if ($up) {
  try {
    $req = [System.Net.HttpWebRequest]::Create('http://127.0.0.1:' + $port + '/')
    $req.Proxy = $null; $req.AllowAutoRedirect = $false; $req.Timeout = 1500
    try { $resp = $req.GetResponse(); $code = [int]$resp.StatusCode; $resp.Close() }
    catch [System.Net.WebException] { if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode } else { $code = -2 } }
    if ($code -eq 401 -or $code -eq 303) { $owner = 'dsh' }
    elseif ($code -eq -2) { $owner = 'unknown-http' }
    else { $owner = 'foreign' }
  } catch { $owner = 'error' }
}
Check ('port' + $port + '_owner=' + $owner)

# --- 7 systemd unit -------------------------------------------------------
$bash = 'systemctl --user is-enabled ' + $unit + ' 2>&1; systemctl --user is-active ' + $unit + ' 2>&1; loginctl show-user ' + $User + ' -p Linger 2>&1; test -f ~/.config/systemd/user/' + $unit + '.service && echo unit=present || echo unit=missing'
try {
  $lines = & wsl.exe -d $Distro -u $User -- bash -lc $bash 2>&1
  foreach ($l in $lines) { Check ('systemd: ' + ([string]$l).Trim()) }
  $joined = (($lines | Out-String))
  if ($joined -notmatch 'unit=present') { Check 'unit=FAILED (missing in ~/.config/systemd/user)'; $fail++ }
  if ($joined -notmatch 'Linger=yes') { Check 'linger=NO (service dies when the last wsl.exe client exits)'; $fail++ }
} catch {
  Check ('systemd=ERROR ' + $_.Exception.Message); $fail++
}

# --- 8 deployment drift ---------------------------------------------------
$drift = Join-Path $Root 'deployed.json'
if (Test-Path $drift) {
  $driftFail = 0
  try {
    $rec = Get-Content -Raw -Encoding UTF8 $drift | ConvertFrom-Json
    Check ('revision=' + $rec.revision + ' installedAt=' + $rec.installedAt)
    foreach ($name in $rec.files.PSObject.Properties.Name) {
      $p = Join-Path $Root $name
      if (-not (Test-Path $p)) { Check ('drift=missing ' + $name); $driftFail++; continue }
      $h = (Get-FileHash -Algorithm SHA256 $p).Hash.ToLower()
      if ($h -ne $rec.files.$name) { Check ('drift=changed ' + $name); $driftFail++ }
    }
    if ($driftFail -eq 0) { Check 'drift=none' }
    $fail += $driftFail
  } catch { Check ('drift=ERROR ' + $_.Exception.Message); $fail++ }
}

$out | ForEach-Object { $_ }
Check ('result=' + $(if ($fail -eq 0) { 'PASS' } else { 'FAIL(' + $fail + ')' }))
Write-Output $out[-1]
exit $fail
