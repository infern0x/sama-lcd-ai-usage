<#
  sama-lcd-ai-usage
  Shows Claude Code and OpenAI Codex usage limits + reset countdowns, with animated logos,
  on the LCD of a SAMA AIO liquid cooler (Turing/TURZX-based 720x720 USB-serial screen).

  Data sources (local logins, nothing else is sent anywhere):
    Claude : ~/.claude/.credentials.json  -> https://api.anthropic.com/api/oauth/usage
    Codex  : ~/.codex/auth.json           -> https://chatgpt.com/backend-api/wham/usage
  Screen protocol: see PROTOCOL.md. Delta encoder + logo drawing live in CoolerLcd.cs.

  The SAMA app must NOT be running at the same time (it locks the serial port).

  Examples:
    powershell -ExecutionPolicy Bypass -File sama-lcd-ai-usage.ps1                 # run (Ctrl+C to stop)
    powershell -ExecutionPolicy Bypass -File sama-lcd-ai-usage.ps1 -Rotate 180     # cooler mounted upside down
    powershell -ExecutionPolicy Bypass -File sama-lcd-ai-usage.ps1 -Demo -SavePng preview.png
#>
param(
  [string]$Port = '',                 # serial port; auto-detected by USB VID/PID when empty
  [int]$Fps = 15,                     # animation frame rate
  [int]$FetchSeconds = 300,           # how often usage is fetched from the APIs
  [ValidateSet(0, 90, 180, 270)][int]$Rotate = 0,   # match how the cooler is mounted
  [switch]$Once,                      # send one frame and exit
  [switch]$Demo,                      # use sample data; with -SavePng no screen is needed
  [string]$SavePng = ''               # save the rendered frame to this PNG file
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

$Size       = 720
$UserAgent  = 'sama-lcd-ai-usage/1.0'
$AppDir     = Split-Path -Parent $MyInvocation.MyCommand.Path
$LogFile    = Join-Path $AppDir 'sama-lcd-ai-usage.log'
$ClaudeCred = Join-Path $env:USERPROFILE '.claude\.credentials.json'
$CodexAuth  = Join-Path $env:USERPROFILE '.codex\auth.json'
$UsbId      = 'VID_1D6B&PID_A040'

function Log([string]$msg) {
  $line = '{0:yyyy-MM-dd HH:mm:ss} {1}' -f (Get-Date), $msg
  try {
    if ((Test-Path $LogFile) -and (Get-Item $LogFile).Length -gt 1MB) { Move-Item $LogFile "$LogFile.old" -Force }
    Add-Content -Path $LogFile -Value $line -Encoding UTF8
  } catch {}
  if ($Once -or $Demo) { Write-Host $line }
}

# ---------------------------------------------------------------- usage data
function Update-ClaudeToken($cred) {
  # Refresh the Claude Code OAuth token (same flow the claude CLI uses) and write it back atomically.
  $o = $cred.claudeAiOauth
  $body = @{ grant_type = 'refresh_token'; refresh_token = $o.refreshToken; client_id = '9d1c250a-e61b-44d9-88ed-5944d1962f5e' } | ConvertTo-Json
  $resp = $null
  foreach ($u in 'https://platform.claude.com/v1/oauth/token', 'https://console.anthropic.com/v1/oauth/token') {
    try { $resp = Invoke-RestMethod -Method Post -Uri $u -ContentType 'application/json' -Body $body -UserAgent $UserAgent -TimeoutSec 20; break }
    catch { Log "claude refresh via $u failed: $($_.Exception.Message)" }
  }
  if (-not $resp -or -not $resp.access_token) { return $false }
  $fresh = Get-Content $ClaudeCred -Raw | ConvertFrom-Json     # re-read in case the CLI touched it meanwhile
  $fresh.claudeAiOauth.accessToken = $resp.access_token
  if ($resp.refresh_token) { $fresh.claudeAiOauth.refreshToken = $resp.refresh_token }
  $fresh.claudeAiOauth.expiresAt = [DateTimeOffset]::UtcNow.AddSeconds([int]$resp.expires_in).ToUnixTimeMilliseconds()
  $tmp = "$ClaudeCred.tmp"
  [IO.File]::WriteAllText($tmp, ($fresh | ConvertTo-Json -Depth 10 -Compress), (New-Object Text.UTF8Encoding($false)))
  Move-Item $tmp $ClaudeCred -Force
  Log 'claude token refreshed'
  return $true
}

function Get-ClaudeUsage {
  if (-not (Test-Path $ClaudeCred)) { return @{ Error = 'not logged in (run: claude auth login)' } }
  $cred = Get-Content $ClaudeCred -Raw | ConvertFrom-Json
  $exp = [DateTimeOffset]::FromUnixTimeMilliseconds([int64]$cred.claudeAiOauth.expiresAt)
  if ($exp -lt [DateTimeOffset]::UtcNow.AddMinutes(5)) {
    if (Update-ClaudeToken $cred) { $cred = Get-Content $ClaudeCred -Raw | ConvertFrom-Json }
  }
  $h = @{ Authorization = "Bearer $($cred.claudeAiOauth.accessToken)"; 'anthropic-beta' = 'oauth-2025-04-20' }
  try { $r = Invoke-RestMethod -Uri 'https://api.anthropic.com/api/oauth/usage' -Headers $h -UserAgent $UserAgent -TimeoutSec 20 }
  catch { return @{ Error = "API error: $($_.Exception.Message)" } }
  @{
    Plan = $cred.claudeAiOauth.subscriptionType
    S = [double]$r.five_hour.utilization;  SReset = if ($r.five_hour.resets_at) { [DateTimeOffset]::Parse($r.five_hour.resets_at).LocalDateTime } else { $null }
    W = [double]$r.seven_day.utilization;  WReset = if ($r.seven_day.resets_at) { [DateTimeOffset]::Parse($r.seven_day.resets_at).LocalDateTime } else { $null }
  }
}

function Get-CodexUsage {
  if (-not (Test-Path $CodexAuth)) { return @{ Error = 'not logged in (sign in to Codex)' } }
  $a = Get-Content $CodexAuth -Raw | ConvertFrom-Json
  $h = @{ Authorization = "Bearer $($a.tokens.access_token)" }
  if ($a.tokens.account_id) { $h['ChatGPT-Account-Id'] = $a.tokens.account_id }
  try { $r = Invoke-RestMethod -Uri 'https://chatgpt.com/backend-api/wham/usage' -Headers $h -UserAgent $UserAgent -TimeoutSec 20 }
  catch { return @{ Error = "API error: $($_.Exception.Message)" } }
  $p = $r.rate_limit.primary_window; $s = $r.rate_limit.secondary_window
  @{
    Plan = $r.plan_type
    S = [double]$p.used_percent; SReset = if ($p.reset_at) { [DateTimeOffset]::FromUnixTimeSeconds([int64]$p.reset_at).LocalDateTime } else { $null }
    W = [double]$s.used_percent; WReset = if ($s.reset_at) { [DateTimeOffset]::FromUnixTimeSeconds([int64]$s.reset_at).LocalDateTime } else { $null }
  }
}

function Get-DemoUsage([string]$who) {
  $now = Get-Date
  if ($who -eq 'claude') { @{ Plan = 'pro'; S = 26; SReset = $now.AddHours(4).AddMinutes(10); W = 38; WReset = $now.AddHours(11).AddMinutes(30) } }
  else { @{ Plan = 'plus'; S = 91; SReset = $now.AddHours(1).AddMinutes(41); W = 72; WReset = $now.AddDays(2).AddHours(12) } }
}

# ---------------------------------------------------------------- rendering (static part, once a minute)
function C([string]$hex) { [System.Drawing.ColorTranslator]::FromHtml($hex) }
$ColBg = C '#0B0F17'; $ColCard = C '#151B26'; $ColTrack = C '#273042'
$ColText = C '#F2F4F8'; $ColDim = C '#8A94A7'
$ColOk = C '#3DDC97'; $ColWarn = C '#FFB547'; $ColBad = C '#FF5C5C'

function Format-Left($when) {
  if (-not $when) { return '-' }
  $ts = $when - (Get-Date)
  if ($ts.TotalSeconds -le 0) { return 'resetting' }
  if ($ts.TotalDays -ge 1) { return ('{0}d {1}h' -f [int][Math]::Floor($ts.TotalDays), $ts.Hours) }
  if ($ts.TotalHours -ge 1) { return ('{0}h {1:00}m' -f [int][Math]::Floor($ts.TotalHours), $ts.Minutes) }
  return ('{0}m' -f [int][Math]::Ceiling($ts.TotalMinutes))
}
function LevelColor([double]$p) { if ($p -ge 85) { $ColBad } elseif ($p -ge 60) { $ColWarn } else { $ColOk } }

function Draw-RoundRect($g, $brush, [float]$x, [float]$y, [float]$w, [float]$h, [float]$r) {
  $p = New-Object System.Drawing.Drawing2D.GraphicsPath
  $p.AddArc($x, $y, 2*$r, 2*$r, 180, 90); $p.AddArc($x+$w-2*$r, $y, 2*$r, 2*$r, 270, 90)
  $p.AddArc($x+$w-2*$r, $y+$h-2*$r, 2*$r, 2*$r, 0, 90); $p.AddArc($x, $y+$h-2*$r, 2*$r, 2*$r, 90, 90); $p.CloseFigure()
  $g.FillPath($brush, $p); $p.Dispose()
}

function Draw-Card($g, [float]$top, [string]$name, $u) {
  $x = 36; $w = $Size - 72; $h = 292
  Draw-RoundRect $g (New-Object System.Drawing.SolidBrush($ColCard)) $x $top $w $h 26
  # the logo at (82, top+44) is drawn per frame (animated) by CoolerLcd.Animator
  $fName = New-Object System.Drawing.Font('Segoe UI Semibold', 30)
  $fPlan = New-Object System.Drawing.Font('Segoe UI', 20)
  $g.DrawString($name, $fName, (New-Object System.Drawing.SolidBrush($ColText)), $x + 80, $top + 16)
  if ($u.Plan) { $sz = $g.MeasureString($name, $fName); $g.DrawString(([string]$u.Plan).ToUpper(), $fPlan, (New-Object System.Drawing.SolidBrush($ColDim)), $x + 88 + $sz.Width, $top + 27) }
  if ($u.Error) {
    $g.DrawString($u.Error, (New-Object System.Drawing.Font('Segoe UI', 22)), (New-Object System.Drawing.SolidBrush($ColBad)), (New-Object System.Drawing.RectangleF(($x + 28), ($top + 90), ($w - 56), 180)))
    return
  }
  $rows = @(@{ L = '5-hour'; P = $u.S; R = $u.SReset }, @{ L = 'Weekly'; P = $u.W; R = $u.WReset })
  $fLbl = New-Object System.Drawing.Font('Segoe UI', 22); $fPct = New-Object System.Drawing.Font('Segoe UI Semibold', 40); $fRst = New-Object System.Drawing.Font('Segoe UI', 21)
  $ry = $top + 84
  foreach ($row in $rows) {
    $pct = [Math]::Max(0, [Math]::Min(100, [double]$row.P))
    $col = LevelColor $pct
    $g.DrawString($row.L, $fLbl, (New-Object System.Drawing.SolidBrush($ColDim)), $x + 28, $ry + 12)
    $g.DrawString(('{0:0}%' -f $pct), $fPct, (New-Object System.Drawing.SolidBrush($col)), $x + 150, $ry)
    $rst = 'resets in ' + (Format-Left $row.R)
    $rsz = $g.MeasureString($rst, $fRst)
    $g.DrawString($rst, $fRst, (New-Object System.Drawing.SolidBrush($ColText)), $x + $w - 28 - $rsz.Width, $ry + 14)
    $by = $ry + 68; $bw = $w - 56
    Draw-RoundRect $g (New-Object System.Drawing.SolidBrush($ColTrack)) ($x + 28) $by $bw 14 7
    if ($pct -gt 0) { Draw-RoundRect $g (New-Object System.Drawing.SolidBrush($col)) ($x + 28) $by ([Math]::Max(14, $bw * $pct / 100)) 14 7 }
    $ry += 100
  }
}

function Render-Base($claude, $codex, $fetchedAt) {
  $bmp = New-Object System.Drawing.Bitmap($Size, $Size, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.SmoothingMode = 'AntiAlias'; $g.TextRenderingHint = 'AntiAliasGridFit'
  $g.Clear($ColBg)
  $fClock = New-Object System.Drawing.Font('Segoe UI Semibold', 34)
  $fSmall = New-Object System.Drawing.Font('Segoe UI', 18)
  $g.DrawString((Get-Date).ToString('HH:mm'), $fClock, (New-Object System.Drawing.SolidBrush($ColText)), 40, 26)
  $upd = if ($fetchedAt) { 'updated ' + $fetchedAt.ToString('HH:mm') } else { 'no data yet' }
  $us = $g.MeasureString($upd, $fSmall)
  $g.DrawString($upd, $fSmall, (New-Object System.Drawing.SolidBrush($ColDim)), $Size - 40 - $us.Width, 44)
  Draw-Card $g 100 'Claude' $claude
  Draw-Card $g 410 'Codex'  $codex
  $g.Dispose()
  if ($Rotate) { $bmp.RotateFlip(@{ 90 = 'Rotate90FlipNone'; 180 = 'Rotate180FlipNone'; 270 = 'Rotate270FlipNone' }[$Rotate]) }
  return $bmp
}

# ---------------------------------------------------------------- device I/O (see PROTOCOL.md)
function Find-Port {
  if ($Port) { return $Port }
  $dev = Get-CimInstance Win32_SerialPort -ErrorAction SilentlyContinue | Where-Object { $_.PNPDeviceID -match $UsbId } | Select-Object -First 1
  if ($dev) { return $dev.DeviceID }
  return $null
}
function New-Header([int]$cmd, [int]$len) {
  $h = New-Object byte[] 250
  $h[0] = $cmd; $h[1] = 0xEF; $h[2] = 0x69
  $h[3] = ($len -shr 24) -band 0xFF; $h[4] = ($len -shr 16) -band 0xFF; $h[5] = ($len -shr 8) -band 0xFF; $h[6] = $len -band 0xFF
  return ,$h
}
function Read-Reply($sp, [int]$ms) {
  $end = (Get-Date).AddMilliseconds($ms); $acc = New-Object System.Collections.Generic.List[byte]
  while ((Get-Date) -lt $end) {
    $n = $sp.BytesToRead
    if ($n -gt 0) { $r = New-Object byte[] $n; [void]$sp.Read($r, 0, $n); $acc.AddRange($r); if ($acc.Contains(0)) { break } } else { Start-Sleep -Milliseconds 30 }
  }
  ([Text.Encoding]::ASCII.GetString($acc.ToArray()) -replace "`0.*$", '')
}
function Write-Packets($sp, [byte[]]$data, [int]$len) {
  $chunk = New-Object byte[] 250                     # 250-byte packets, 249 data bytes each
  for ($i = 0; $i -lt $len; $i += 249) {
    [Array]::Clear($chunk, 0, 250)
    [Array]::Copy($data, $i, $chunk, 0, [Math]::Min(249, $len - $i))
    $sp.Write($chunk, 0, 250)
  }
}
function Open-Screen {
  $p = Find-Port
  if (-not $p) { throw "cooler screen not found (USB $UsbId)" }
  $sp = New-Object System.IO.Ports.SerialPort($p, 115200, 'None', 8, 'One')
  $sp.DtrEnable = $true; $sp.RtsEnable = $true; $sp.WriteTimeout = 10000; $sp.ReadTimeout = 500
  try { $sp.Open() } catch { throw "cannot open $p (is the SAMA app running?): $($_.Exception.Message)" }
  $hs = New-Header 1 1; $hs[10] = 197; $hs[11] = 211      # cmd 1 = version handshake
  $sp.Write($hs, 0, 250)
  $ver = Read-Reply $sp 1500
  if ($ver -notmatch 'rom') { $sp.Close(); throw "unexpected handshake reply: '$ver'" }
  Log "connected on $p ($ver)"
  return $sp
}
function Send-Full($sp, [byte[]]$raw) {
  $sp.DiscardInBuffer()                               # cmd 200 = full opaque frame (raw BGRA)
  $sp.Write((New-Header 200 $raw.Length), 0, 250)
  Write-Packets $sp $raw $raw.Length
  $ok = Read-Reply $sp 4000
  if ($ok -notmatch 'full_png') { throw "full frame not accepted: '$ok'" }
}
function Send-Delta($sp, [byte[]]$enc, [int]$len, [int]$id) {
  $data = New-Object byte[] ($len + 2)                # cmd 204 = delta frame, ids restart at 0 after cmd 200
  [Array]::Copy($enc, 0, $data, 0, $len); $data[$len] = 0xEF; $data[$len + 1] = 0x69
  $h = New-Header 204 $data.Length
  $h[10] = ($id -shr 24) -band 0xFF; $h[11] = ($id -shr 16) -band 0xFF; $h[12] = ($id -shr 8) -band 0xFF; $h[13] = $id -band 0xFF
  $sp.Write($h, 0, 250)
  Write-Packets $sp $data $data.Length
}
function Get-Status($sp) {
  $sp.DiscardInBuffer()
  $sp.Write((New-Header 207 1), 0, 250)               # cmd 207 -> "needReSend:x|renderCnt:n"
  Read-Reply $sp 600
}

# ---------------------------------------------------------------- main loop
trap { Log "fatal: $($_.Exception.Message) @ $($_.InvocationInfo.PositionMessage)"; break }
if (-not $Once -and -not $Demo) {
  $script:mutex = New-Object System.Threading.Mutex($false, 'Local\SamaLcdAiUsage')
  if (-not $script:mutex.WaitOne(0)) { Log "another instance is already running, exiting (pid $PID)"; return }
}
Add-Type -Path (Join-Path $AppDir 'CoolerLcd.cs') -ReferencedAssemblies System.Drawing
$anim = New-Object CoolerLcd.Animator
$anim.Rotate = $Rotate

if ($Demo -and $SavePng) {                            # offline preview, no screen needed
  $base = Render-Base (Get-DemoUsage 'claude') (Get-DemoUsage 'codex') (Get-Date)
  [void]$anim.Compose($base, 0.3)
  $anim.LastFrame.Save($SavePng, [System.Drawing.Imaging.ImageFormat]::Png)
  Log "preview saved to $SavePng"
  return
}

Log "start (pid $PID, fps $Fps, rotate $Rotate)"
$claude = @{ Error = 'loading...' }; $codex = @{ Error = 'loading...' }; $fetchedAt = $null; $lastFetch = [datetime]::MinValue
$sp = $null; $base = $null; $baseMinute = ''; $prev = $null; $id = 0
$clock = [Diagnostics.Stopwatch]::StartNew(); $lastStatus = 0
$frameMs = [int](1000 / [Math]::Max(1, $Fps))

while ($true) {
  try {
    if (((Get-Date) - $lastFetch).TotalSeconds -ge $FetchSeconds) {
      if ($Demo) { $claude = Get-DemoUsage 'claude'; $codex = Get-DemoUsage 'codex' }
      else {
        try { $claude = Get-ClaudeUsage } catch { $claude = @{ Error = $_.Exception.Message } }
        try { $codex = Get-CodexUsage } catch { $codex = @{ Error = $_.Exception.Message } }
      }
      $fetchedAt = Get-Date; $lastFetch = Get-Date; $baseMinute = ''
      Log ("usage claude={0}/{1} codex={2}/{3}" -f $claude.S, $claude.W, $codex.S, $codex.W)
      if ($claude.Error) { Log "claude: $($claude.Error)" }; if ($codex.Error) { Log "codex: $($codex.Error)" }
    }
    $minute = (Get-Date).ToString('yyyyMMddHHmm')     # static part re-rendered once a minute
    if ($minute -ne $baseMinute) {
      if ($base) { $base.Dispose() }
      $base = Render-Base $claude $codex $fetchedAt
      $baseMinute = $minute
    }
    $cur = $anim.Compose($base, $clock.Elapsed.TotalSeconds)
    if ($SavePng) { $anim.LastFrame.Save($SavePng, [System.Drawing.Imaging.ImageFormat]::Png); $SavePng = '' }
    if (-not $sp) { $sp = Open-Screen; $prev = $null }
    if (-not $prev) {
      Send-Full $sp $cur; $prev = $cur; $id = 0
    } else {
      $len = 0
      $enc = [CoolerLcd.Codec]::Delta($prev, $cur, [ref]$len)
      if ($null -eq $enc) { Send-Full $sp $cur; $id = 0 }
      elseif ($len -gt 0) { Send-Delta $sp $enc $len $id; $id++ }
      $prev = $cur
    }
    if ($clock.ElapsedMilliseconds - $lastStatus -gt 3000) {   # keep the screen in sync
      $lastStatus = $clock.ElapsedMilliseconds
      $st = Get-Status $sp
      if ($st -match 'needReSend:1' -or -not $st) { Log "resync (status '$st')"; $prev = $null }
    }
    if ($Once) { break }
    Start-Sleep -Milliseconds ($frameMs - ([int]($clock.Elapsed.TotalSeconds * 1000) % $frameMs))
  } catch {
    Log "error: $($_.Exception.Message)"
    if ($sp) { try { $sp.Close(); $sp.Dispose() } catch {} }
    $sp = $null; $prev = $null
    if ($Once) { break }
    Start-Sleep -Seconds 10
  }
}
if ($sp) { $sp.Close() }
