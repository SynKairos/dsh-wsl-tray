param(
  [string]$Distro = 'Ubuntu-24.04',
  [string]$User   = ''
)

$ErrorActionPreference = 'Continue'

# Post-deploy checks that need no GUI, no right-click and no service restart.
# Prints one line per item and exits non-zero when anything failed.

if (-not $User) { $User = $env:USERNAME.ToLower() }

$root = Join-Path $env:LOCALAPPDATA 'dsh'
$ps1  = Join-Path $root 'dsh-tray.ps1'
$json = Join-Path $root 'dsh-labels.json'
$ico  = Join-Path $root 'dsh-icon.ico'
$out  = @()
$fail = 0

# 1 syntax parse (the PowerShell in-box parser, i.e. what the launched host uses)
$errs = $null; $tokens = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($ps1, [ref]$tokens, [ref]$errs)
if ($errs -and $errs.Count -gt 0) {
  $out += 'parse=FAILED'
  foreach ($e in $errs) { $out += ('  L' + $e.Extent.StartLineNumber + ' ' + $e.Message) }
  $fail++
} else {
  $out += ('parse=OK tokens=' + $tokens.Count)
}

# 2 non-ASCII bytes: PowerShell 5.1 reads .ps1 as ANSI, so any of them corrupts it
$nonAscii = 0
foreach ($b in [System.IO.File]::ReadAllBytes($ps1)) { if ($b -gt 127) { $nonAscii++ } }
$out += ('non_ascii=' + $nonAscii)
if ($nonAscii -ne 0) { $fail++ }

# 3 labels json parses and carries the keys the panel needs
try {
  $L = Get-Content -Raw -Encoding UTF8 $json | ConvertFrom-Json
  $need = @('appName', 'tooltip', 'menuOpen', 'menuRestart', 'menuStop', 'menuLog', 'menuExit', 'statusRunning', 'statusStopped', 'statusStarting', 'statusStopping', 'statusFailed')
  $miss = @()
  foreach ($k in $need) { if (-not $L.$k) { $miss += $k } }
  if ($miss.Count -gt 0) { $out += ('labels=MISSING ' + ($miss -join ',')); $fail++ }
  else { $out += 'labels=OK' }
} catch {
  $out += ('labels=FAILED ' + $_.Exception.Message); $fail++
}

# 4 icon decodes
try {
  Add-Type -AssemblyName System.Drawing
  $i = New-Object System.Drawing.Icon($ico)
  $out += ('icon=OK ' + $i.Width + 'x' + $i.Height)
  $i.Dispose()
} catch { $out += ('icon=FAILED ' + $_.Exception.Message); $fail++ }

# 5 the token line is reachable over the WSL share
$unc = "\\wsl.localhost\$Distro\home\$User\.local\state\dsh-web.log"
try {
  $reach = Test-Path $unc
  $out += ('unc_log=' + $reach)
  if ($reach) {
    $tk = $null
    foreach ($line in (Get-Content $unc)) {
      $m = [regex]::Match($line, 'token=([A-Za-z0-9_\-]+)')
      if ($m.Success) { $tk = $m.Groups[1].Value }
    }
    if ($tk) { $out += ('token_parse=OK len=' + $tk.Length) } else { $out += 'token_parse=EMPTY'; $fail++ }
  } else { $fail++ }
} catch { $out += ('unc_log=ERROR ' + $_.Exception.Message); $fail++ }

# 6 port 3080 answers, and whether the answer looks like dsh
$c = $null
$up = $false
try {
  $c = New-Object System.Net.Sockets.TcpClient
  $r = $c.BeginConnect('127.0.0.1', 3080, $null, $null)
  $up = $r.AsyncWaitHandle.WaitOne(800, $false)
  if ($up) { $c.EndConnect($r) }
} catch { $up = $false }
finally { if ($c) { try { $c.Close() } catch { } } }
$out += ('port3080_up=' + $up)

$script:trayState = 'unknown'
if ($up) {
  try {
    $req = [System.Net.HttpWebRequest]::Create('http://127.0.0.1:3080/')
    $req.Proxy = $null; $req.AllowAutoRedirect = $false; $req.Timeout = 1500
    try { $resp = $req.GetResponse(); $code = [int]$resp.StatusCode; $resp.Close() }
    catch [System.Net.WebException] { if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode } else { $code = -2 } }
    if ($code -eq 401 -or $code -eq 303) { $script:trayState = 'dsh' }
    elseif ($code -eq -2) { $script:trayState = 'unknown-http' }
    else { $script:trayState = 'foreign' }
  } catch { $script:trayState = 'error' }
}
$out += ('port3080_owner=' + $script:trayState)

$out | ForEach-Object { $_ }
Write-Output ('result=' + $(if ($fail -eq 0) { 'PASS' } else { "FAIL($fail)" }))
exit $fail
