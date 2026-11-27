#Requires -Version 5.1
<#
  Droid Bar - Windows tray icon showing your Factory Droid usage limits.

  Usage:
    DroidBar.exe                      (or: powershell -NoProfile -ExecutionPolicy Bypass -File droid-bar.ps1)
    ... -Mock samples\mock.json       use a local JSON file instead of the API
    ... -Preview popup.png            render the popup to a PNG and exit
    ... -PreviewTab <id>              with -Preview: which tab to render (standard | core | computer)
    ... -Dump                         print the raw API response and exit
#>
param(
    [string]$Mock,
    [string]$Preview,
    [string]$PreviewTab,
    [switch]$Dump
)

Set-StrictMode -Version Latest
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

# GUI-free helpers (parsing, formatting, alert logic, tray look) live in a sibling
# module so they can be unit-tested off-Windows; it never loads WinForms/Drawing.
# $PSScriptRoot resolves to the exe folder under DroidBar.exe too, so the release
# zip layout (script + src\droid-bar-lib.psm1) works as-is.
Import-Module (Join-Path (Join-Path $PSScriptRoot 'src') 'droid-bar-lib.psm1')
Initialize-LibState -LogPath $LogPath -StatePath $StatePath

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

# ---------------------------------------------------------------- fetching

$script:Cfg = Get-Config
Set-LibConfig -Config $script:Cfg
$script:Fetch = $null

function Get-LimitsUrl { return ($script:Cfg.apiBase.TrimEnd('/') + '/api/billing/limits') }
function Get-ComputersUrl { return ($script:Cfg.apiBase.TrimEnd('/') + '/api/v0/computers') }
function Get-ComputeUsageUrl { return ($script:Cfg.apiBase.TrimEnd('/') + '/api/organization/compute-usage') }

# One background job fetches all three endpoints with the same Bearer key and
# returns @{ limits = <result>; computers = <result>; computeUsage = <result> }
# so a computers or compute-usage failure can never take the limits display
# down (each half carries its own ok/status/error).
$FetchScript = {
    param($limitsUrl, $computersUrl, $computeUsageUrl, $key)
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    function Get-RemoteJson($url) {
        try {
            $r = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 20 -Headers @{ Authorization = "Bearer $key"; Accept = 'application/json' }
            return @{ ok = $true; body = [Text.Encoding]::UTF8.GetString($r.RawContentStream.ToArray()) }
        } catch {
            $status = $null
            if ($_.Exception.Response) { $status = [int]$_.Exception.Response.StatusCode }
            return @{ ok = $false; status = $status; error = $_.Exception.Message }
        }
    }
    return @{ limits = (Get-RemoteJson $limitsUrl); computers = (Get-RemoteJson $computersUrl); computeUsage = (Get-RemoteJson $computeUsageUrl) }
}

function Start-Refresh {
    if ($script:Fetch) { return }
    if ($Mock) {
        # Same file feeds all three endpoints: mock.json carries the limits windows,
        # the computers array and the computeUsage object (real-API shape parity).
        $body = (Get-Content $Mock -Raw -Encoding UTF8)
        Set-FetchResult @{ ok = $true; body = $body }
        Set-ComputersResult @{ ok = $true; body = $body }
        Set-ComputeUsageResult @{ ok = $true; body = $body }
        Show-Alerts
        Update-Ui
        return
    }
    $key = Get-ApiKey
    if (-not $key) {
        Set-FetchError 'Set your API key (right-click the icon)'
        Update-Ui
        return
    }
    $ps = [powershell]::Create()
    [void]$ps.AddScript($FetchScript).AddArgument((Get-LimitsUrl)).AddArgument((Get-ComputersUrl)).AddArgument((Get-ComputeUsageUrl)).AddArgument($key)
    $script:Fetch = @{ ps = $ps; handle = $ps.BeginInvoke() }
    if ($script:Popup -and $script:Popup.Visible) { $script:Popup.Invalidate() }
}

function Complete-Refresh {
    if (-not $script:Fetch -or -not $script:Fetch.handle.IsCompleted) { return }
    $f = $script:Fetch
    $script:Fetch = $null
    try {
        $out = $f.ps.EndInvoke($f.handle)
        Set-FetchResult $out[0].limits
        # Computers and compute-usage failures are contained: Set-ComputersResult
        # and Set-ComputeUsageResult only touch their own state, so the limits
        # display keeps working either way.
        Set-ComputersResult $out[0].computers
        Set-ComputeUsageResult $out[0].computeUsage
        if (-not (Get-FetchError)) { Show-Alerts }
    } catch {
        Set-FetchError 'Failed to query the API'
        Write-Log "fetch: $_"
    } finally { $f.ps.Dispose() }
    Update-Ui
}

# ---------------------------------------------------------------- alerts

# Test-Alerts (module) computes the threshold crossings and updates state.json;
# here we only turn its result into the tray balloon notification.
function Show-Alerts {
    $r = Test-Alerts
    if ($r.Messages.Count -gt 0 -and $script:Tray) {
        $title = 'Droid: credit usage'
        $icon = [Windows.Forms.ToolTipIcon]::Info
        if ($r.Worst -ge 100) { $title = 'Droid: limit reached'; $icon = [Windows.Forms.ToolTipIcon]::Error }
        elseif ($r.Worst -gt 0) { $title = 'Droid: approaching limit'; $icon = [Windows.Forms.ToolTipIcon]::Warning }
        $script:Tray.ShowBalloonTip(10000, $title, ($r.Messages -join "`n"), $icon)
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
# Get-TrayLook (module) returns palette names; map them to System.Drawing colors.
# 'transparent' means no badge fill (normal state: the mark sits straight on the
# taskbar); 'dark' is only used as the mark/text color when the taskbar is light.
$TrayColors = @{
    transparent = [Drawing.Color]::Transparent
    dark        = [Drawing.Color]::FromArgb(24, 24, 24)
    orange      = $C.Orange
    red         = $C.Red
    white       = [Drawing.Color]::White
}
# Computer status chips (palette names from Get-ComputerStatusColor, same
# convention as $TrayColors): active accent green, paused muted, provisioning
# orange, failed red, unknown gray.
$ChipColors = @{
    green  = @{ bg = [Drawing.Color]::FromArgb(34, 197, 94); fg = [Drawing.Color]::FromArgb(10, 10, 10) }
    muted  = @{ bg = $C.Muted;                               fg = [Drawing.Color]::White }
    orange = @{ bg = $C.Orange;                              fg = [Drawing.Color]::FromArgb(10, 10, 10) }
    red    = @{ bg = $C.Red;                                 fg = [Drawing.Color]::White }
    gray   = @{ bg = [Drawing.Color]::FromArgb(90, 90, 90);  fg = [Drawing.Color]::White }
}
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

# Content-aware popup size: the Standard/Core view needs a fixed height for the
# three usage bars; the Computer view grows with the Managed Computers Usage
# card (when it renders) and with the number of machines, and keeps a compact
# floor when the list is empty or unavailable.
function Get-PopupSize {
    $s = $script:S
    if ($script:Tab -eq 'computer') {
        # usage card (label row + bar + hours line + gap) only takes space when visible
        $usageH = 0
        $usage = Get-ComputeUsageInfo
        if ($null -ne $usage.Pct) { $usageH = [int](64 * $s) }
        $computers = Get-Computers
        $n = 0
        if ($computers) { $n = @($computers).Count }
        if ($n -eq 0) { return New-Object Drawing.Size([int](420 * $s), ([int](180 * $s) + $usageH)) }
        # header (72) + summary row + one 28px row per machine + footer (58)
        $h = [int](150 * $s) + ([int](28 * $s) * $n) + $usageH
        return New-Object Drawing.Size([int](420 * $s), $h)
    }
    return New-Object Drawing.Size([int](420 * $s), [int](292 * $s))
}

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

    # header + tab switch, driven by the tab registry (Get-TabRegistry in the
    # lib module: id -> label + width). Computer is a tab here but never a
    # $Pools key, so it can never opt into notifications.
    Draw-Text $g 'Usage Limits' $F.Title $pad ([int]($pad + 3 * $s)) $C.Text
    $segH = [int](30 * $s); $segY = $pad - [int](4 * $s)
    $registry = Get-TabRegistry
    $segW = [int](8 * $s)
    foreach ($id in @($registry.Keys)) { $segW += [int]($registry[$id].width * $s) }
    $x = $W - $pad - $segW
    $outer = New-Object Drawing.RectangleF($x, $segY, $segW, $segH)
    $path = New-RoundPath $outer (5 * $s)
    $g.FillPath((New-Object Drawing.SolidBrush($C.SegBg)), $path)
    $g.DrawPath($pen, $path)
    $tx = $x + [int](4 * $s)
    foreach ($id in @($registry.Keys)) {
        $t = $registry[$id]
        $r = New-Object Drawing.Rectangle($tx, ($segY + [int](4 * $s)), [int]($t.width * $s), ($segH - [int](8 * $s)))
        $fg = $C.Muted
        if ($script:Tab -eq $id) {
            $g.FillPath([Drawing.Brushes]::White, (New-RoundPath ([Drawing.RectangleF]$r) (4 * $s)))
            $fg = [Drawing.Color]::Black
        } elseif ($script:Hover -eq "tab:$id") { $fg = $C.Text }
        [Windows.Forms.TextRenderer]::DrawText($g, $t.label, $F.Body, $r, $fg, ($TF::HorizontalCenter -bor $TF::VerticalCenter -bor $TF::SingleLine))
        $script:Hit["tab:$id"] = $r
        $tx += [int]($t.width * $s)
    }

    # body: tab-specific content
    if ($script:Tab -eq 'computer') {
        Draw-ComputerView $g $W $H
    } else {
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
        $data = Get-UsageData
        $status = if (-not $data) { '' }
                  elseif ($exhausted) { "$($Pools[$script:Tab]) limit reached." }
                  else { "You are using $($Pools[$script:Tab]) Usage." }
        if ($data -and ((Get-MemberValue $data 'extraUsageBalanceCents') -gt 0)) {
            $status += '  Extra usage: ' + ('${0:0.00}' -f ($data.extraUsageBalanceCents / 100))
        }
        Draw-Text $g $status $F.Small $pad ($y - [int](6 * $s)) $C.Muted
    }

    # footer: updated / error + links
    Draw-Footer $g $W $H
    $pen.Dispose()
}

# Computer tab body (display-only): the Managed Computers Usage card (when the
# org has a usable quota), a summary line, then one row per machine — name +
# provider type on the left, a status chip on the right. Unavailable or empty
# data degrades to a single message line.
function Draw-ComputerView($g, [int]$W, [int]$H) {
    $s = $script:S
    $pad = [int](22 * $s)
    $computers = Get-Computers
    $y = $pad + [int](50 * $s)

    # Managed Computers Usage card (org compute quota per billing cycle), matching
    # the dashboard's card: label + percent, always-orange bar, hours used /
    # included, and the billing-cycle reset countdown. Hidden entirely when the
    # usage fetch failed or the org has no usable quota — the machine list keeps
    # rendering either way (same containment as the computers errors).
    $usage = Get-ComputeUsageInfo
    if ($null -ne $usage.Pct) {
        $label = 'Managed Computers Usage'
        Draw-Text $g $label $F.Label $pad $y $C.Text
        $lw = (Measure-Text $label $F.Label).Width
        Draw-Text $g (Format-Pct $usage.Pct) $F.Small ($pad + $lw + [int](8 * $s)) ($y + [int](1 * $s)) $C.Muted

        $reset = [char]0x21BB + ' ' + (Format-Remaining $usage.End)
        $rw = (Measure-Text $reset $F.Small).Width
        Draw-Text $g $reset $F.Small ($W - $pad - $rw) ($y + [int](1 * $s)) $C.Muted

        $barW = $W - 2 * $pad
        $by = $y + [int](25 * $s); $bh = [int](8 * $s)
        $g.FillRectangle((New-Object Drawing.SolidBrush($C.Track)), $pad, $by, $barW, $bh)
        # Always orange, like the dashboard card (never switches to red).
        $fw = [math]::Max([int](2 * $s), [int]($barW * [math]::Min(100, $usage.Pct) / 100))
        $g.FillRectangle((New-Object Drawing.SolidBrush($C.Orange)), $pad, $by, $fw, $bh)

        $hours = (Format-ComputeHours $usage.UsedMs) + ' / ' + (Format-ComputeHours $usage.LimitMs)
        Draw-Text $g $hours $F.Small $pad ($by + $bh + [int](6 * $s)) $C.Muted
        $y += [int](64 * $s)
    }

    $err = Get-ComputersError
    if ($err) { Draw-Text $g ('Computers unavailable · ' + $err) $F.Small $pad $y $C.Red; return }
    if (-not $computers) { Draw-Text $g 'No computers' $F.Small $pad $y $C.Muted; return }

    Draw-Text $g (Format-ComputerSummary $computers) $F.Label $pad $y $C.Text
    $y += [int](30 * $s)
    # Loop variable is $machine, NOT $c: PowerShell variable names are
    # case-insensitive and $c would shadow the $C color palette, breaking
    # $C.Text under strict mode.
    foreach ($machine in @($computers)) {
        $name = $machine['name']
        $prov = $machine['providerType']
        Draw-Text $g $name $F.Body $pad $y $C.Text
        $nw = (Measure-Text $name $F.Body).Width
        Draw-Text $g $prov $F.Small ($pad + $nw + [int](8 * $s)) ($y + [int](2 * $s)) $C.Muted

        # status chip: pill filled with the palette color, label right-aligned
        $status = $machine['status']
        $pal = Get-ComputerStatusColor $status
        $cc = $ChipColors[$pal]
        $cw = (Measure-Text $status $F.Small).Width + [int](14 * $s)
        $ch = [int](16 * $s)
        $r = New-Object Drawing.RectangleF(($W - $pad - $cw), ($y - [int](1 * $s)), $cw, $ch)
        $pill = New-RoundPath $r ($ch / 2)
        $g.FillPath((New-Object Drawing.SolidBrush($cc.bg)), $pill)
        $pill.Dispose()
        [Windows.Forms.TextRenderer]::DrawText($g, $status, $F.Small, (New-Object Drawing.Point(($W - $pad - $cw + [int](7 * $s)), ($y + [int](1 * $s)))), $cc.fg, $TF::NoPadding)
        $y += [int](28 * $s)
    }
}

function Draw-Footer($g, [int]$W, [int]$H) {
    $s = $script:S
    $pad = [int](22 * $s)
    $pen = New-Object Drawing.Pen($C.Border)
    $fy = $H - $pad - [int](12 * $s)
    $g.DrawLine($pen, $pad, $fy - [int](10 * $s), $W - $pad, $fy - [int](10 * $s))
    $err = Get-FetchError
    $upd = Get-LastUpdated
    if ($script:Fetch) { $left = 'Refreshing…'; $lc = $C.Muted }
    elseif ($err) { $left = $err; $lc = $C.Red }
    elseif ($upd) { $left = 'Updated ' + $upd.ToString('HH:mm'); $lc = $C.Muted }
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

# Factory logo mark (factory.ai brand SVG rasterized white on transparent at
# 256x248), embedded as base64 so the release layout stays script + module only.
$script:MarkPngB64 = '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'
$script:MarkBitmap = $null

function Get-MarkBitmap {
    if (-not $script:MarkBitmap) {
        $ms = New-Object IO.MemoryStream(, [Convert]::FromBase64String($script:MarkPngB64))
        $script:MarkBitmap = [Drawing.Bitmap]::FromStream($ms)
    }
    return $script:MarkBitmap
}

function New-TrayBitmap([string]$text, $bg, $fg, [int]$sz) {
    $bmp = New-Object Drawing.Bitmap($sz, $sz)
    $g = [Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'
    $g.TextRenderingHint = 'AntiAliasGridFit'
    # Rounded-square badge only for the alert states (orange/red); the normal
    # state draws the mark straight on the (transparent) taskbar like the native
    # tray icons. The no-data ('…') and error ('!') states keep drawing as text;
    # the hover tooltip and the popup carry the exact percentages.
    $hasBg = ($bg.A -gt 0)
    if ($hasBg) {
        $g.FillPath((New-Object Drawing.SolidBrush($bg)), (New-RoundPath (New-Object Drawing.RectangleF(0, 0, ($sz - 1), ($sz - 1))) ($sz / 5)))
    }
    if ($text -eq '…' -or $text -eq '!') {
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
    # Bigger mark without the badge (native-icon proportion), inset when badged.
    $h = if ($hasBg) { $sz * 0.62 } else { $sz * 0.84 }
    $w = $h * 67 / 65   # mark viewBox aspect (67x65)
    $g.InterpolationMode = 'HighQualityBicubic'
    $mark = Get-MarkBitmap
    if ($fg.R -eq 255 -and $fg.G -eq 255 -and $fg.B -eq 255) {
        $g.DrawImage($mark, [single](($sz - $w) / 2), [single](($sz - $h) / 2), [single]$w, [single]$h)
    } else {
        # Tint the white mark to $fg (light-taskbar variant): the color matrix
        # scales RGB and leaves the alpha channel untouched.
        $ia = New-Object Drawing.Imaging.ImageAttributes
        $cm = New-Object Drawing.Imaging.ColorMatrix
        $cm.Matrix00 = [single]($fg.R / 255.0)
        $cm.Matrix11 = [single]($fg.G / 255.0)
        $cm.Matrix22 = [single]($fg.B / 255.0)
        $ia.SetColorMatrix($cm)
        $dest = New-Object Drawing.Rectangle([int][math]::Round(($sz - $w) / 2), [int][math]::Round(($sz - $h) / 2), [int][math]::Round($w), [int][math]::Round($h))
        $g.DrawImage($mark, $dest, 0, 0, $mark.Width, $mark.Height, [Drawing.GraphicsUnit]::Pixel, $ia)
        $ia.Dispose()
    }
    $g.Dispose()
    return $bmp
}

# ---------------------------------------------------------------- preview / dump modes

if ($Dump) {
    $key = Get-ApiKey
    if (-not $key) { Write-Error 'No API key (set FACTORY_API_KEY or configure it in the app)'; exit 1 }
    $r = & $FetchScript (Get-LimitsUrl) (Get-ComputersUrl) (Get-ComputeUsageUrl) $key
    if ($r.limits.ok) { $r.limits.body } else { "Failed: HTTP $($r.limits.status) $($r.limits.error)" }
    if ($r.computeUsage.ok) { '--- compute-usage ---'; $r.computeUsage.body } else { "Compute usage failed: HTTP $($r.computeUsage.status) $($r.computeUsage.error)" }
    exit 0
}

if ($Preview) {
    # -PreviewTab <id> picks the tab the preview renders (default standard).
    if ($PreviewTab) {
        $registry = Get-TabRegistry
        if (-not $registry.Contains($PreviewTab)) {
            [Console]::Error.WriteLine(("Unknown -PreviewTab '{0}' (valid: {1})" -f $PreviewTab, (@($registry.Keys) -join ', ')))
            exit 1
        }
        $script:Tab = $PreviewTab
    }
    if ($Mock) {
        $body = (Get-Content $Mock -Raw -Encoding UTF8)
        Set-FetchResult @{ ok = $true; body = $body }
        Set-ComputersResult @{ ok = $true; body = $body }
        Set-ComputeUsageResult @{ ok = $true; body = $body }
    }
    Set-LastUpdated (Get-Date)
    $script:S = 1.0
    $sz = Get-PopupSize
    $bmp = New-Object Drawing.Bitmap($sz.Width, $sz.Height)
    $g = [Drawing.Graphics]::FromImage($bmp)
    Draw-Popup $g $sz.Width $sz.Height
    $g.Dispose()
    $bmp.Save($Preview, [Drawing.Imaging.ImageFormat]::Png)
    $look = Get-TrayLook
    (New-TrayBitmap $look.text $TrayColors[$look.bg] $TrayColors[$look.fg] 64).Save(($Preview -replace '\.png$', '-icon.png'), [Drawing.Imaging.ImageFormat]::Png)
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

$Popup.Add_Paint({ param($form, $e)
    try { Draw-Popup $e.Graphics $form.ClientSize.Width $form.ClientSize.Height } catch { Write-Log "paint: $_" }
})
$Popup.Add_Deactivate({ $script:Popup.Hide(); $script:HiddenAt = Get-Date })
$Popup.Add_KeyDown({ param($form, $e) if ($e.KeyCode -eq 'Escape') { $form.Hide() } })
$Popup.Add_MouseMove({ param($form, $e)
    $hover = $null
    foreach ($k in $script:Hit.Keys) { if ($script:Hit[$k].Contains($e.Location)) { $hover = $k } }
    if ($hover -ne $script:Hover) {
        $script:Hover = $hover
        $form.Cursor = if ($hover) { [Windows.Forms.Cursors]::Hand } else { [Windows.Forms.Cursors]::Default }
        $form.Invalidate()
    }
})
$Popup.Add_MouseClick({ param($form, $e)
    try {
        switch ($script:Hover) {
            'refresh'      { Start-Refresh }
            'open'         { Start-Process $UsageUrl; $form.Hide() }
        }
        # Tab clicks dispatch through the registry (no literal per-tab cases);
        # switching tabs also resizes the popup to the tab's content height.
        if ($script:Hover -like 'tab:*') {
            $id = $script:Hover.Substring(4)
            if ((Get-TabRegistry).Contains($id)) {
                $script:Tab = $id
                $form.ClientSize = Get-PopupSize
                $form.Invalidate()
            }
        }
    } catch { Write-Log "click: $_" }
})

function Show-Popup {
    if ($script:Popup.Visible) { $script:Popup.Hide(); return }
    if (((Get-Date) - $script:HiddenAt).TotalMilliseconds -lt 300) { return }   # the icon click that just closed it
    $script:Popup.ClientSize = Get-PopupSize   # content-aware height may have changed since last shown
    $sz = $script:Popup.Size
    $cur = [Windows.Forms.Cursor]::Position
    $wa = [Windows.Forms.Screen]::FromPoint($cur).WorkingArea
    $m = [int](12 * $script:S)
    $x = [math]::Min([math]::Max($cur.X - $sz.Width / 2, $wa.Left + $m), $wa.Right - $sz.Width - $m)
    $y = if ($cur.Y -gt $wa.Top + $wa.Height / 2) { $wa.Bottom - $sz.Height - $m } else { $wa.Top + $m }
    $script:Popup.Location = New-Object Drawing.Point([int]$x, [int]$y)
    $script:Popup.Show()
    $script:Popup.Activate()
    $upd = Get-LastUpdated
    if (-not $upd -or ((Get-Date) - $upd).TotalSeconds -gt 60) { Start-Refresh }
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
        $test = & $FetchScript (Get-LimitsUrl) (Get-ComputersUrl) (Get-ComputeUsageUrl) $key
        if (-not $test.limits.ok -and ($test.limits.status -eq 401 -or $test.limits.status -eq 403)) {
            [void][Windows.Forms.MessageBox]::Show('Factory rejected this key (HTTP ' + $test.limits.status + ').', 'Droid Bar', 'OK', 'Warning')
        } else {
            Set-ApiKey $key
            Set-FetchResult $test.limits
            Set-ComputersResult $test.computers
            Set-ComputeUsageResult $test.computeUsage
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
$Tray.Add_MouseClick({ param($form, $e) if ($e.Button -eq 'Left') { Show-Popup } })
$Tray.Add_BalloonTipClicked({ Show-Popup })

# Light-taskbar detection for the transparent tray states: Windows paints the
# taskbar light when SystemUsesLightTheme is 1 (missing key = dark, the default).
function Test-LightTaskbar {
    try {
        return [bool](Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -Name SystemUsesLightTheme -ErrorAction Stop).SystemUsesLightTheme
    } catch { return $false }
}

function Update-Ui {
    try {
        $look = Get-TrayLook
        $sz = [math]::Max(16, [Windows.Forms.SystemInformation]::SmallIconSize.Width)
        # On a light taskbar the transparent state flips to a dark mark/text so
        # the icon keeps its contrast; alert badges keep their white mark.
        $fgName = $look.fg
        if ($look.bg -eq 'transparent' -and $fgName -eq 'white' -and (Test-LightTaskbar)) { $fgName = 'dark' }
        $bmp = New-TrayBitmap $look.text $TrayColors[$look.bg] $TrayColors[$fgName] $sz
        $h = $bmp.GetHicon()
        $script:Tray.Icon = [Drawing.Icon]::FromHandle($h)
        $bmp.Dispose()
        if ($script:PrevIcon) { [void][DBNative]::DestroyIcon($script:PrevIcon) }
        $script:PrevIcon = $h

        $data = Get-UsageData
        $err = Get-FetchError
        if ($data) {
            $parts = foreach ($k in $Windows.Keys) { '{0} {1}' -f $Short[$k], (Format-Pct (Get-WinInfo 'standard' $k).Pct) }
            $tip = 'Droid · ' + ($parts -join ' · ')
            $core = Get-PoolMax 'core'
            if ($null -ne $core) { $tip += "`nCore up to " + (Format-Pct $core) }
        } elseif ($err) { $tip = 'Droid · ' + $err }
        else { $tip = 'Droid · loading…' }
        if ($tip.Length -gt 63) { $tip = $tip.Substring(0, 63) }
        $script:Tray.Text = $tip
        if ($script:Popup.Visible) {
            # A refresh can change the machine count, so re-apply the content-aware
            # size before repainting (else rows can paint over divider/footer).
            $script:Popup.ClientSize = Get-PopupSize
            $script:Popup.Invalidate()
        }
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
