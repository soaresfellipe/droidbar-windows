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
# Get-TrayLook (module) returns palette names; map them to the popup's colors.
$TrayColors = @{
    gray   = [Drawing.Color]::FromArgb(60, 60, 60)
    dark   = [Drawing.Color]::FromArgb(38, 38, 38)
    orange = $C.Orange
    red    = $C.Red
    white  = [Drawing.Color]::White
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
    # Same tray pattern, brand glyph instead of the usage number: rounded square
    # with the semantic fill (dark/orange/red tracks the highest Standard
    # percentage) and the white Factory mark centered. The no-data ('…') and
    # error ('!') states keep drawing as text; the hover tooltip and the popup
    # carry the exact percentages.
    $g.FillPath((New-Object Drawing.SolidBrush($bg)), (New-RoundPath (New-Object Drawing.RectangleF(0, 0, ($sz - 1), ($sz - 1))) ($sz / 5)))
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
    $h = $sz * 0.62
    $w = $h * 67 / 65   # mark viewBox aspect (67x65)
    $g.InterpolationMode = 'HighQualityBicubic'
    $g.DrawImage((Get-MarkBitmap), [single](($sz - $w) / 2), [single](($sz - $h) / 2), [single]$w, [single]$h)
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

function Update-Ui {
    try {
        $look = Get-TrayLook
        $sz = [math]::Max(16, [Windows.Forms.SystemInformation]::SmallIconSize.Width)
        $bmp = New-TrayBitmap $look.text $TrayColors[$look.bg] $TrayColors[$look.fg] $sz
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
