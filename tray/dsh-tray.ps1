param(
  [string]$Distro       = 'Ubuntu-24.04',
  [string]$User         = '',
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

# No machine-specific constants below: the install root follows the Windows
# per-user profile, and the distro account defaults to the Windows account name
# lowercased (override with -User when the two differ).
$Root = Join-Path $env:LOCALAPPDATA 'dsh'
if (-not $User) { $User = $env:USERNAME.ToLower() }
$IcoPath   = Join-Path $Root 'dsh-icon.ico'
$LabelFile = Join-Path $Root 'dsh-labels.json'
$LogUnc    = "\\wsl.localhost\$Distro\home\$User\.local\state\dsh-web.log"
$RunArgs   = "-d $Distro -u $User -- bash -l /home/$User/bin/dsh-run.sh --no-browser"
$StopArgs  = "-d $Distro -u $User -- bash -l /home/$User/bin/dsh-stop.sh"
$LogArgs   = "-d $Distro -u $User -- bash -l /home/$User/bin/dsh-log.sh"
$L         = Get-Content -Raw -Encoding UTF8 $LabelFile | ConvertFrom-Json

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

$script:Proc      = $null
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
# One start/stop at a time, driven by a dispatcher timer instead of a blocking
# wait on the click handler: the UI thread must stay free to repaint the panel.
$script:OpKind     = ''
$script:OpProc     = $null
$script:OpDeadline = [DateTime]::MinValue
$script:OpNext     = ''
$script:OpOpen     = $false
$script:OpMiss     = 0
$script:OpTimer    = $null
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
  param([int]$TimeoutMs = 500)
  $c = $null
  try {
    $c = New-Object System.Net.Sockets.TcpClient
    $r = $c.BeginConnect('127.0.0.1', 3080, $null, $null)
    $ok = $r.AsyncWaitHandle.WaitOne($TimeoutMs, $false)
    if ($ok) { $c.EndConnect($r) }
    return $ok
  } catch { return $false }
  finally { if ($c) { try { $c.Close() } catch { } } }
}

# HTTP status of 127.0.0.1:Port. 401/303/200/302 => dsh is the listener.
# -2 => nothing answered on HTTP (treated as foreign or closed).
function Test-DshHttp {
  param([int]$Port = 3080, [int]$TimeoutMs = 1500)
  $req = $null
  try {
    $req = [System.Net.HttpWebRequest]::Create("http://127.0.0.1:$Port/")
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
  param([int]$Port = 3080, [int]$TimeoutMs = 1500)
  $ok = $false
  $c = $null
  try {
    $c = New-Object System.Net.Sockets.TcpClient
    $r = $c.BeginConnect('127.0.0.1', $Port, $null, $null)
    $ok = $r.AsyncWaitHandle.WaitOne(500, $false)
    if ($ok) { $c.EndConnect($r) }
  } catch {
    $ok = $false
  } finally {
    if ($c) { try { $c.Close() } catch { } }
  }
  if (-not $ok) { return 'free' }
  $code = Test-DshHttp -Port $Port -TimeoutMs $TimeoutMs
  # dsh answers 401 on an unauthenticated GET / (measured 2026-11-24, 0.2.2-rc.5).
  # 303 only appears with a valid token. A generic 200 is NOT proof of dsh.
  if ($code -eq 401 -or $code -eq 303) { return 'dsh' }
  return 'foreign'
}

# Single read of the log over the 9p share. Returns $null when the share is
# unreachable or the token line is not there yet.
function Read-TokenFromUnc {
  try {
    if (-not (Test-Path $LogUnc)) { return $null }
    $lines = Get-Content $LogUnc -ErrorAction Stop
    for ($i = $lines.Count - 1; $i -ge 0; $i--) {
      $m = [regex]::Match($lines[$i], 'token=([A-Za-z0-9_\-]+)')
      if ($m.Success) { return $m.Groups[1].Value }
    }
  } catch { }
  return $null
}

# Fallback when the share itself is missing: read the same file inside the distro.
# Output is drained asynchronously so a large log cannot block the UI thread.
function Read-TokenFromWsl {
  $p = $null
  try {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'C:\Windows\System32\wsl.exe'
    $psi.Arguments = "-d $Distro -u $User -- /bin/cat /home/$User/.local/state/dsh-web.log"
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
    $text = ''
    if ($out.IsCompleted) { $text = $out.Result }
    $lines = $text -split "`r?`n"
    for ($i = $lines.Count - 1; $i -ge 0; $i--) {
      $m = [regex]::Match($lines[$i], 'token=([A-Za-z0-9_\-]+)')
      if ($m.Success) { return $m.Groups[1].Value }
    }
  } catch { }
  finally { if ($p) { try { $p.Dispose() } catch { } } }
  return $null
}

function Get-Token {
  param([switch]$Robust)
  $t = Read-TokenFromUnc
  if ($t) { return $t }
  if (-not $Robust) { return $null }
  # A 9p hiccup looks exactly like a missing token; retry once before falling back.
  Start-Sleep -Milliseconds 250
  $t = Read-TokenFromUnc
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
    if ($Reason -eq 'stop')  {
      $hint = $L.hintStopFail
      if ($L.statusStopFailed) { $label = $L.statusStopFailed }
    }
  }

  $dot.Background = Brush $color
  [void]$st.Children.Add($dot)
  $pad = New-Object System.Windows.Controls.Border; $pad.Width = 6
  [void]$st.Children.Add($pad)
  [void]$st.Children.Add((New-Text -Text ($label + '   ' + $L.dotSep + '   127.0.0.1:3080') -Size 10.5 -Color $C_Sub))
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
  [void]$outer.Children.Add((New-Row -Glyph 'E71A' -Label $L.menuStop    -OnClick { Stop-Server }))
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

# --- non-blocking start/stop ------------------------------------------------
# Everything below runs on the dispatcher thread, so it must only spawn work and
# return. Polling happens in Update-Op on the op timer (400 ms).

function New-WslProcess([string]$Arguments) {
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = 'C:\Windows\System32\wsl.exe'
  $psi.Arguments = $Arguments
  $psi.UseShellExecute = $false
  $psi.CreateNoWindow = $true
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  return [System.Diagnostics.Process]::Start($psi)
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
    $script:Proc = $p
    $script:State = 'running'
    $script:Reason = ''
    $script:PortKind = 'dsh'
  } else {
    if ($p) { try { if (-not $p.HasExited) { $p.Kill() } } catch { } }
    $script:Proc = $null
    $script:State = 'failed'
    $r = $Why
    if (-not $r) { if (Test-Up) { $r = 'token' } else { $r = 'start'; $script:PortKind = 'free' } }
    $script:Reason = $r
  }
  $script:OpProc = $null
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
    $script:Proc = $null
    $script:State = 'stopped'
    $script:Reason = ''
    $script:PortKind = 'free'
  } else {
    $script:State = 'failed'
    $script:Reason = 'stop'
    $script:PortKind = 'dsh'
  }
  Update-PanelContent
  if ($Ok -and $next -eq 'start') { [void](Begin-Start) }
}

function Update-Op {
  if (-not $script:OpKind) { Stop-OpTimer; return }
  $now = [DateTime]::Now
  if ($script:OpKind -eq 'start') {
    if (Test-Up -TimeoutMs 250) {
      $script:OpMiss = 0
      # Readiness is the HTTP signature of dsh, not the token file: the 9p share is
      # the least reliable link in the chain and must stay off the polling path.
      $code = Test-DshHttp -TimeoutMs 700
      if ($code -eq 401 -or $code -eq 303) { Complete-Start $true; return }
      if ($code -ne -2) { Complete-Start $false 'port'; return }
    } else {
      $script:OpMiss++
    }
    $exited = $false
    if ($script:OpProc) { try { $exited = $script:OpProc.HasExited } catch { $exited = $true } }
    if ($exited -and $script:OpMiss -ge 2) { Complete-Start $false; return }
    if ($now -gt $script:OpDeadline) { Complete-Start $false; return }
    return
  }
  if ($script:OpKind -eq 'stop') {
    if (-not (Test-Up)) { Complete-Stop $true; return }
    if ($now -gt $script:OpDeadline) { Complete-Stop $false }
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
    Update-PanelContent
    return $false
  }
  $script:State = 'starting'
  $script:Reason = ''
  $script:PortKind = 'free'
  $script:OpKind = 'start'
  $script:OpMiss = 0
  $script:OpDeadline = [DateTime]::Now.AddSeconds(90)
  try { $script:OpProc = New-WslProcess $RunArgs } catch { $script:OpProc = $null }
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
# port bound must not be reported as success: the next start would silently adopt
# the old instance.
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
  if ($script:Proc) { try { if (-not $script:Proc.HasExited) { $script:Proc.Kill() } } catch { } }
  $script:Proc = $null
  $script:OpKind = 'stop'
  $script:OpDeadline = [DateTime]::Now.AddSeconds(12)
  try { $script:OpProc = New-WslProcess $StopArgs } catch { $script:OpProc = $null }
  if (-not (Test-Up)) { Complete-Stop $true; return }
  Start-OpTimer
  Update-PanelContent
}

function Stop-Server { Begin-Stop }

function Restart-Server {
  if ($script:OpKind -eq 'stop') { return }
  $script:OpNext = 'start'
  Begin-Stop
}

function Open-Browser {
  $t = Get-Token -Robust
  if (-not $t) {
    $script:State = 'failed'
    $script:Reason = 'token'
    Show-Panel
    Start-HideTimer 8000
    return
  }
  Start-Process ("http://127.0.0.1:3080/?token=" + $t)
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
    $script:State = 'failed'
    $script:Reason = 'token'
    Show-Panel
    Start-HideTimer 8000
    return
  }
  # Reuse the remembered tab only when it was opened with this very token. A tray
  # restart keeps the hash, a dsh restart changes the token and therefore opens a
  # fresh tab instead of focusing a page that will answer 401.
  $h = Get-TokenHash $t
  $reuse = ($h -ne '') -and ((Read-LastTokenHash) -eq $h)
  if ($reuse) {
    $w = Find-DshWindow
    if ($w -ne [IntPtr]::Zero) {
      if (Focus-Window $w) { return }
    }
  }
  Start-Process ("http://127.0.0.1:3080/?token=" + $t)
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

# Quitting must not wait on wsl.exe: fire the stop script detached and let the
# process die on its own. The distro keeps running the script after we exit.
function Exit-App {
  if ($script:OpProc) { try { if (-not $script:OpProc.HasExited) { $script:OpProc.Kill() } } catch { } }
  if ($script:Proc) { try { if (-not $script:Proc.HasExited) { $script:Proc.Kill() } } catch { } }
  try { [void](New-WslProcess $StopArgs) } catch { }
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
$timer.Interval = [TimeSpan]::FromSeconds(3)
$timer.add_Tick({
  if ($script:OpKind) { return }
  if ($script:Prewarming) { return }
  $before = Get-PanelKey
  if (Test-Up) {
    # Probe identity only when it is not already known: a foreign listener makes
    # the HTTP check burn its full timeout, so steady state must not re-probe.
    if ($script:PortKind -ne 'dsh') {
      if ((Get-PortState) -eq 'dsh') { $script:PortKind = 'dsh' } else { $script:PortKind = 'foreign' }
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

[void]$app.Run()
