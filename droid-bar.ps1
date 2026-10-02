#Requires -Version 5.1
<#
  Droid Bar - Windows tray icon showing your Factory Droid usage limits.

  Usage:
    DroidBar.exe                      (or: powershell -NoProfile -ExecutionPolicy Bypass -File droid-bar.ps1)
    ... -Mock samples\mock.json       use a local JSON file instead of the API
    ... -Preview popup.png            render the popup to a PNG and exit
    ... -Dump                         print the raw API response and exit
#>
param(
    [string]$Mock,
    [string]$Preview,
    [switch]$Dump
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class DBNative {
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] public static extern bool DestroyIcon(IntPtr h);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
    [DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
    [DllImport("dwmapi.dll")] public static extern int DwmSetWindowAttribute(IntPtr h, int attr, ref int val, int size);
}
'@

# ---------------------------------------------------------------- paths/config

$AppName    = 'DroidBar'
$ScriptPath = $MyInvocation.MyCommand.Path
$DataDir    = Join-Path $env:APPDATA 'droid-bar'
$CfgPath    = Join-Path $DataDir 'config.json'
$StatePath  = Join-Path $DataDir 'state.json'
$LogPath    = Join-Path $DataDir 'droid-bar.log'
$UsageUrl   = 'https://app.factory.ai/settings/usage'
$KeysUrl    = 'https://app.factory.ai/settings/api-keys'
$RunKey     = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
if (-not (Test-Path $DataDir)) { New-Item -ItemType Directory -Path $DataDir | Out-Null }

function Write-Log([string]$msg) {
    try {
        if ((Test-Path $LogPath) -and (Get-Item $LogPath).Length -gt 512KB) { Remove-Item $LogPath }
        Add-Content -Path $LogPath -Value ("{0:yyyy-MM-dd HH:mm:ss}  {1}" -f (Get-Date), $msg) -Encoding UTF8
    } catch { }
}

function ConvertTo-Hashtable($obj) {
    $h = @{}
    if ($null -ne $obj) { foreach ($p in $obj.PSObject.Properties) { $h[$p.Name] = $p.Value } }
    return $h
}

function Get-Config {
    $cfg = @{
        apiKeyProtected = ''
        apiBase         = 'https://api.factory.ai'
        pollMinutes     = 5
        thresholds      = @(75, 90, 100)
        notifyPools     = @('standard', 'core')
        trayPool        = 'standard'
    }
    if (Test-Path $CfgPath) {
        try {
            $saved = ConvertTo-Hashtable (Get-Content $CfgPath -Raw -Encoding UTF8 | ConvertFrom-Json)
            foreach ($k in $saved.Keys) { $cfg[$k] = $saved[$k] }
        } catch { Write-Log "invalid config: $_" }
    }
    return $cfg
}

function Save-Config {
    $script:Cfg | ConvertTo-Json -Depth 5 | Set-Content -Path $CfgPath -Encoding UTF8
}

# The key is protected with DPAPI (only your Windows user can decrypt it).
function Get-ApiKey {
    if ($env:FACTORY_API_KEY) { return $env:FACTORY_API_KEY }
    if (-not $script:Cfg.apiKeyProtected) { return $null }
    try {
        $sec = ConvertTo-SecureString $script:Cfg.apiKeyProtected
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR([Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec))
    } catch { return $null }
}

function Set-ApiKey([string]$key) {
    $script:Cfg.apiKeyProtected = ConvertTo-SecureString $key -AsPlainText -Force | ConvertFrom-SecureString
    Save-Config
}

function Get-AlertState {
    if (Test-Path $StatePath) {
        try { return ConvertTo-Hashtable (Get-Content $StatePath -Raw | ConvertFrom-Json) } catch { }
    }
    return @{}
}

# ---------------------------------------------------------------- data helpers

$Pools   = [ordered]@{ standard = 'Standard'; core = 'Droid Core' }
$Windows = [ordered]@{ fiveHour = '5-hour usage'; weekly = 'Weekly usage'; monthly = 'Monthly usage' }
$Short   = @{ fiveHour = '5h'; weekly = 'week'; monthly = 'month' }

function ConvertTo-LocalTime($v) {
    if ($null -eq $v -or "$v" -eq '') { return $null }
    if ($v -is [datetime]) { return $v.ToLocalTime() }
    if ($v -is [int] -or $v -is [long] -or $v -is [double] -or $v -is [decimal]) {
        $n = [double]$v
        if ($n -gt 1e12) { return [DateTimeOffset]::FromUnixTimeMilliseconds([long]$n).LocalDateTime }
        return [DateTimeOffset]::FromUnixTimeSeconds([long]$n).LocalDateTime
    }
    try { return [DateTimeOffset]::Parse([string]$v, [Globalization.CultureInfo]::InvariantCulture).LocalDateTime } catch { return $null }
}

function Get-WinInfo([string]$pool, [string]$key) {
    $info = @{ Pct = $null; End = $null; Active = $false }
    if (-not $script:Data -or -not $script:Data.limits) { return $info }
    $p = $script:Data.limits.$pool
    if (-not $p) { return $info }
    $w = $p.$key
    if (-not $w) { return $info }
    $pct = 0.0
    if ($null -ne $w.usedPercent) { $pct = [double]$w.usedPercent }
    $end = ConvertTo-LocalTime $w.windowEnd
    $info.End = $end
    if ($end) {
        $info.Active = $end -ge (Get-Date)
        if (-not $info.Active) { $pct = 0 }   # window already rolled over: usage is back to zero
    }
    $info.Pct = [math]::Max(0, $pct)
    return $info
}

function Get-PoolMax([string]$pool) {
    $max = $null
    foreach ($k in $Windows.Keys) {
        $i = Get-WinInfo $pool $k
        if ($null -ne $i.Pct -and ($null -eq $max -or $i.Pct -gt $max)) { $max = $i.Pct }
    }
    return $max
}

function Format-Pct($pct) { if ($null -eq $pct) { return '—' }; return ('{0:0}%' -f [math]::Floor($pct)) }

function Format-Remaining($end) {
    if (-not $end) { return '—' }
    $ts = $end - (Get-Date)
    if ($ts.TotalSeconds -le 0) { return 'now' }
    if ($ts.TotalHours -ge 48) { return ('{0} days' -f [math]::Floor($ts.TotalDays)) }
    if ($ts.TotalHours -ge 24) { return ('1 day {0}h' -f $ts.Hours) }
    $h = [math]::Floor($ts.TotalHours)
    if ($h -gt 0) { return ('{0}h {1}min' -f $h, $ts.Minutes) }
    if ($ts.Minutes -lt 1) { return '<1min' }
    return ('{0}min' -f $ts.Minutes)
}

# ---------------------------------------------------------------- fetching

$script:Cfg       = Get-Config
$script:Data      = $null
$script:LastError = $null
$script:Updated   = $null
$script:Fetch     = $null
$script:Alerts    = Get-AlertState

function Get-LimitsUrl { return ($script:Cfg.apiBase.TrimEnd('/') + '/api/billing/limits') }

$FetchScript = {
    param($url, $key)
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    try {
        $r = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 20 -Headers @{ Authorization = "Bearer $key"; Accept = 'application/json' }
        $body = [Text.Encoding]::UTF8.GetString($r.RawContentStream.ToArray())
        return @{ ok = $true; body = $body }
    } catch {
        $status = $null
        if ($_.Exception.Response) { $status = [int]$_.Exception.Response.StatusCode }
        return @{ ok = $false; status = $status; error = $_.Exception.Message }
    }
}

function Set-FetchResult($res) {
    if ($res.ok) {
        try {
            $script:Data = $res.body | ConvertFrom-Json
            $script:LastError = $null
            $script:Updated = Get-Date
            if ($script:Data.limits.notAvailable) { $script:LastError = 'Limits unavailable for this account' }
        } catch {
            $script:LastError = 'Unexpected API response'
            Write-Log "json: $_ :: $($res.body)"
        }
    } elseif ($res.status -eq 401 -or $res.status -eq 403) {
        $script:LastError = 'Invalid API key or missing permission'
    } elseif ($res.status) {
        $script:LastError = "HTTP error $($res.status)"
    } else {
        $script:LastError = "Can't reach Factory"
    }
    if ($script:LastError) { Write-Log "$($script:LastError) $($res.error)" }
}

function Start-Refresh {
    if ($script:Fetch) { return }
    if ($Mock) {
        Set-FetchResult @{ ok = $true; body = (Get-Content $Mock -Raw -Encoding UTF8) }
        Test-Alerts
        Update-Ui
        return
    }
    $key = Get-ApiKey
    if (-not $key) {
        $script:LastError = 'Set your API key (right-click the icon)'
        Update-Ui
        return
    }
    $ps = [powershell]::Create()
    [void]$ps.AddScript($FetchScript).AddArgument((Get-LimitsUrl)).AddArgument($key)
    $script:Fetch = @{ ps = $ps; handle = $ps.BeginInvoke() }
    if ($script:Popup -and $script:Popup.Visible) { $script:Popup.Invalidate() }
}

function Complete-Refresh {
    if (-not $script:Fetch -or -not $script:Fetch.handle.IsCompleted) { return }
    $f = $script:Fetch
    $script:Fetch = $null
    try {
        $out = $f.ps.EndInvoke($f.handle)
        Set-FetchResult $out[0]
        if (-not $script:LastError) { Test-Alerts }
    } catch {
        $script:LastError = 'Failed to query the API'
        Write-Log "fetch: $_"
    } finally { $f.ps.Dispose() }
    Update-Ui
}

# ---------------------------------------------------------------- alerts

function Test-Alerts {
    $thresholds = @($script:Cfg.thresholds | ForEach-Object { [double]$_ } | Sort-Object)
    $msgs = New-Object System.Collections.Generic.List[string]
    $worst = 0
    foreach ($pool in @($script:Cfg.notifyPools)) {
        if (-not $Pools.Contains($pool)) { continue }
        foreach ($k in $Windows.Keys) {
            $i = Get-WinInfo $pool $k
            if ($null -eq $i.Pct) { continue }
            $id = "$pool.$k"
            $level = 0.0
            if ($script:Alerts.ContainsKey($id)) { $level = [double]$script:Alerts[$id] }

            # Usage dropped well below the last alert: the window has reset.
            if ($level -gt 0 -and $i.Pct -lt ($level - 5)) {
                if ($level -ge 100) { $msgs.Add(("{0} · {1}: limit available again ({2})" -f $Pools[$pool], $Windows[$k], (Format-Pct $i.Pct))) }
                $level = 0
            }
            $crossed = $thresholds | Where-Object { $i.Pct -ge $_ } | Select-Object -Last 1
            if ($crossed -and $crossed -gt $level) {
                $what = if ($i.Pct -ge 100) { 'limit reached' } else { 'at ' + (Format-Pct $i.Pct) }
                $msgs.Add(("{0} · {1}: {2}, resets in {3}" -f $Pools[$pool], $Windows[$k], $what, (Format-Remaining $i.End)))
                $level = $crossed
                if ($crossed -gt $worst) { $worst = $crossed }
            }
            $script:Alerts[$id] = $level
        }
    }
    try { $script:Alerts | ConvertTo-Json | Set-Content -Path $StatePath -Encoding UTF8 } catch { }

    if ($msgs.Count -gt 0 -and $script:Tray) {
        $title = 'Droid: credit usage'
        $icon = [Windows.Forms.ToolTipIcon]::Info
        if ($worst -ge 100) { $title = 'Droid: limit reached'; $icon = [Windows.Forms.ToolTipIcon]::Error }
        elseif ($worst -gt 0) { $title = 'Droid: approaching limit'; $icon = [Windows.Forms.ToolTipIcon]::Warning }
        $script:Tray.ShowBalloonTip(10000, $title, ($msgs -join "`n"), $icon)
    }
}

# ---------------------------------------------------------------- drawing

$C = @{
    Bg      = [Drawing.Color]::FromArgb(10, 10, 10)
    Border  = [Drawing.Color]::FromArgb(40, 40, 40)
    Text    = [Drawing.Color]::FromArgb(240, 240, 240)
    Muted   = [Drawing.Color]::FromArgb(130, 130, 130)
    Track   = [Drawing.Color]::FromArgb(38, 38, 38)
    Orange  = [Drawing.Color]::FromArgb(255, 92, 0)
    Red     = [Drawing.Color]::FromArgb(239, 68, 68)
    Link    = [Drawing.Color]::FromArgb(200, 200, 200)
    SegBg   = [Drawing.Color]::FromArgb(22, 22, 22)
}
$F = @{
    Title = New-Object Drawing.Font('Segoe UI Semibold', 10.5)
    Label = New-Object Drawing.Font('Segoe UI Semibold', 9.5)
    Body  = New-Object Drawing.Font('Segoe UI', 9)
    Small = New-Object Drawing.Font('Segoe UI', 8.5)
}
$TF = [Windows.Forms.TextFormatFlags]
$script:Tab   = 'standard'
$script:Hit   = @{}
$script:Hover = $null
$script:S     = 1.0

function New-RoundPath([Drawing.RectangleF]$r, [single]$rad) {
    $p = New-Object Drawing.Drawing2D.GraphicsPath
    $d = $rad * 2
    $p.AddArc($r.X, $r.Y, $d, $d, 180, 90)
    $p.AddArc($r.Right - $d, $r.Y, $d, $d, 270, 90)
    $p.AddArc($r.Right - $d, $r.Bottom - $d, $d, $d, 0, 90)
    $p.AddArc($r.X, $r.Bottom - $d, $d, $d, 90, 90)
    $p.CloseFigure()
    return $p
}

function Get-PopupSize { return New-Object Drawing.Size([int](420 * $script:S), [int](292 * $script:S)) }

function Draw-Text($g, [string]$text, $font, [int]$x, [int]$y, $color) {
    [Windows.Forms.TextRenderer]::DrawText($g, $text, $font, (New-Object Drawing.Point($x, $y)), $color, $TF::NoPadding)
}
function Measure-Text([string]$text, $font) {
    return [Windows.Forms.TextRenderer]::MeasureText($text, $font, (New-Object Drawing.Size(1000, 100)), $TF::NoPadding)
}

function Draw-Popup($g, [int]$W, [int]$H) {
    $s = $script:S
    $pad = [int](22 * $s)
    $g.Clear($C.Bg)
    $g.SmoothingMode = 'AntiAlias'
    $script:Hit = @{}

    # frame
    $pen = New-Object Drawing.Pen($C.Border)
    $g.DrawRectangle($pen, 0, 0, $W - 1, $H - 1)

    # header + Standard / Droid Core switch
    Draw-Text $g 'Usage Limits' $F.Title $pad ([int]($pad + 3 * $s)) $C.Text
    $segH = [int](30 * $s); $segY = $pad - [int](4 * $s)
    $tabs = @(@{ id = 'standard'; w = [int](86 * $s) }, @{ id = 'core'; w = [int](100 * $s) })
    $segW = $tabs[0].w + $tabs[1].w + [int](8 * $s)
    $x = $W - $pad - $segW
    $outer = New-Object Drawing.RectangleF($x, $segY, $segW, $segH)
    $path = New-RoundPath $outer (5 * $s)
    $g.FillPath((New-Object Drawing.SolidBrush($C.SegBg)), $path)
    $g.DrawPath($pen, $path)
    $tx = $x + [int](4 * $s)
    foreach ($t in $tabs) {
        $r = New-Object Drawing.Rectangle($tx, ($segY + [int](4 * $s)), $t.w, ($segH - [int](8 * $s)))
        $fg = $C.Muted
        if ($script:Tab -eq $t.id) {
            $g.FillPath([Drawing.Brushes]::White, (New-RoundPath ([Drawing.RectangleF]$r) (4 * $s)))
            $fg = [Drawing.Color]::Black
        } elseif ($script:Hover -eq "tab:$($t.id)") { $fg = $C.Text }
        [Windows.Forms.TextRenderer]::DrawText($g, $Pools[$t.id], $F.Body, $r, $fg, ($TF::HorizontalCenter -bor $TF::VerticalCenter -bor $TF::SingleLine))
        $script:Hit["tab:$($t.id)"] = $r
        $tx += $t.w
    }

    # bars
    $y = $pad + [int](50 * $s)
    $barW = $W - 2 * $pad
    $exhausted = $false
    foreach ($k in $Windows.Keys) {
        $i = Get-WinInfo $script:Tab $k
        $label = $Windows[$k]
        Draw-Text $g $label $F.Label $pad $y $C.Text
        $lw = (Measure-Text $label $F.Label).Width
        Draw-Text $g (Format-Pct $i.Pct) $F.Small ($pad + $lw + [int](8 * $s)) ($y + [int](1 * $s)) $C.Muted

        $reset = [char]0x21BB + ' ' + (Format-Remaining $i.End)
        $rw = (Measure-Text $reset $F.Small).Width
        Draw-Text $g $reset $F.Small ($W - $pad - $rw) ($y + [int](1 * $s)) $C.Muted

        $by = $y + [int](25 * $s); $bh = [int](8 * $s)
        $g.FillRectangle((New-Object Drawing.SolidBrush($C.Track)), $pad, $by, $barW, $bh)
        if ($i.Pct -gt 0) {
            $fill = if ($i.Pct -ge 90) { $C.Red } else { $C.Orange }
            $fw = [math]::Max([int](2 * $s), [int]($barW * [math]::Min(100, $i.Pct) / 100))
            $g.FillRectangle((New-Object Drawing.SolidBrush($fill)), $pad, $by, $fw, $bh)
        }
        if ($i.Pct -ge 100) { $exhausted = $true }
        $y += [int](52 * $s)
    }

    # status
    $status = if (-not $script:Data) { '' }
              elseif ($exhausted) { "$($Pools[$script:Tab]) limit reached." }
              else { "You are using $($Pools[$script:Tab]) Usage." }
    if ($script:Data -and $script:Data.extraUsageBalanceCents -gt 0) {
        $status += '  Extra usage: ' + ('${0:0.00}' -f ($script:Data.extraUsageBalanceCents / 100))
    }
    Draw-Text $g $status $F.Small $pad ($y - [int](6 * $s)) $C.Muted

    # footer: updated / error + links
    $fy = $H - $pad - [int](12 * $s)
    $g.DrawLine($pen, $pad, $fy - [int](10 * $s), $W - $pad, $fy - [int](10 * $s))
    if ($script:Fetch) { $left = 'Refreshing…'; $lc = $C.Muted }
    elseif ($script:LastError) { $left = $script:LastError; $lc = $C.Red }
    elseif ($script:Updated) { $left = 'Updated ' + $script:Updated.ToString('HH:mm'); $lc = $C.Muted }
    else { $left = ''; $lc = $C.Muted }
    Draw-Text $g $left $F.Small $pad $fy $lc

    $lx = $W - $pad
    foreach ($l in @(@{ id = 'open'; t = 'Open dashboard ' + [char]0x2197 }, @{ id = 'refresh'; t = 'Refresh' })) {
        $sz = Measure-Text $l.t $F.Small
        $lx -= $sz.Width
        $col = if ($script:Hover -eq $l.id) { [Drawing.Color]::White } else { $C.Link }
        Draw-Text $g $l.t $F.Small $lx $fy $col
        $script:Hit[$l.id] = New-Object Drawing.Rectangle($lx, $fy, $sz.Width, $sz.Height)
        $lx -= [int](18 * $s)
    }
    $pen.Dispose()
}

function New-TrayBitmap([string]$text, $bg, $fg, [int]$sz) {
    $bmp = New-Object Drawing.Bitmap($sz, $sz)
    $g = [Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'
    $g.TextRenderingHint = 'AntiAliasGridFit'
    $g.FillPath((New-Object Drawing.SolidBrush($bg)), (New-RoundPath (New-Object Drawing.RectangleF(0, 0, ($sz - 1), ($sz - 1))) ($sz / 5)))
    $px = $sz * 0.72
    do {
        $font = New-Object Drawing.Font('Segoe UI', [single]$px, [Drawing.FontStyle]::Bold, [Drawing.GraphicsUnit]::Pixel)
        $m = $g.MeasureString($text, $font, 1000, [Drawing.StringFormat]::GenericTypographic)
        if ($m.Width -le $sz - 1) { break }
        $font.Dispose(); $px -= 0.5
    } while ($px -gt 5)
    $sf = New-Object Drawing.StringFormat([Drawing.StringFormat]::GenericTypographic)
    $sf.Alignment = 'Center'; $sf.LineAlignment = 'Center'
    $g.DrawString($text, $font, (New-Object Drawing.SolidBrush($fg)), (New-Object Drawing.RectangleF(0, ($sz * 0.04), $sz, $sz)), $sf)
    $g.Dispose(); $font.Dispose()
    return $bmp
}

function Get-TrayLook {
    $pool = $script:Cfg.trayPool
    $max = Get-PoolMax $pool
    if (-not $script:Data -or $null -eq $max) {
        $t = if ($script:LastError) { '!' } else { '…' }
        return @{ text = $t; bg = [Drawing.Color]::FromArgb(60, 60, 60); fg = [Drawing.Color]::White }
    }
    $bg = [Drawing.Color]::FromArgb(38, 38, 38)
    if ($max -ge 90) { $bg = $C.Red } elseif ($max -ge 75) { $bg = $C.Orange }
    return @{ text = ('{0:0}' -f [math]::Min(100, [math]::Floor($max))); bg = $bg; fg = [Drawing.Color]::White }
}

# ---------------------------------------------------------------- preview / dump modes

if ($Dump) {
    $key = Get-ApiKey
    if (-not $key) { Write-Error 'No API key (set FACTORY_API_KEY or configure it in the app)'; exit 1 }
    $r = & $FetchScript (Get-LimitsUrl) $key
    if ($r.ok) { $r.body } else { "Failed: HTTP $($r.status) $($r.error)" }
    exit 0
}

if ($Preview) {
    if ($Mock) { Set-FetchResult @{ ok = $true; body = (Get-Content $Mock -Raw -Encoding UTF8) } }
    $script:Updated = Get-Date
    $script:S = 1.0
    $sz = Get-PopupSize
    $bmp = New-Object Drawing.Bitmap($sz.Width, $sz.Height)
    $g = [Drawing.Graphics]::FromImage($bmp)
    Draw-Popup $g $sz.Width $sz.Height
    $g.Dispose()
    $bmp.Save($Preview, [Drawing.Imaging.ImageFormat]::Png)
    $look = Get-TrayLook
    (New-TrayBitmap $look.text $look.bg $look.fg 64).Save(($Preview -replace '\.png$', '-icon.png'), [Drawing.Imaging.ImageFormat]::Png)
    "ok: $Preview"
    exit 0
}

# ---------------------------------------------------------------- app

$mutex = New-Object Threading.Mutex($false, 'Local\DroidBar-Tray')
if (-not $mutex.WaitOne(0)) { exit 0 }

$console = [DBNative]::GetConsoleWindow()
if ($console -ne [IntPtr]::Zero) { [void][DBNative]::ShowWindow($console, 0) }
[void][DBNative]::SetProcessDPIAware()
[Windows.Forms.Application]::EnableVisualStyles()

# --- popup
$script:Popup = New-Object Windows.Forms.Form
$Popup.FormBorderStyle = 'None'
$Popup.ShowInTaskbar = $false
$Popup.TopMost = $true
$Popup.StartPosition = 'Manual'
$Popup.BackColor = $C.Bg
$Popup.KeyPreview = $true
$Popup.GetType().GetProperty('DoubleBuffered', [Reflection.BindingFlags]'NonPublic,Instance').SetValue($Popup, $true, $null)
$tmpG = $Popup.CreateGraphics(); $script:S = $tmpG.DpiX / 96.0; $tmpG.Dispose()
$Popup.ClientSize = Get-PopupSize
$corner = 2
[void][DBNative]::DwmSetWindowAttribute($Popup.Handle, 33, [ref]$corner, 4)   # rounded corners (Win11)
$script:HiddenAt = [datetime]::MinValue

$Popup.Add_Paint({ param($sender, $e)
    try { Draw-Popup $e.Graphics $sender.ClientSize.Width $sender.ClientSize.Height } catch { Write-Log "paint: $_" }
})
$Popup.Add_Deactivate({ $script:Popup.Hide(); $script:HiddenAt = Get-Date })
$Popup.Add_KeyDown({ param($sender, $e) if ($e.KeyCode -eq 'Escape') { $sender.Hide() } })
$Popup.Add_MouseMove({ param($sender, $e)
    $hover = $null
    foreach ($k in $script:Hit.Keys) { if ($script:Hit[$k].Contains($e.Location)) { $hover = $k } }
    if ($hover -ne $script:Hover) {
        $script:Hover = $hover
        $sender.Cursor = if ($hover) { [Windows.Forms.Cursors]::Hand } else { [Windows.Forms.Cursors]::Default }
        $sender.Invalidate()
    }
})
$Popup.Add_MouseClick({ param($sender, $e)
    try {
        switch ($script:Hover) {
            'tab:standard' { $script:Tab = 'standard'; $sender.Invalidate() }
            'tab:core'     { $script:Tab = 'core'; $sender.Invalidate() }
            'refresh'      { Start-Refresh }
            'open'         { Start-Process $UsageUrl; $sender.Hide() }
        }
    } catch { Write-Log "click: $_" }
})

function Show-Popup {
    if ($script:Popup.Visible) { $script:Popup.Hide(); return }
    if (((Get-Date) - $script:HiddenAt).TotalMilliseconds -lt 300) { return }   # the icon click that just closed it
    $sz = $script:Popup.Size
    $cur = [Windows.Forms.Cursor]::Position
    $wa = [Windows.Forms.Screen]::FromPoint($cur).WorkingArea
    $m = [int](12 * $script:S)
    $x = [math]::Min([math]::Max($cur.X - $sz.Width / 2, $wa.Left + $m), $wa.Right - $sz.Width - $m)
    $y = if ($cur.Y -gt $wa.Top + $wa.Height / 2) { $wa.Bottom - $sz.Height - $m } else { $wa.Top + $m }
    $script:Popup.Location = New-Object Drawing.Point([int]$x, [int]$y)
    $script:Popup.Show()
    $script:Popup.Activate()
    if (-not $script:Updated -or ((Get-Date) - $script:Updated).TotalSeconds -gt 60) { Start-Refresh }
}

# --- API key dialog
function Show-KeyDialog {
    $s = $script:S
    $dlg = New-Object Windows.Forms.Form
    $dlg.Text = 'Droid Bar · API key'
    $dlg.FormBorderStyle = 'FixedDialog'; $dlg.MaximizeBox = $false; $dlg.MinimizeBox = $false
    $dlg.StartPosition = 'CenterScreen'; $dlg.TopMost = $true
    $dlg.ClientSize = New-Object Drawing.Size([int](440 * $s), [int](150 * $s))
    $dlg.Font = $F.Body

    $lbl = New-Object Windows.Forms.Label
    $lbl.Text = 'Paste a Factory API key (fk-...). It is stored encrypted (DPAPI) for your Windows user only.'
    $lbl.SetBounds([int](14 * $s), [int](12 * $s), [int](412 * $s), [int](36 * $s))
    $link = New-Object Windows.Forms.LinkLabel
    $link.Text = 'Get a key at app.factory.ai/settings/api-keys'
    $link.SetBounds([int](14 * $s), [int](50 * $s), [int](412 * $s), [int](20 * $s))
    $link.Add_LinkClicked({ Start-Process $KeysUrl })
    $box = New-Object Windows.Forms.TextBox
    $box.UseSystemPasswordChar = $true
    $box.SetBounds([int](14 * $s), [int](76 * $s), [int](412 * $s), [int](24 * $s))
    $ok = New-Object Windows.Forms.Button
    $ok.Text = 'Save'; $ok.DialogResult = 'OK'
    $ok.SetBounds([int](266 * $s), [int](112 * $s), [int](78 * $s), [int](28 * $s))
    $cancel = New-Object Windows.Forms.Button
    $cancel.Text = 'Cancel'; $cancel.DialogResult = 'Cancel'
    $cancel.SetBounds([int](348 * $s), [int](112 * $s), [int](78 * $s), [int](28 * $s))
    $dlg.Controls.AddRange(@($lbl, $link, $box, $ok, $cancel))
    $dlg.AcceptButton = $ok; $dlg.CancelButton = $cancel

    if ($dlg.ShowDialog() -eq 'OK' -and $box.Text.Trim()) {
        $key = $box.Text.Trim()
        $test = & $FetchScript (Get-LimitsUrl) $key
        if (-not $test.ok -and ($test.status -eq 401 -or $test.status -eq 403)) {
            [void][Windows.Forms.MessageBox]::Show('Factory rejected this key (HTTP ' + $test.status + ').', 'Droid Bar', 'OK', 'Warning')
        } else {
            Set-ApiKey $key
            Set-FetchResult $test
            Update-Ui
        }
    }
    $dlg.Dispose()
}

# --- start with Windows
$ExePath = Join-Path (Split-Path $ScriptPath) 'DroidBar.exe'
function Get-RunCommand {
    if (Test-Path $ExePath) { return ('"{0}"' -f $ExePath) }
    return ('"{0}\System32\conhost.exe" --headless powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{1}"' -f $env:SystemRoot, $ScriptPath)
}
function Test-Autostart {
    try { return [bool](Get-ItemProperty -Path $RunKey -Name $AppName -ErrorAction Stop).$AppName } catch { return $false }
}
function Set-Autostart([bool]$on) {
    if ($on) { Set-ItemProperty -Path $RunKey -Name $AppName -Value (Get-RunCommand) }
    else { Remove-ItemProperty -Path $RunKey -Name $AppName -ErrorAction SilentlyContinue }
}

# --- tray
$script:Tray = New-Object Windows.Forms.NotifyIcon
$script:PrevIcon = $null
$menu = New-Object Windows.Forms.ContextMenuStrip
$miOpen = $menu.Items.Add('Show usage')
$miOpen.Font = New-Object Drawing.Font($miOpen.Font, [Drawing.FontStyle]::Bold)
$miOpen.Add_Click({ Show-Popup })
$menu.Items.Add('Refresh now').Add_Click({ Start-Refresh })
[void]$menu.Items.Add('-')
$menu.Items.Add('Open Factory dashboard').Add_Click({ Start-Process $UsageUrl })
$menu.Items.Add('Set API key…').Add_Click({ Show-KeyDialog })
$miAuto = New-Object Windows.Forms.ToolStripMenuItem('Start with Windows')
if (Test-Autostart) { Set-Autostart $true }   # refresh old entries (powershell -> DroidBar.exe)
$miAuto.Checked = Test-Autostart
$miAuto.Add_Click({ Set-Autostart (-not $miAuto.Checked); $miAuto.Checked = Test-Autostart })
[void]$menu.Items.Add($miAuto)
$menu.Items.Add('Open settings folder').Add_Click({ Start-Process $DataDir })
[void]$menu.Items.Add('-')
$menu.Items.Add('Quit').Add_Click({
    $script:Tray.Visible = $false
    [Windows.Forms.Application]::Exit()
})
$Tray.ContextMenuStrip = $menu
$Tray.Add_MouseClick({ param($sender, $e) if ($e.Button -eq 'Left') { Show-Popup } })
$Tray.Add_BalloonTipClicked({ Show-Popup })

function Update-Ui {
    try {
        $look = Get-TrayLook
        $sz = [math]::Max(16, [Windows.Forms.SystemInformation]::SmallIconSize.Width)
        $bmp = New-TrayBitmap $look.text $look.bg $look.fg $sz
        $h = $bmp.GetHicon()
        $script:Tray.Icon = [Drawing.Icon]::FromHandle($h)
        $bmp.Dispose()
        if ($script:PrevIcon) { [void][DBNative]::DestroyIcon($script:PrevIcon) }
        $script:PrevIcon = $h

        if ($script:Data) {
            $parts = foreach ($k in $Windows.Keys) { '{0} {1}' -f $Short[$k], (Format-Pct (Get-WinInfo 'standard' $k).Pct) }
            $tip = 'Droid · ' + ($parts -join ' · ')
            $core = Get-PoolMax 'core'
            if ($null -ne $core) { $tip += "`nCore up to " + (Format-Pct $core) }
        } elseif ($script:LastError) { $tip = 'Droid · ' + $script:LastError }
        else { $tip = 'Droid · loading…' }
        if ($tip.Length -gt 63) { $tip = $tip.Substring(0, 63) }
        $script:Tray.Text = $tip
        if ($script:Popup.Visible) { $script:Popup.Invalidate() }
    } catch { Write-Log "ui: $_" }
}

# --- timers
$pollTimer = New-Object Windows.Forms.Timer
$pollTimer.Interval = [int]([math]::Max(1, [double]$script:Cfg.pollMinutes) * 60000)
$pollTimer.Add_Tick({ Start-Refresh })
$pollTimer.Start()

$fetchTimer = New-Object Windows.Forms.Timer
$fetchTimer.Interval = 300
$fetchTimer.Add_Tick({ Complete-Refresh })
$fetchTimer.Start()

$clockTimer = New-Object Windows.Forms.Timer
$clockTimer.Interval = 30000
$clockTimer.Add_Tick({ if ($script:Popup.Visible) { $script:Popup.Invalidate() } })
$clockTimer.Start()

Update-Ui
$Tray.Visible = $true
if (-not (Get-ApiKey) -and -not $Mock) { Show-KeyDialog }
Start-Refresh

[Windows.Forms.Application]::Run()

$Tray.Dispose()
if ($script:PrevIcon) { [void][DBNative]::DestroyIcon($script:PrevIcon) }
$mutex.ReleaseMutex()
