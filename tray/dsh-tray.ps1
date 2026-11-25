param(
  [string]$Distro       = '',
  [string]$User         = '',
  [string]$ConfigFile   = '',
  [switch]$Render,
  [switch]$NoStart,
  [string]$RenderState  = 'running',
  [string]$RenderReason = '',
  [int]$Probe           = 0,
  [switch]$AnchorTest,
  [string]$AnchorState  = 'running',
  [int]$CursorX         = -1,
  [int]$CursorY         = -1,
  [switch]$ListWindows,
  [switch]$FocusTest,
  [switch]$AnimTest,
  [switch]$SelfTest,
  [switch]$TokenTest,
  [switch]$ConfigTest,
  [switch]$ControllerTest,
  [switch]$BenchPanel
)

# NOTE: this file must stay pure ASCII. PowerShell 5.1 parses .ps1 as ANSI,
# so any non-ASCII byte in comments or literals corrupts the script.
# All Chinese UI text lives in dsh-labels.json (UTF-8, read via ConvertFrom-Json).

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# --- configuration -----------------------------------------------------------
# Every machine-specific value lives in dsh-tray.config.json next to this
# script: port, bind host, distro, account, systemd unit, log path, timeouts.
# Nothing below may hardcode any of them.
# Diagnostics must never block on a modal dialog: they run from scripts.
$script:Headless = [bool]($Render -or $ConfigTest -or $ControllerTest -or $ListWindows -or
  $FocusTest -or $AnimTest -or $SelfTest -or $TokenTest -or $BenchPanel -or $AnchorTest -or $Probe -gt 0)

$Root = if ($env:DSH_TRAY_ROOT) { $env:DSH_TRAY_ROOT } else { Join-Path $env:LOCALAPPDATA 'dsh' }
$script:LogFile = Join-Path $Root 'tray.log'

function Write-TrayLog {
  param([string]$Message, [string]$Level = 'info')
  try {
    $line = ('{0:yyyy-MM-dd HH:mm:ss.fff} [{1}] {2}' -f (Get-Date), $Level, $Message)
    try {
      if ((Test-Path $script:LogFile) -and ((Get-Item $script:LogFile).Length -gt 1MB)) {
        Move-Item -Force $script:LogFile ($script:LogFile + '.1')
      }
    } catch { }
    [System.IO.File]::AppendAllText($script:LogFile, $line + [Environment]::NewLine)
  } catch { }
}

$script:Defaults = [ordered]@{
  schema              = 1
  distro              = 'Ubuntu-24.04'
  user                = ''
  host                = '127.0.0.1'
  port                = 3080
  unit                = 'dsh-web'
  logPath             = '~/.local/state/dsh-web.log'
  stopConfirm         = $true
  startTimeoutSeconds = 90
  stopTimeoutSeconds  = 25
  pollSeconds         = 3
  focusBrowser        = $true
}

function Read-TrayConfig {
  param([string]$Path)
  if (-not (Test-Path $Path)) { throw ('config not found: ' + $Path) }
  $raw = Get-Content -Raw -Encoding UTF8 $Path | ConvertFrom-Json
  $cfg = [ordered]@{}
  foreach ($k in $script:Defaults.Keys) { $cfg[$k] = $script:Defaults[$k] }
  foreach ($p in $raw.PSObject.Properties) {
    if ($script:Defaults.Contains($p.Name)) { $cfg[$p.Name] = $p.Value }
    else { Write-TrayLog ('config: unknown key ignored: ' + $p.Name) 'warn' }
  }
  if (-not $cfg.distro) { throw 'config: distro must not be empty' }
  if ([int]$cfg.port -lt 1 -or [int]$cfg.port -gt 65535) { throw ('config: port out of range: ' + $cfg.port) }
  if ($cfg.unit -notmatch '^[A-Za-z0-9_.@-]+$') { throw ('config: illegal unit name: ' + $cfg.unit) }
  if ($cfg.host -notmatch '^[A-Za-z0-9.:\[\]-]+$') { throw ('config: illegal host: ' + $cfg.host) }
  if (-not $cfg.logPath) { throw 'config: logPath must not be empty' }
  return $cfg
}

if (-not $ConfigFile) { $ConfigFile = Join-Path $Root 'dsh-tray.config.json' }
try {
  $C = Read-TrayConfig $ConfigFile
} catch {
  Write-TrayLog ('fatal config: ' + $_.Exception.Message) 'error'
  Write-Output ('fatal config: ' + $_.Exception.Message)
  if (-not $script:Headless) {
    [void][System.Windows.MessageBox]::Show(('Bad tray config:' + [Environment]::NewLine + $ConfigFile + [Environment]::NewLine + [Environment]::NewLine + $_.Exception.Message + [Environment]::NewLine + [Environment]::NewLine + 'See ' + $script:LogFile), 'DeepSeek Harness', 'OK', 'Error')
  }
  exit 1
}
# Command-line parameters win over the file, so a one-off run can point elsewhere.
if ($Distro) { $C.distro = $Distro }
if ($User)   { $C.user   = $User }
if (-not $C.user) { $C.user = $env:USERNAME.ToLower() }

$script:Distro    = [string]$C.distro
$script:LinuxUser = [string]$C.user
$script:Port      = [int]$C.port
$script:BindHost  = [string]$C.host
$script:Unit      = [string]$C.unit
$script:BaseUrl   = 'http://' + $script:BindHost + ':' + $script:Port + '/'
$script:StopConfirm = [bool]$C.stopConfirm
$script:StartTimeout = [int]$C.startTimeoutSeconds
$script:StopTimeout  = [int]$C.stopTimeoutSeconds
$script:PollSeconds  = [int]$C.pollSeconds

$LinuxHome = '/home/' + $script:LinuxUser
$LogLinux  = ([string]$C.logPath).Replace('~', $LinuxHome)
$LogUnc    = '\\wsl.localhost\' + $script:Distro + ($LogLinux -replace '/', '\')
$WslBase   = '-d ' + $script:Distro + ' -u ' + $script:LinuxUser + ' -- '
$LogArgs   = $WslBase + 'bash -l ' + $LinuxHome + '/bin/dsh-log.sh'

Write-TrayLog ('start pid=' + $PID + ' config=' + $ConfigFile)
Write-TrayLog ('resolved distro=' + $script:Distro + ' user=' + $script:LinuxUser + ' port=' + $script:Port + ' unit=' + $script:Unit)

$IcoPath   = Join-Path $Root 'dsh-icon.ico'
$LabelFile = Join-Path $Root 'dsh-labels.json'
if (-not (Test-Path $LabelFile)) {
  Write-TrayLog ('fatal: labels file missing: ' + $LabelFile) 'error'
  Write-Output ('fatal: labels file missing: ' + $LabelFile)
  if (-not $script:Headless) {
    [void][System.Windows.MessageBox]::Show(('Missing labels file:' + [Environment]::NewLine + $LabelFile), 'DeepSeek Harness', 'OK', 'Error')
  }
  exit 1
}
$L = Get-Content -Raw -Encoding UTF8 $LabelFile | ConvertFrom-Json

# Palette taken from the official design tokens shipped inside dsh itself
# (@deepseek-ai/dsh-client-ui-theme -> --dsw-static-*), so the panel matches the
# web UI instead of approximating it:
#   bg      neutral-bluish-900   #1b1b1c
#   border  alias-border-l2 (dark) #ffffff1f
#   text    neutral-bluish-100   #ebeef2
#   muted   neutral-bluish-500   #979da6
#   green   static-green-400     #4ed17e
#   amber   static-amber-400     #f7ad31
#   red     static-red-400       #f25a5a
$C_Bg     = '#1B1B1C'
$C_Brd    = '#1FFFFFFF'
$C_Text   = '#EBEEF2'
$C_Sub    = '#979DA6'
$C_Hover  = '#1AFFFFFF'
$C_Green  = '#4ED17E'
$C_Gray   = '#61666B'
$C_Amber  = '#F7AD31'
$C_Red    = '#F25A5A'
$C_Line   = '#0FFFFFFF'
$C_Glyph  = '#CFD3D6'
$FontCN   = 'Microsoft YaHei UI'
$FontIcon = 'Segoe MDL2 Assets'

$script:State     = 'stopped'
$script:Reason    = ''
$script:Panel     = $null
$script:Run       = $true
$script:Mutex     = $null
$script:PokeEvt   = $null
$script:HideTimer = $null
$script:HideArmed = $false
$script:HideMs    = 2500
$script:LastOpen  = [DateTime]::MinValue
$script:Prewarming = $false
$script:WarmHide   = $null
$script:AnimOk     = $true
$script:HideGen    = 0
$script:HideWait      = $null
$script:HidePendingGen = 0
$script:ShownKey   = ''
$script:PortKind   = 'free'
# A non-dsh listener cannot become dsh without disappearing first, so the
# expensive HTTP identity probe is skipped until this moment.
$script:ForeignUntil = [DateTime]::MinValue
# One start/stop at a time, driven by a dispatcher timer instead of a blocking
# wait on the click handler: the UI thread must stay free to repaint the panel.
$script:OpKind     = ''
$script:OpProc     = $null
$script:OpDeadline = [DateTime]::MinValue
$script:OpNext     = ''
$script:OpOpen     = $false
$script:OpTimer    = $null
$script:OpStdout   = $null
$script:OpStderr   = $null
try { $script:AnimOk = [System.Windows.SystemParameters]::ClientAreaAnimation } catch { $script:AnimOk = $true }

# Brushes / fonts / logo are rebuilt on every panel refresh otherwise, and each
# BrushConverter + hex parse costs real milliseconds when done ~40x per click.
$script:BrushCache = @{}
$script:FontCache  = @{}
$script:Logo       = $null
$script:LogoDone   = $false

function Brush([string]$hex) {
  if ($script:BrushCache.ContainsKey($hex)) { return $script:BrushCache[$hex] }
  $b = (New-Object System.Windows.Media.BrushConverter).ConvertFromString($hex)
  try { $b.Freeze() } catch { }
  $script:BrushCache[$hex] = $b
  return $b
}

function Get-Font([string]$name) {
  if ($script:FontCache.ContainsKey($name)) { return $script:FontCache[$name] }
  $f = New-Object System.Windows.Media.FontFamily($name)
  $script:FontCache[$name] = $f
  return $f
}
function Thick([double]$a, [double]$b, [double]$c, [double]$d) { New-Object System.Windows.Thickness($a, $b, $c, $d) }
function Corner([double]$r) { New-Object System.Windows.CornerRadius($r) }

# --- Win32 window lookup: focus an already-open dsh page instead of opening a duplicate tab ---
$script:HasWin32     = $null
$script:HitHwnd     = [IntPtr]::Zero
$script:BrowserProc = @('msedge', 'chrome', 'firefox', 'brave', 'vivaldi', 'opera', 'chromium', 'arc')

function Ensure-Win32 {
  if ($script:HasWin32 -ne $null) { return $script:HasWin32 }
  try {
    if (-not ('DshWin32' -as [type])) {
      $code = @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public class DshWin32 {
  public delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern int GetWindowTextLength(IntPtr h);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool ShowWindowAsync(IntPtr h, int c);
  [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
  [DllImport("user32.dll")] public static extern void SwitchToThisWindow(IntPtr h, bool alt);
  [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr h);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint a, uint b, bool f);
  [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
}
'@
      Add-Type -TypeDefinition $code -ErrorAction Stop
    }
    $script:HasWin32 = $true
  } catch {
    $script:HasWin32 = $false
  }
  return $script:HasWin32
}

function Get-WindowList {
  $rows = New-Object System.Collections.ArrayList
  $cb = [DshWin32+EnumProc]{
    param([IntPtr]$h, [IntPtr]$l)
    try {
      if (-not [DshWin32]::IsWindowVisible($h)) { return $true }
      $len = [DshWin32]::GetWindowTextLength($h)
      if ($len -le 0) { return $true }
      $sb = New-Object System.Text.StringBuilder ($len + 2)
      [void][DshWin32]::GetWindowTextW($h, $sb, $sb.Capacity)
      [uint32]$procId = 0
      [void][DshWin32]::GetWindowThreadProcessId($h, [ref]$procId)
      $pn = ''
      try { $pn = (Get-Process -Id $procId -ErrorAction Stop).ProcessName.ToLower() } catch { $pn = '?' }
      [void]$rows.Add([pscustomobject]@{ Hwnd = $h; Pid = $procId; Proc = $pn; Title = $sb.ToString() })
    } catch { }
    return $true
  }
  [void][DshWin32]::EnumWindows($cb, [IntPtr]::Zero)
  return $rows
}

function Find-DshWindow {
  if (-not (Ensure-Win32)) { return [IntPtr]::Zero }
  $marker = [string]$L.windowMarker
  if (-not $marker) { $marker = [string]$L.appName }
  if (-not $marker) { return [IntPtr]::Zero }
  $script:HitHwnd = [IntPtr]::Zero
  $names = $script:BrowserProc
  foreach ($w in (Get-WindowList)) {
    if ($w.Title -notlike "*$marker*") { continue }
    if ($names -notcontains $w.Proc) { continue }
    $script:HitHwnd = $w.Hwnd
    break
  }
  return $script:HitHwnd
}

function Focus-Window([IntPtr]$h) {
  if (-not (Ensure-Win32) -or $h -eq [IntPtr]::Zero) { return $false }
  if ([DshWin32]::IsIconic($h)) { [void][DshWin32]::ShowWindowAsync($h, 9) }
  $ok = $false
  try {
    [uint32]$fgPid = 0
    $fg = [DshWin32]::GetForegroundWindow()
    $fgThread = [DshWin32]::GetWindowThreadProcessId($fg, [ref]$fgPid)
    $myThread = [DshWin32]::GetCurrentThreadId()
    $attached = $false
    if ($fgThread -ne 0 -and $fgThread -ne $myThread) {
      $attached = [DshWin32]::AttachThreadInput($myThread, $fgThread, $true)
    }
    [void][DshWin32]::BringWindowToTop($h)
    $ok = [DshWin32]::SetForegroundWindow($h)
    if ($attached) { [void][DshWin32]::AttachThreadInput($myThread, $fgThread, $false) }
  } catch { }
  if (-not $ok) {
    try { [DshWin32]::SwitchToThisWindow($h, $true); $ok = $true } catch { }
  }
  return $ok
}

function Test-Up {
  param([int]$Port = 0, [int]$TimeoutMs = 500)
  if (-not $Port) { $Port = $script:Port }
  $c = $null
  try {
    $c = New-Object System.Net.Sockets.TcpClient
    $r = $c.BeginConnect($script:BindHost, $Port, $null, $null)
    $ok = $r.AsyncWaitHandle.WaitOne($TimeoutMs, $false)
    if ($ok) { $c.EndConnect($r) }
    return $ok
  } catch { return $false }
  finally { if ($c) { try { $c.Close() } catch { } } }
}

# HTTP status of the configured listener. 401/303 => dsh is the listener.
# -2 => nothing answered on HTTP (treated as foreign or closed).
function Test-DshHttp {
  param([int]$Port = 0, [int]$TimeoutMs = 1500)
  if (-not $Port) { $Port = $script:Port }
  $req = $null
  try {
    $req = [System.Net.HttpWebRequest]::Create('http://' + $script:BindHost + ':' + $Port + '/')
    $req.Proxy = $null
    $req.Timeout = $TimeoutMs
    $req.ReadWriteTimeout = $TimeoutMs
    $req.AllowAutoRedirect = $false
    $resp = $req.GetResponse()
    $code = [int]$resp.StatusCode
    $resp.Close()
    return $code
  } catch [System.Net.WebException] {
    $ex = $_.Exception
    if ($ex.Response) {
      $code = [int]$ex.Response.StatusCode
      try { $ex.Response.Close() } catch { }
      return $code
    }
    return -2
  } catch {
    return -2
  }
}

# 'free' | 'dsh' | 'foreign'
function Get-PortState {
  param([int]$Port = 0, [int]$TimeoutMs = 1500)
  if (-not $Port) { $Port = $script:Port }
  if (-not (Test-Up -Port $Port -TimeoutMs 500)) { return 'free' }
  $code = Test-DshHttp -Port $Port -TimeoutMs $TimeoutMs
  # dsh answers 401 on an unauthenticated GET / (measured 2026-11-24, 0.2.2-rc.5).
  # 303 only appears with a valid token. A generic 200 is NOT proof of dsh.
  if ($code -eq 401 -or $code -eq 303) { return 'dsh' }
  return 'foreign'
}

# --- token plumbing ----------------------------------------------------------
# dsh prints one `dsh web: http://...?token=...` line per process and the token
# is fresh on every start. Only the tail of the log is read: the file is
# append-only, so reading it whole would make every click slower over time.
$script:TailBytes = 65536

function Read-LogText {
  try {
    if (-not (Test-Path $LogUnc)) { return $null }
    $fs = [System.IO.File]::Open($LogUnc, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    try {
      $len = $fs.Length
      $start = [Math]::Max(0, $len - $script:TailBytes)
      [void]$fs.Seek($start, [System.IO.SeekOrigin]::Begin)
      $count = [int]($len - $start)
      $buf = New-Object byte[] $count
      $read = $fs.Read($buf, 0, $count)
      return [System.Text.Encoding]::UTF8.GetString($buf, 0, $read)
    } finally { $fs.Dispose() }
  } catch { return $null }
}

# Newest token, but only when it belongs to the current run: the launcher writes
# a `[boot]` marker before dsh starts, so a token below the last marker is stale
# and must not be turned into a browser tab that answers 401.
function Get-TokenFromText {
  param([string]$Text)
  if (-not $Text) { return $null }
  $lines = $Text -split "`r?`n"
  for ($i = $lines.Count - 1; $i -ge 0; $i--) {
    if ($lines[$i] -match '\[boot\]') { return $null }
    $m = [regex]::Match($lines[$i], 'token=([A-Za-z0-9_\-]+)')
    if ($m.Success) { return $m.Groups[1].Value }
  }
  return $null
}

# Fallback when the share itself is missing: tail the same file inside the
# distro. Output is drained asynchronously so a large log cannot block the UI.
function Read-TokenFromWsl {
  $p = $null
  try {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'C:\Windows\System32\wsl.exe'
    $psi.Arguments = $WslBase + 'tail -c ' + $script:TailBytes + ' -- ' + $LogLinux
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $p = [System.Diagnostics.Process]::Start($psi)
    $err = $p.StandardError.ReadToEndAsync()
    $out = $p.StandardOutput.ReadToEndAsync()
    if (-not $p.WaitForExit(3000)) {
      try { $p.Kill() } catch { }
      return $null
    }
    if (-not $out.IsCompleted) { return $null }
    return (Get-TokenFromText $out.Result)
  } catch { return $null }
  finally { if ($p) { try { $p.Dispose() } catch { } } }
}

function Get-Token {
  param([switch]$Robust)
  $t = Get-TokenFromText (Read-LogText)
  if ($t) { return $t }
  if (-not $Robust) { return $null }
  # A 9p hiccup looks exactly like a missing token; retry once before falling back.
  Start-Sleep -Milliseconds 250
  $t = Get-TokenFromText (Read-LogText)
  if ($t) { return $t }
  return (Read-TokenFromWsl)
}

# Which token the remembered browser tab was opened with. Only a hash is stored:
# the panel must not add another plaintext copy of the credential to disk (the
# log already carries one), yet it must still be able to tell a stale tab from a
# live one. Surviving a tray restart is the whole point, so it lives in a file.
function Get-TokenHash([string]$Token) {
  if (-not $Token) { return '' }
  try {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $b = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Token))
    $h = [System.BitConverter]::ToString($b) -replace '-', ''
    return $h.ToLower()
  } catch { return '' }
}

function Read-LastTokenHash {
  try {
    $p = Join-Path $Root 'last-token.sha'
    if (Test-Path $p) { return ((Get-Content -Raw $p).Trim()) }
  } catch { }
  return ''
}

function Write-LastTokenHash([string]$Token) {
  try {
    $h = Get-TokenHash $Token
    if ($h) { [System.IO.File]::WriteAllText((Join-Path $Root 'last-token.sha'), $h) }
  } catch { }
}

function New-Text {
  param([string]$Text, [double]$Size, [string]$Color, [string]$Font = $FontCN, [string]$Weight = 'Normal')
  $t = New-Object System.Windows.Controls.TextBlock
  $t.Text = $Text
  $t.FontSize = $Size
  $t.FontFamily = Get-Font $Font
  $t.Foreground = Brush $Color
  if ($Weight -eq 'SemiBold') { $t.FontWeight = [System.Windows.FontWeights]::SemiBold }
  $t.VerticalAlignment = 'Center'
  return $t
}

function New-Glyph {
  param([string]$Hex, [double]$Size = 13)
  $t = New-Object System.Windows.Controls.TextBlock
  $t.Text = [string][char][Convert]::ToInt32($Hex, 16)
  $t.FontFamily = Get-Font $FontIcon
  $t.FontSize = $Size
  $t.Foreground = Brush $C_Glyph
  $t.VerticalAlignment = 'Center'
  $t.TextAlignment = 'Center'
  $t.Width = 18
  return $t
}

function Get-Logo {
  if ($script:LogoDone) { return $script:Logo }
  $script:LogoDone = $true
  try {
    $ico = New-Object System.Drawing.Icon($IcoPath, 32, 32)
    $bmp = $ico.ToBitmap()
    $ms = New-Object System.IO.MemoryStream
    $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
    $ms.Position = 0
    $img = New-Object System.Windows.Media.Imaging.BitmapImage
    $img.BeginInit()
    $img.StreamSource = $ms
    $img.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
    $img.EndInit()
    $img.Freeze()
    $ico.Dispose(); $bmp.Dispose()
    $script:Logo = $img
    return $img
  } catch { return $null }
}

function New-Row {
  param([string]$Glyph, [string]$Label, [scriptblock]$OnClick)
  $b = New-Object System.Windows.Controls.Border
  $b.CornerRadius = Corner 8
  $b.Padding = Thick 22 8 12 8
  $b.Margin = Thick 6 1 6 1
  $b.Background = [System.Windows.Media.Brushes]::Transparent
  $b.Cursor = [System.Windows.Input.Cursors]::Hand

  $g = New-Object System.Windows.Controls.StackPanel
  $g.Orientation = 'Horizontal'
  [void]$g.Children.Add((New-Glyph -Hex $Glyph))
  $sp = New-Object System.Windows.Controls.Border
  $sp.Width = 10
  [void]$g.Children.Add($sp)
  [void]$g.Children.Add((New-Text -Text $Label -Size 12.5 -Color $C_Text))
  $b.Child = $g

  $b.add_MouseEnter({ $this.Background = Brush $C_Hover }.GetNewClosure())
  $b.add_MouseLeave({ $this.Background = [System.Windows.Media.Brushes]::Transparent })
  $b.add_MouseLeftButtonUp([System.Windows.Input.MouseButtonEventHandler]{ param($s, $e) & $OnClick }.GetNewClosure())
  return $b
}

function New-Panel {
  param([string]$State, [string]$Reason)

  $root = New-Object System.Windows.Controls.Border
  $root.Width = 300
  $root.Background = Brush $C_Bg
  $root.BorderBrush = Brush $C_Brd
  $root.BorderThickness = Thick 1 1 1 1
  $root.CornerRadius = Corner 14
  # Text crispness: layered/transparent windows lose ClearType by default, and the
  # default Ideal text formatting mode looks soft at 10-12.5 px. Display mode uses
  # GDI-compatible metrics; ClearTypeHint re-enables subpixel AA over the opaque bg.
  [System.Windows.Media.RenderOptions]::SetClearTypeHint($root, [System.Windows.Media.ClearTypeHint]::Enabled)
  [System.Windows.Media.TextOptions]::SetTextFormattingMode($root, [System.Windows.Media.TextFormattingMode]::Display)
  [System.Windows.Media.TextOptions]::SetTextRenderingMode($root, [System.Windows.Media.TextRenderingMode]::ClearType)
  $root.SnapsToDevicePixels = $true
  $root.UseLayoutRounding = $true
  # Hold the auto-hide countdown while the pointer is inside: moving toward the
  # "open log" row must not race the fade-out.
  $root.add_MouseEnter({ if ($script:HideTimer) { $script:HideTimer.Stop() } })
  $root.add_MouseLeave({ if ($script:HideArmed) { Start-HideTimer $script:HideMs } })

  $outer = New-Object System.Windows.Controls.StackPanel
  $outer.Margin = Thick 0 6 0 6

  $head = New-Object System.Windows.Controls.Grid
  $head.Margin = Thick 16 12 16 10
  $c1 = New-Object System.Windows.Controls.ColumnDefinition; $c1.Width = 'Auto'
  $c2 = New-Object System.Windows.Controls.ColumnDefinition; $c2.Width = '*'
  [void]$head.ColumnDefinitions.Add($c1)
  [void]$head.ColumnDefinitions.Add($c2)

  $logo = New-Object System.Windows.Controls.Border
  $logo.Width = 30; $logo.Height = 30
  $logo.CornerRadius = Corner 8
  $logo.VerticalAlignment = 'Center'
  $src = Get-Logo
  if ($src) {
    $ib = New-Object System.Windows.Media.ImageBrush($src)
    $ib.Stretch = [System.Windows.Media.Stretch]::UniformToFill
    $logo.Background = $ib
  } else {
    $logo.Background = Brush '#232324'
  }
  [System.Windows.Controls.Grid]::SetColumn($logo, 0)
  [void]$head.Children.Add($logo)

  $txt = New-Object System.Windows.Controls.StackPanel
  $txt.Margin = Thick 10 0 0 0
  $txt.VerticalAlignment = 'Center'
  [void]$txt.Children.Add((New-Text -Text $L.appName -Size 13 -Color $C_Text -Weight 'SemiBold'))

  $st = New-Object System.Windows.Controls.StackPanel
  $st.Orientation = 'Horizontal'
  $st.Margin = Thick 0 3 0 0
  $dot = New-Object System.Windows.Controls.Border
  $dot.Width = 6; $dot.Height = 6
  $dot.CornerRadius = Corner 3
  $dot.VerticalAlignment = 'Center'

  $color = $C_Gray; $label = $L.statusStopped; $hint = ''
  if ($State -eq 'running')  { $color = $C_Green; $label = $L.statusRunning }
  if ($State -eq 'starting') { $color = $C_Amber; $label = $L.statusStarting }
  if ($State -eq 'stopping') {
    $color = $C_Amber
    $label = $L.statusStopping
    if (-not $label) { $label = $L.statusStarting }
  }
  if ($State -eq 'failed') {
    $color = $C_Red
    $label = $L.statusFailed
    $hint  = $L.hintStartFail
    if ($Reason -eq 'port')  { $hint = $L.hintPortBusy }
    if ($Reason -eq 'token') { $hint = $L.hintNoToken }
    if ($Reason -eq 'linger') { $hint = $L.hintLinger }
    if ($Reason -eq 'nounit') { $hint = $L.hintNoUnit }
    if ($Reason -eq 'stop')  {
      $hint = $L.hintStopFail
      if ($L.statusStopFailed) { $label = $L.statusStopFailed }
    }
  }

  $dot.Background = Brush $color
  [void]$st.Children.Add($dot)
  $pad = New-Object System.Windows.Controls.Border; $pad.Width = 6
  [void]$st.Children.Add($pad)
  [void]$st.Children.Add((New-Text -Text ($label + '   ' + $L.dotSep + '   ' + $script:BindHost + ':' + $script:Port) -Size 10.5 -Color $C_Sub))
  [void]$txt.Children.Add($st)

  if ($hint) {
    $ht = New-Text -Text $hint -Size 10 -Color $C_Red
    $ht.TextWrapping = 'Wrap'
    $ht.VerticalAlignment = 'Top'
    $ht.Margin = Thick 0 4 0 0
    [void]$txt.Children.Add($ht)
  }

  [System.Windows.Controls.Grid]::SetColumn($txt, 1)
  [void]$head.Children.Add($txt)
  [void]$outer.Children.Add($head)

  $sep = New-Object System.Windows.Controls.Border
  $sep.Height = 1
  $sep.Background = Brush $C_Line
  $sep.Margin = Thick 12 0 12 6
  [void]$outer.Children.Add($sep)

  [void]$outer.Children.Add((New-Row -Glyph 'E8A7' -Label $L.menuOpen    -OnClick { Open-UI }))
  [void]$outer.Children.Add((New-Row -Glyph 'E72C' -Label $L.menuRestart -OnClick { Restart-Server }))
  [void]$outer.Children.Add((New-Row -Glyph 'E71A' -Label $L.menuStop    -OnClick { Confirm-Stop }))
  if ($State -eq 'failed') {
    [void]$outer.Children.Add((New-Row -Glyph 'E7C3' -Label $L.menuLog -OnClick { Open-Log }))
  }

  $sep2 = New-Object System.Windows.Controls.Border
  $sep2.Height = 1
  $sep2.Background = Brush $C_Line
  $sep2.Margin = Thick 12 6 12 6
  [void]$outer.Children.Add($sep2)

  $exitRow = New-Row -Glyph 'E7E8' -Label $L.menuExit -OnClick { Exit-App }
  $exitRow.Margin = Thick 6 1 6 5
  [void]$outer.Children.Add($exitRow)

  $root.Child = $outer
  return $root
}

function Open-Log {
  Hide-Panel
  if (Test-Path $LogUnc) {
    Start-Process -FilePath 'notepad.exe' -ArgumentList $LogUnc
  } else {
    Start-Process -FilePath 'C:\Windows\System32\wsl.exe' -ArgumentList $LogArgs
  }
}

# --- non-blocking service control -------------------------------------------
# The service belongs to systemd (a user unit), not to this tray: quitting or
# crashing the tray must not stop dsh, and `Restart=on-failure` in the unit
# covers a dsh crash. Every operation spawns `wsl.exe ... systemctl --user`
# without waiting; Update-Op polls the process and the port on the op timer.

function New-WslProcess([string]$Arguments) {
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = 'C:\Windows\System32\wsl.exe'
  $psi.Arguments = $Arguments
  $psi.UseShellExecute = $false
  $psi.CreateNoWindow = $true
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $p = [System.Diagnostics.Process]::Start($psi)
  # Drain both pipes: a redirected pipe that nobody reads blocks wsl.exe once
  # the buffer fills, which used to look like a start that never finished.
  $script:OpStdout = $p.StandardOutput.ReadToEndAsync()
  $script:OpStderr = $p.StandardError.ReadToEndAsync()
  return $p
}

function Get-WslOutput([System.Diagnostics.Process]$P) {
  $parts = @()
  try { if ($script:OpStdout -and $script:OpStdout.IsCompleted) { $parts += $script:OpStdout.Result.Trim() } } catch { }
  try { if ($script:OpStderr -and $script:OpStderr.IsCompleted) { $parts += $script:OpStderr.Result.Trim() } } catch { }
  $text = (($parts | Where-Object { $_ }) -join ' | ')
  return $text
}

# Short synchronous call for diagnostics (`is-active`, `status`). Never used on
# the 3 s poll path, because every wsl.exe spawn costs a process hand-off.
function Invoke-Systemctl([string]$Verb) {
  $p = $null
  try {
    $p = New-WslProcess ($WslBase + 'systemctl --user --no-pager ' + $Verb + ' ' + $script:Unit)
    if (-not $p.WaitForExit(8000)) { try { $p.Kill() } catch { }; return @{ Code = -1; Text = 'timeout after 8000ms' } }
    return @{ Code = $p.ExitCode; Text = (Get-WslOutput $p) }
  } catch {
    return @{ Code = -2; Text = $_.Exception.Message }
  } finally { if ($p) { try { $p.Dispose() } catch { } } }
}

function Start-OpTimer {
  if (-not $script:OpTimer) {
    $script:OpTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:OpTimer.Interval = [TimeSpan]::FromMilliseconds(400)
    $script:OpTimer.add_Tick({ Update-Op })
  }
  if (-not $script:OpTimer.IsEnabled) { $script:OpTimer.Start() }
}

function Stop-OpTimer {
  if ($script:OpTimer) { $script:OpTimer.Stop() }
}

function Complete-Start([bool]$Ok, [string]$Why = '') {
  $open = $script:OpOpen
  $p = $script:OpProc
  $script:OpOpen = $false
  $script:OpKind = ''
  Stop-OpTimer
  if ($Ok) {
    $script:State = 'running'
    $script:Reason = ''
    $script:PortKind = 'dsh'
  } else {
    if ($p) { try { if (-not $p.HasExited) { $p.Kill() } } catch { } }
    $script:State = 'failed'
    $r = $Why
    if (-not $r) { if (Test-Up) { $r = 'token' } else { $r = 'start'; $script:PortKind = 'free' } }
    $script:Reason = $r
  }
  $script:OpProc = $null
  Write-TrayLog ('start -> ok=' + $Ok + ' reason=' + $script:Reason)
  Update-PanelContent
  if ($Ok -and $open) { Open-Browser }
}

function Complete-Stop([bool]$Ok) {
  $next = $script:OpNext
  $script:OpNext = ''
  $script:OpProc = $null
  $script:OpKind = ''
  Stop-OpTimer
  if ($Ok) {
    $script:State = 'stopped'
    $script:Reason = ''
    $script:PortKind = 'free'
  } else {
    $script:State = 'failed'
    $script:Reason = 'stop'
    $script:PortKind = 'dsh'
  }
  Write-TrayLog ('stop -> ok=' + $Ok)
  Update-PanelContent
  if ($Ok -and $next -eq 'start') { [void](Begin-Start) }
}

function Update-Op {
  if (-not $script:OpKind) { Stop-OpTimer; return }
  $now = [DateTime]::Now
  if ($script:OpKind -eq 'start') {
    if (Test-Up -TimeoutMs 250) {
      # Readiness is the HTTP signature of dsh, not the token file: the 9p share
      # is the least reliable link in the chain and stays off the polling path.
      $code = Test-DshHttp -TimeoutMs 700
      if ($code -eq 401 -or $code -eq 303) { Complete-Start $true; return }
      if ($code -ne -2) { Complete-Start $false 'port'; return }
    }
    $exited = $false
    if ($script:OpProc) { try { $exited = $script:OpProc.HasExited } catch { $exited = $true } }
    if ($exited) {
      $rc = -1
      try { $rc = $script:OpProc.ExitCode } catch { }
      $text = Get-WslOutput $script:OpProc
      if ($rc -ne 0) {
        Write-TrayLog ('systemctl start failed rc=' + $rc + ' text=' + $text) 'error'
        $why = 'start'
        if ($text -match 'Failed to connect to bus|No medium found|Connection refused') { $why = 'linger' }
        elseif ($text -match 'not be found|not loaded|No such file|Unit .* not found') { $why = 'nounit' }
        Complete-Start $false $why
        return
      }
      # rc=0 but no listener yet: the unit is Type=simple, dsh still needs a
      # few seconds before it binds. Keep waiting until the deadline.
    }
    if ($now -gt $script:OpDeadline) { Complete-Start $false 'start'; return }
    return
  }
  if ($script:OpKind -eq 'stop') {
    if (-not (Test-Up)) { Complete-Stop $true; return }
    if ($now -gt $script:OpDeadline) {
      $text = Get-WslOutput $script:OpProc
      Write-TrayLog ('stop timed out text=' + $text) 'warn'
      Complete-Stop $false
    }
  }
}

function Begin-Start {
  if ($script:OpKind) { return $false }
  $p = Get-PortState
  if ($p -eq 'dsh') {
    $script:State = 'running'
    $script:Reason = ''
    $script:PortKind = 'dsh'
    Update-PanelContent
    return $true
  }
  if ($p -eq 'foreign') {
    $script:State = 'failed'
    $script:Reason = 'port'
    $script:PortKind = 'foreign'
    Write-TrayLog ('port ' + $script:Port + ' is held by a foreign listener') 'warn'
    Update-PanelContent
    return $false
  }
  $script:State = 'starting'
  $script:Reason = ''
  $script:PortKind = 'free'
  $script:OpKind = 'start'
  $script:OpDeadline = [DateTime]::Now.AddSeconds($script:StartTimeout)
  Write-TrayLog ('systemctl --user start ' + $script:Unit)
  try { $script:OpProc = New-WslProcess ($WslBase + 'systemctl --user start ' + $script:Unit) } catch {
    Write-TrayLog ('spawn failed: ' + $_.Exception.Message) 'error'
    $script:OpProc = $null
  }
  if (-not $script:OpProc) {
    $script:OpKind = ''
    $script:State = 'failed'
    $script:Reason = 'start'
    Update-PanelContent
    return $false
  }
  Start-OpTimer
  Update-PanelContent
  return $true
}

# Stop first, then wait for the port to actually release. A stop that leaves the
# port bound must not be reported as success: the panel would then show a dead
# service while the next start silently adopts the old instance.
function Begin-Stop {
  if ($script:OpKind -eq 'stop') { return }
  if ($script:OpKind -eq 'start') {
    if ($script:OpProc) { try { if (-not $script:OpProc.HasExited) { $script:OpProc.Kill() } } catch { } }
    $script:OpProc = $null
    $script:OpKind = ''
    Stop-OpTimer
  }
  $script:State = 'stopping'
  $script:Reason = ''
  $script:OpKind = 'stop'
  $script:OpDeadline = [DateTime]::Now.AddSeconds($script:StopTimeout)
  Write-TrayLog ('systemctl --user stop ' + $script:Unit)
  try { $script:OpProc = New-WslProcess ($WslBase + 'systemctl --user stop ' + $script:Unit) } catch {
    Write-TrayLog ('spawn failed: ' + $_.Exception.Message) 'error'
    $script:OpProc = $null
  }
  if (-not (Test-Up)) { Complete-Stop $true; return }
  Start-OpTimer
  Update-PanelContent
}

function Stop-Server { Begin-Stop }

# A modal question, owned by the panel when it exists so it cannot open behind
# another window. Falls back to the active desktop otherwise.
function Ask-Confirm([string]$Message, [string]$Fallback) {
  $msg = $Message
  if (-not $msg) { $msg = $Fallback }
  $title = [string]$L.appName
  $answer = $null
  if ($script:Panel) {
    $answer = [System.Windows.MessageBox]::Show($script:Panel, $msg, $title, 'YesNo', 'Warning')
  } else {
    $answer = [System.Windows.MessageBox]::Show($msg, $title, 'YesNo', 'Warning')
  }
  return ($answer -eq 'Yes')
}

# Stopping kills in-flight agent turns, so a single stray click must not do it.
function Confirm-Stop {
  if (-not $script:StopConfirm) { Stop-Server; return }
  Hide-Panel
  if (Ask-Confirm ([string]$L.confirmStop) 'Stop the service? Running agent turns will be aborted.') { Stop-Server }
}

function Restart-Server {
  if ($script:OpKind -eq 'stop') { return }
  if ($script:StopConfirm) {
    Hide-Panel
    if (-not (Ask-Confirm ([string]$L.confirmRestart) 'Restart the service? Running agent turns will be interrupted.')) { return }
  }
  $script:OpNext = 'start'
  Begin-Stop
}

function Open-Browser {
  $t = Get-Token -Robust
  if (-not $t) {
    Write-TrayLog 'no token found in the log tail' 'warn'
    $script:State = 'failed'
    $script:Reason = 'token'
    Show-Panel
    Start-HideTimer 8000
    return
  }
  Write-TrayLog 'opening browser tab'
  Start-Process ($script:BaseUrl + '?token=' + $t)
  Write-LastTokenHash $t
  Hide-Panel
}

function Open-UI {
  Hide-Panel
  # A start in flight will open the browser itself when it completes.
  if ($script:OpKind -eq 'start') { $script:OpOpen = $true; Show-Panel; return }
  if ($script:OpKind -eq 'stop') { return }

  $kind = Get-PortState
  if ($kind -eq 'foreign') {
    $script:State = 'failed'
    $script:Reason = 'port'
    $script:PortKind = 'foreign'
    Show-Panel
    Start-HideTimer 8000
    return
  }
  if ($kind -eq 'free') {
    $script:OpOpen = $true
    [void](Begin-Start)
    return
  }

  $script:PortKind = 'dsh'
  $script:State = 'running'
  $script:Reason = ''
  $t = Get-Token -Robust
  if (-not $t) {
    Write-TrayLog 'no token found in the log tail' 'warn'
    $script:State = 'failed'
    $script:Reason = 'token'
    Show-Panel
    Start-HideTimer 8000
    return
  }
  # Reuse the remembered tab only when it was opened with this very token. A tray
  # restart keeps the hash, a dsh restart changes the token and therefore opens a
  # fresh tab instead of focusing a page that will answer 401.
  $reuse = $false
  if ([bool]$C.focusBrowser) {
    $h = Get-TokenHash $t
    $reuse = ($h -ne '') -and ((Read-LastTokenHash) -eq $h)
  }
  if ($reuse) {
    $w = Find-DshWindow
    if ($w -ne [IntPtr]::Zero) {
      if (Focus-Window $w) { return }
    }
  }
  Start-Process ($script:BaseUrl + '?token=' + $t)
  Write-LastTokenHash $t
  Hide-Panel
}

# Fade out, then hide. The finishing step runs from a script-scope timer instead of
# the animation's Completed event: a GetNewClosure() scriptblock resolves $script: to
# the closure's own empty scope, so Completed handlers silently miss every variable.
function Complete-Hide {
  if ($script:HideWait) { $script:HideWait.Stop() }
  if (-not $script:Panel) { return }
  if ($script:HideGen -ne $script:HidePendingGen) { return }
  try {
    $script:Panel.Hide()
    $script:Panel.BeginAnimation([System.Windows.Window]::OpacityProperty, $null)
    $script:Panel.Opacity = 1.0
  } catch { }
}

function Hide-Panel {
  $script:HideArmed = $false
  if (-not $script:Panel) { return }
  if (-not $script:Panel.IsVisible) { return }
  if (-not $script:AnimOk) { $script:Panel.Hide(); return }
  $script:HideGen++
  $script:HidePendingGen = $script:HideGen
  $a = New-Object System.Windows.Media.Animation.DoubleAnimation
  $a.To = 0.0
  $a.Duration = [System.Windows.Duration]([TimeSpan]::FromMilliseconds(80))
  $a.FillBehavior = [System.Windows.Media.Animation.FillBehavior]::HoldEnd
  $script:Panel.BeginAnimation([System.Windows.Window]::OpacityProperty, $a)
  if (-not $script:HideWait) {
    $script:HideWait = New-Object System.Windows.Threading.DispatcherTimer
    $script:HideWait.Interval = [TimeSpan]::FromMilliseconds(95)
    $script:HideWait.add_Tick({ Complete-Hide })
  }
  $script:HideWait.Stop()
  $script:HideWait.Start()
}

function Start-FadeIn {
  if (-not $script:AnimOk) { $script:Panel.Opacity = 1.0; return }
  $a = New-Object System.Windows.Media.Animation.DoubleAnimation
  $a.From = 0.0
  $a.To = 1.0
  $a.Duration = [System.Windows.Duration]([TimeSpan]::FromMilliseconds(170))
  $e = New-Object System.Windows.Media.Animation.CubicEase
  $e.EasingMode = [System.Windows.Media.Animation.EasingMode]::EaseOut
  $a.EasingFunction = $e
  $script:Panel.BeginAnimation([System.Windows.Window]::OpacityProperty, $a)
}

function Start-HideTimer {
  param([int]$Ms = 2500)
  $script:HideMs = $Ms
  $script:HideArmed = $true
  if (-not $script:HideTimer) { return }
  $script:HideTimer.Interval = [TimeSpan]::FromMilliseconds($Ms)
  $script:HideTimer.Stop()
  $script:HideTimer.Start()
}

# WPF positions windows in DIPs while Screen/Cursor report physical pixels.
# At 125% scaling (2560x1440 -> 2048x1104 DIP) mixing the two pushes the panel
# far below the working area. Normalize everything into DIP space here.
function Get-DipScale {
  $b = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
  $spw = [System.Windows.SystemParameters]::PrimaryScreenWidth
  if ($spw -gt 0) { return ($b.Width / $spw) }
  return 1.0
}

function Get-PanelHeight {
  param([string]$State)
  $c = New-Panel -State $State -Reason ''
  $c.Measure((New-Object System.Windows.Size(300, [double]::PositiveInfinity)))
  $h = [Math]::Ceiling($c.DesiredSize.Height)
  if ($h -lt 100) { $h = 270 }
  return $h
}

function Get-PanelPlacement {
  param([double]$H, [int]$Cx = -1, [int]$Cy = -1)
  $scale = Get-DipScale
  $wa = [System.Windows.SystemParameters]::WorkArea
  if ($Cx -lt 0 -or $Cy -lt 0) {
    $p = [System.Windows.Forms.Cursor]::Position
    $Cx = $p.X; $Cy = $p.Y
  }
  $x = $Cx / $scale
  $y = $Cy / $scale
  $left = [Math]::Min([Math]::Max($x + 16 - 300, $wa.Left + 8), $wa.Right - 300 - 8)
  $top = $y - $H - 12
  if ($top -lt ($wa.Top + 8)) { $top = $wa.Top + 8 }
  if (($top + $H) -gt ($wa.Bottom - 8)) { $top = $wa.Bottom - 8 - $H }
  return @{ Left = $left; Top = $top; Scale = $scale; Wa = $wa; H = $H; Cx = $Cx; Cy = $Cy }
}

$script:PanelCache = @{}
$script:Phase      = $false
$script:PhaseMarks = New-Object System.Collections.ArrayList

function Mark {
  param([string]$Label, $Sw)
  if ($script:Phase -and $Sw) { [void]$script:PhaseMarks.Add($Label + '=' + $Sw.ElapsedMilliseconds) }
}

# One cached visual tree per (state, reason) keeps a click from rebuilding ~40
# text elements, re-decoding the icon and re-parsing hex colors.
function Get-PanelEntry {
  param([string]$State, [string]$Reason)
  $Key = $State + '|' + $Reason
  if ($script:PanelCache.ContainsKey($Key)) { return $script:PanelCache[$Key] }
  $c = New-Panel -State $State -Reason $Reason
  $c.Measure((New-Object System.Windows.Size(300, [double]::PositiveInfinity)))
  $h = [Math]::Ceiling($c.DesiredSize.Height)
  if ($h -lt 100) { $h = 270 }
  $entry = @{ Content = $c; H = $h }
  $script:PanelCache[$Key] = $entry
  return $entry
}

function Get-PanelKey { return ($script:State + '|' + $script:Reason) }

# Swap the cached tree in place while the panel is open, so a state change during
# a start/stop is visible without closing and reopening the flyout.
function Update-PanelContent {
  if (-not $script:Panel) { return }
  if (-not $script:Panel.IsVisible) { return }
  if ($script:Prewarming) { return }
  $k = Get-PanelKey
  if ($k -eq $script:ShownKey) { return }
  $script:ShownKey = $k
  $entry = Get-PanelEntry -State $script:State -Reason $script:Reason
  $script:Panel.Content = $entry.Content
  $pl = Get-PanelPlacement -H $entry.H
  $script:Panel.Left = $pl.Left
  $script:Panel.Top = $pl.Top
}

function Ensure-PanelWindow {
  if ($script:Panel) { return }
  $w = New-Object System.Windows.Window
  $w.WindowStyle = 'None'
  $w.AllowsTransparency = $true
  $w.Background = [System.Windows.Media.Brushes]::Transparent
  $w.ShowInTaskbar = $false
  $w.Topmost = $true
  $w.SizeToContent = 'WidthAndHeight'
  $w.ResizeMode = 'NoResize'
  $w.ShowActivated = $true
  $w.add_Deactivated({ Hide-Panel })
  $w.add_KeyDown({ param($s, $e) if ($e.Key -eq 'Escape') { Hide-Panel } })
  $script:Panel = $w
}

# Pay the lazy WPF cost (window handle, theme resources, DirectWrite font cache)
# once at startup instead of on the first right click. The window is composed at
# the real anchor position with near-zero opacity, so the first visible frame is
# already prepared instead of being built on the click.
function Prewarm-Panel {
  try {
    Ensure-PanelWindow
    $entry = Get-PanelEntry -State $script:State -Reason $script:Reason
    $script:ShownKey = Get-PanelKey
    $script:Panel.Content = $entry.Content
    $pl = Get-PanelPlacement -H $entry.H
    $script:Panel.Left    = $pl.Left
    $script:Panel.Top     = $pl.Top
    $script:Panel.ShowActivated = $false
    $script:Panel.Opacity = 0.01
    $script:Panel.Show()
    # Showing and hiding inside one dispatcher tick produces no frame at all, so
    # the expensive first composition would still land on the first real click.
    # Keep it alive for a couple of frames before hiding.
    $script:Prewarming = $true
    if (-not $script:WarmHide) {
      $script:WarmHide = New-Object System.Windows.Threading.DispatcherTimer
      $script:WarmHide.Interval = [TimeSpan]::FromMilliseconds(180)
      $script:WarmHide.add_Tick({
        $script:WarmHide.Stop()
        if ($script:Prewarming) {
          $script:Prewarming = $false
          Hide-Panel
          $script:Panel.Opacity = 1.0
        }
      })
    }
    $script:WarmHide.Start()
    return $true
  } catch {
    try { $script:Panel.Opacity = 1.0 } catch { }
    return $false
  }
}

function Show-Panel {
  $swP = $null
  if ($script:Phase) { $swP = [System.Diagnostics.Stopwatch]::StartNew() }
  $script:Prewarming = $false
  $script:HideGen++
  if ($script:Panel) { $script:Panel.Opacity = 1.0 }
  # Identity is owned by the 3 s poll; re-probing here would add up to 1.5 s to the
  # click. Only the cheap TCP probe runs on the open path.
  if (-not $script:OpKind) {
    if (Test-Up) {
      if ($script:State -ne 'failed') { $script:State = 'running' }
    } elseif ($script:State -ne 'failed' -and $script:State -ne 'stopping') {
      $script:State = 'stopped'
    }
  }
  Mark 'probe' $swP
  Ensure-PanelWindow
  $entry = Get-PanelEntry -State $script:State -Reason $script:Reason
  $script:ShownKey = Get-PanelKey
  Mark 'entry' $swP
  $script:Panel.Content = $entry.Content
  $pl = Get-PanelPlacement -H $entry.H
  Mark 'place' $swP
  $script:Panel.Left = $pl.Left
  $script:Panel.Top  = $pl.Top
  $script:Panel.ShowActivated = $true
  $already = $script:Panel.IsVisible
  if (-not $already) {
    $script:Panel.BeginAnimation([System.Windows.Window]::OpacityProperty, $null)
    if ($script:AnimOk) { $script:Panel.Opacity = 0.0 } else { $script:Panel.Opacity = 1.0 }
    $script:Panel.Show()
  } elseif ($script:AnimOk) {
    # still on screen but possibly mid fade-out: cancel it and settle at full opacity
    $script:Panel.BeginAnimation([System.Windows.Window]::OpacityProperty, $null)
    $script:Panel.Opacity = 1.0
  }
  Mark 'show' $swP
  $script:Panel.Activate()
  if (-not $already) { Start-FadeIn }
  Mark 'activate' $swP
}

# Quitting the tray never stops the service: systemd owns it. Killing the
# in-flight wsl.exe client is enough to release this process.
function Exit-App {
  Write-TrayLog 'exit requested'
  if ($script:OpProc) { try { if (-not $script:OpProc.HasExited) { $script:OpProc.Kill() } } catch { } }
  if ($script:Tray) { $script:Tray.Visible = $false; $script:Tray.Dispose() }
  if ($script:Panel) { $script:Panel.Close() }
  if ($script:Mutex) { try { $script:Mutex.ReleaseMutex() } catch { } }
  $script:Run = $false
  [System.Windows.Application]::Current.Shutdown()
}

if ($ListWindows) {
  if (-not (Ensure-Win32)) { Write-Output 'win32: UNAVAILABLE'; exit 1 }
  $marker = [string]$L.windowMarker
  Write-Output ('marker = ' + $marker)
  $all = Get-WindowList
  Write-Output ('visible windows = ' + $all.Count)
  foreach ($w in $all) {
    $isB = $script:BrowserProc -contains $w.Proc
    $hit = ($w.Title -like "*$marker*")
    if ($isB -or $hit) {
      Write-Output ('  ' + $w.Proc + ' pid=' + $w.Pid + ' hwnd=' + $w.Hwnd + ' browser=' + $isB + ' hit=' + $hit + ' :: ' + $w.Title)
    }
  }
  $h = Find-DshWindow
  Write-Output ('find  = ' + $h)
  exit 0
}

if ($FocusTest) {
  $h = Find-DshWindow
  if ($h -eq [IntPtr]::Zero) { Write-Output 'find  = 0 (no dsh window)'; exit 0 }
  $ok = Focus-Window $h
  $fg = [DshWin32]::GetForegroundWindow()
  Write-Output ('find  = ' + $h)
  Write-Output ('focus = ' + $ok + '  foregroundNow = ' + $fg + '  match = ' + ($fg -eq $h))
  exit 0
}

if ($AnimTest) {
  $app = New-Object System.Windows.Application
  $app.ShutdownMode = [System.Windows.ShutdownMode]::OnExplicitShutdown
  $script:State = 'running'
  $script:AnimOut = New-Object System.Collections.ArrayList
  $script:AnimStep = 0
  $t = New-Object System.Windows.Threading.DispatcherTimer
  $t.Interval = [TimeSpan]::FromMilliseconds(45)
  $t.add_Tick({
    $script:AnimStep++
    if ($script:AnimStep -eq 1) {
      Show-Panel
      [void]$script:AnimOut.Add('t=0ms   opacity=' + [math]::Round($script:Panel.Opacity, 3))
      return
    }
    if ($script:AnimStep -le 5) {
      $ms = ($script:AnimStep - 1) * 45
      [void]$script:AnimOut.Add('t=' + $ms + 'ms  opacity=' + [math]::Round($script:Panel.Opacity, 3))
      return
    }
    if ($script:AnimStep -eq 6) {
      Hide-Panel
      [void]$script:AnimOut.Add('hide called, opacity=' + [math]::Round($script:Panel.Opacity, 3))
      return
    }
    if ($script:AnimStep -le 9) {
      [void]$script:AnimOut.Add('after hide +' + (($script:AnimStep - 6) * 45) + 'ms visible=' + $script:Panel.IsVisible + ' opacity=' + [math]::Round($script:Panel.Opacity, 3))
      return
    }
    $t.Stop()
    $app.Shutdown()
  })
  $t.Start()
  [void]$app.Run()
  foreach ($line in $script:AnimOut) { Write-Output $line }
  exit 0
}

if ($AnchorTest) {
  $h = Get-PanelHeight -State $AnchorState
  $pl = Get-PanelPlacement -H $h -Cx $CursorX -Cy $CursorY
  Write-Output ('scale   = ' + $pl.Scale)
  Write-Output ('workarea= ' + $pl.Wa.Left + ',' + $pl.Wa.Top + ' - ' + $pl.Wa.Right + ',' + $pl.Wa.Bottom)
  Write-Output ('cursor  = ' + $pl.Cx + ',' + $pl.Cy + ' (physical px)')
  Write-Output ('size    = 300 x ' + $h + ' (DIP)')
  $l = [math]::Round($pl.Left); $t = [math]::Round($pl.Top)
  Write-Output ('panel   = L' + $l + ' T' + $t + ' R' + ($l + 300) + ' B' + ($t + $h))
  $inB = (($pl.Top + $h) -le $pl.Wa.Bottom)
  $inR = (($pl.Left + 300) -le $pl.Wa.Right)
  $inT = ($pl.Top -ge $pl.Wa.Top)
  $inL = ($pl.Left -ge $pl.Wa.Left)
  Write-Output ('inside  = ' + ($inB -and $inR -and $inT -and $inL))
  exit 0
}

if ($Probe -gt 0) {
  Write-Output ('port ' + $Probe + ' = ' + (Get-PortState -Port $Probe))
  exit 0
}

# Configuration resolution: prints what every other switch would use, without
# touching the service. Run it right after editing dsh-tray.config.json.
if ($ConfigTest) {
  Write-Output ('config   = ' + $ConfigFile)
  Write-Output ('distro   = ' + $script:Distro)
  Write-Output ('user     = ' + $script:LinuxUser)
  Write-Output ('endpoint = ' + $script:BindHost + ':' + $script:Port)
  Write-Output ('unit     = ' + $script:Unit)
  Write-Output ('logunc   = ' + $LogUnc)
  Write-Output ('logexists= ' + (Test-Path $LogUnc))
  foreach ($f in @($ConfigFile, $IcoPath, $LabelFile)) {
    Write-Output ('file     = ' + $f + ' exists=' + (Test-Path $f))
  }
  exit 0
}

# Controller diagnostics: prints the exact commands and the unit state. It does
# spawn wsl.exe (which boots the distro) but never starts or stops the unit.
if ($ControllerTest) {
  Write-Output ('unit       = ' + $script:Unit)
  Write-Output ('cmd start  = wsl.exe ' + $WslBase + 'systemctl --user start ' + $script:Unit)
  Write-Output ('cmd stop   = wsl.exe ' + $WslBase + 'systemctl --user stop ' + $script:Unit)
  $r = Invoke-Systemctl 'is-active'
  Write-Output ('is-active  = ' + $r.Text + '  (rc=' + $r.Code + ')')
  $r = Invoke-Systemctl 'is-enabled'
  Write-Output ('is-enabled = ' + $r.Text + '  (rc=' + $r.Code + ')')
  $r = Invoke-Systemctl 'status'
  Write-Output '--- systemctl status ---'
  Write-Output $r.Text
  exit 0
}

# Token plumbing check: length only, never the value. Deliberately does not write
# the hash file, so a first click still opens a fresh tab after this upgrade.
if ($TokenTest) {
  $t = Get-Token -Robust
  if (-not $t) { Write-Output 'token = MISSING'; exit 1 }
  Write-Output ('token = ok  len=' + $t.Length)
  $h = Get-TokenHash $t
  Write-Output ('hash  = ' + $h.Substring(0, 16) + '...')
  Write-Output ('last  = ' + (Read-LastTokenHash))
  Write-Output ('reuse = ' + ($h -eq (Read-LastTokenHash)))
  exit 0
}

# Stop, then start, while a 50 ms heartbeat measures how long the dispatcher is
# starved. A blocking wait would show up as a multi-second gap; the async state
# machine must keep the heartbeat under a few hundred ms.
if ($SelfTest) {
  $app = New-Object System.Windows.Application
  $app.ShutdownMode = [System.Windows.ShutdownMode]::OnExplicitShutdown
  $script:SelfLog    = New-Object System.Collections.ArrayList
  $script:SelfPhase  = 0
  $script:SelfTicks  = 0
  $script:SelfMaxGap = 0
  $script:SelfGapSum = 0
  $script:SelfLast   = [DateTime]::Now
  $script:SelfState  = $script:State
  $script:SelfT0     = [DateTime]::Now
  $script:SelfStopMs = 0
  $script:SelfStartMs = 0
  $script:SelfStopGap = 0
  $script:SelfStartGap = 0

  $beat = New-Object System.Windows.Threading.DispatcherTimer
  $beat.Interval = [TimeSpan]::FromMilliseconds(50)
  $beat.add_Tick({
    $now = [DateTime]::Now
    $gap = ($now - $script:SelfLast).TotalMilliseconds
    $script:SelfLast = $now
    $script:SelfTicks++
    if ($gap -gt $script:SelfMaxGap) { $script:SelfMaxGap = $gap }
    if ($script:State -ne $script:SelfState) {
      $script:SelfState = $script:State
      [void]$script:SelfLog.Add('t=' + [int](([DateTime]::Now - $script:SelfT0).TotalMilliseconds) + 'ms state=' + $script:State + ' reason=' + $script:Reason + ' kind=' + $script:PortKind)
    }
  })
  $beat.Start()

  # Seed the state from the port before driving anything: the tray normally gets
  # this from Begin-Start at startup, which the test path skips.
  $seed = Get-PortState
  if ($seed -eq 'dsh') { $script:State = 'running'; $script:PortKind = 'dsh' }
  elseif ($seed -eq 'foreign') { $script:State = 'failed'; $script:Reason = 'port'; $script:PortKind = 'foreign' }
  else { $script:State = 'stopped'; $script:PortKind = 'free' }
  $script:SelfState = $script:State

  $drv = New-Object System.Windows.Threading.DispatcherTimer
  $drv.Interval = [TimeSpan]::FromMilliseconds(120)
  $drv.add_Tick({
    if ($script:SelfPhase -eq 0) {
      if ($script:OpKind) { return }
      if ($script:State -ne 'running') {
        [void]$script:SelfLog.Add('abort: initial state=' + $script:State + ' reason=' + $script:Reason)
        $script:SelfPhase = 9
        return
      }
      $script:SelfGapSum = 0
      $script:SelfStopT0 = [DateTime]::Now
      $script:SelfStopGap = $script:SelfMaxGap
      $script:SelfPhase = 1
      Begin-Stop
      return
    }
    if ($script:SelfPhase -eq 1) {
      if ($script:State -eq 'stopping') { return }
      $script:SelfStopMs = [int](([DateTime]::Now - $script:SelfStopT0).TotalMilliseconds)
      $script:SelfStopGap = [int]($script:SelfMaxGap)
      $script:SelfMaxGap = 0
      $script:SelfStartT0 = [DateTime]::Now
      $script:SelfPhase = 2
      [void](Begin-Start)
      return
    }
    if ($script:SelfPhase -eq 2) {
      if ($script:State -eq 'starting') { return }
      $script:SelfStartMs = [int](([DateTime]::Now - $script:SelfStartT0).TotalMilliseconds)
      $script:SelfStartGap = [int]($script:SelfMaxGap)
      $script:SelfPhase = 9
      return
    }
    if ($script:SelfPhase -eq 9) {
      $drv.Stop()
      $beat.Stop()
      $app.Shutdown()
    }
  })
  $drv.Start()
  [void]$app.Run()

  foreach ($line in $script:SelfLog) { Write-Output $line }
  Write-Output ('stop   = ' + $script:SelfStopMs + ' ms  maxDispatcherGap=' + $script:SelfStopGap + ' ms')
  Write-Output ('start  = ' + $script:SelfStartMs + ' ms  maxDispatcherGap=' + $script:SelfStartGap + ' ms')
  Write-Output ('final  = ' + $script:State + ' reason=' + $script:Reason + ' kind=' + $script:PortKind + ' port=' + (Get-PortState))
  # Written to disk as well: stdout from a -File run is not always captured.
  $dump = New-Object System.Collections.ArrayList
  foreach ($line in $script:SelfLog) { [void]$dump.Add($line) }
  [void]$dump.Add('stop   = ' + $script:SelfStopMs + ' ms  maxDispatcherGap=' + $script:SelfStopGap + ' ms')
  [void]$dump.Add('start  = ' + $script:SelfStartMs + ' ms  maxDispatcherGap=' + $script:SelfStartGap + ' ms')
  [void]$dump.Add('final  = ' + $script:State + ' reason=' + $script:Reason)
  try { [System.IO.File]::WriteAllLines((Join-Path $Root 'selftest.txt'), [string[]]$dump) } catch { }
  exit 0
}

if ($Render) {
  if ($RenderReason) { $script:Reason = $RenderReason }
  $p = New-Panel -State $RenderState -Reason $script:Reason
  $p.Measure((New-Object System.Windows.Size(300, [double]::PositiveInfinity)))
  $h = [Math]::Ceiling($p.DesiredSize.Height)
  $p.Arrange((New-Object System.Windows.Rect(0, 0, 300, $h)))
  $p.UpdateLayout()
  $s = 2
  $rtb = New-Object System.Windows.Media.Imaging.RenderTargetBitmap((300 * $s), ([int]$h * $s), 192, 192, ([System.Windows.Media.PixelFormats]::Pbgra32))
  $rtb.Render($p)
  $enc = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
  $enc.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($rtb))
  $out = Join-Path $Root ('panel-' + $RenderState + '.png')
  $fs = [System.IO.File]::Create($out)
  $enc.Save($fs); $fs.Close()
  Write-Output ('rendered state=' + $RenderState + ' reason=' + $script:Reason + ' h=' + $h + ' ap=' + [System.Threading.Thread]::CurrentThread.GetApartmentState())
  exit 0
}

# --- single instance (P0-2) ---
$scope = 'Global'
$mName = "dsh-tray-$env:USERNAME"
try {
  $script:Mutex = New-Object System.Threading.Mutex -ArgumentList @($false, "Global\$mName")
} catch {
  $scope = 'Local'
  $script:Mutex = New-Object System.Threading.Mutex -ArgumentList @($false, "Local\$mName")
}
$owned = $false
try {
  $owned = $script:Mutex.WaitOne(0, $false)
} catch [System.Threading.AbandonedMutexException] {
  $owned = $true
}
if (-not $owned) {
  try {
    $e = New-Object System.Threading.EventWaitHandle -ArgumentList @($false, [System.Threading.EventResetMode]::AutoReset, "$scope\dsh-show-$env:USERNAME")
    [void]$e.Set()
    $e.Dispose()
  } catch { }
  exit 0
}
$script:PokeScope = $scope
try {
  $script:PokeEvt = New-Object System.Threading.EventWaitHandle -ArgumentList @($false, [System.Threading.EventResetMode]::AutoReset, "$scope\dsh-show-$env:USERNAME")
} catch { $script:PokeEvt = $null }

if ($NoStart) {
  Write-TrayLog 'NoStart: not touching the service'
  if (Test-Up) { $script:State = 'running'; $script:PortKind = 'dsh' }
} else {
  [void](Begin-Start)
}

$script:Tray = New-Object System.Windows.Forms.NotifyIcon
$script:Tray.Icon = New-Object System.Drawing.Icon($IcoPath)
$script:Tray.Text = $L.tooltip
$script:Tray.Visible = $true
# left click -> open the UI in the browser; right click -> flyout panel.
# Debounced so a double click does not open two tabs.
$script:Tray.add_MouseUp({
  param($s, $e)
  if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Right) {
    Show-Panel
    return
  }
  if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
    $now = [DateTime]::Now
    if (($now - $script:LastOpen).TotalMilliseconds -lt 800) { return }
    $script:LastOpen = $now
    Open-UI
  }
})

$app = New-Object System.Windows.Application
$app.ShutdownMode = [System.Windows.ShutdownMode]::OnExplicitShutdown
# A stray exception in a timer or click handler used to kill the tray with no
# trace (its console window is hidden). Log it, keep the process alive, and let
# the poll put the state back on its feet.
$app.add_DispatcherUnhandledException({
  param($s, $e)
  Write-TrayLog ('unhandled: ' + $e.Exception.GetType().Name + ': ' + $e.Exception.Message) 'error'
  Write-TrayLog ('stack: ' + $e.Exception.StackTrace) 'error'
  $e.Handled = $true
})

# warm the panel shortly after the tray icon appears, so the first right click
# does not pay the lazy WPF / window-creation cost
if (-not $BenchPanel) {
  $script:WarmTimer = New-Object System.Windows.Threading.DispatcherTimer
  $script:WarmTimer.Interval = [TimeSpan]::FromMilliseconds(600)
  $script:WarmTimer.add_Tick({
    $script:WarmTimer.Stop()
    [void](Prewarm-Panel)
  })
  $script:WarmTimer.Start()
}

$script:HideTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:HideTimer.Interval = [TimeSpan]::FromMilliseconds($script:HideMs)
$script:HideTimer.add_Tick({ $script:HideTimer.Stop(); $script:HideArmed = $false; Hide-Panel })

$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromSeconds([Math]::Max(1, $script:PollSeconds))
$timer.add_Tick({
  if ($script:OpKind) { return }
  if ($script:Prewarming) { return }
  $before = Get-PanelKey
  if (Test-Up) {
    if ($script:PortKind -ne 'dsh') {
      # A foreign listener that never answers HTTP costs ~2 s of dispatcher time
      # per probe, so probe it once and trust the negative result until the port
      # goes away or a minute passes: never burn the UI thread every 3 s.
      if ($script:ForeignUntil -gt [DateTime]::Now) {
        $script:PortKind = 'foreign'
      } else {
        $code = Test-DshHttp -TimeoutMs 1000
        if ($code -eq 401 -or $code -eq 303) {
          $script:PortKind = 'dsh'
        } else {
          $script:PortKind = 'foreign'
          $script:ForeignUntil = [DateTime]::Now.AddSeconds(60)
          Write-TrayLog ('port ' + $script:Port + ' belongs to a foreign listener (cached for 60s)') 'warn'
        }
      }
    }
    if ($script:PortKind -eq 'dsh') {
      if ($script:State -eq 'failed') {
        # Recover on its own, except for a failed stop: that one needs the red
        # state kept until the user acts again.
        if ($script:Reason -ne 'stop') {
          if ($script:Reason -eq 'token') {
            if (Get-Token) { $script:State = 'running'; $script:Reason = '' }
          } else {
            $script:State = 'running'
            $script:Reason = ''
          }
        }
      } else {
        $script:State = 'running'
        $script:Reason = ''
      }
    } else {
      if ($script:State -ne 'failed') { $script:State = 'failed'; $script:Reason = 'port' }
    }
  } else {
    $script:PortKind = 'free'
    $script:ForeignUntil = [DateTime]::MinValue
    if ($script:State -eq 'failed') {
      if ($script:Reason -eq 'port') { $script:State = 'stopped'; $script:Reason = '' }
    } elseif ($script:State -ne 'stopping') {
      $script:State = 'stopped'
      $script:Reason = ''
    }
  }
  if ((Get-PanelKey) -ne $before) { Update-PanelContent }
})
$timer.Start()

# second launch pokes the running instance through a named event
if ($script:PokeEvt) {
  $poke = New-Object System.Windows.Threading.DispatcherTimer
  $poke.Interval = [TimeSpan]::FromMilliseconds(700)
  $poke.add_Tick({ if ($script:PokeEvt.WaitOne(0)) { Show-Panel } })
  $poke.Start()
}

try {
  [void]$app.Run()
} catch {
  Write-TrayLog ('fatal: ' + $_.Exception.Message) 'error'
  Write-TrayLog ('stack: ' + $_.Exception.StackTrace) 'error'
  [void][System.Windows.MessageBox]::Show(('The tray stopped:' + [Environment]::NewLine + $_.Exception.Message + [Environment]::NewLine + [Environment]::NewLine + 'See ' + $script:LogFile), 'DeepSeek Harness', 'OK', 'Error')
  exit 1
}
