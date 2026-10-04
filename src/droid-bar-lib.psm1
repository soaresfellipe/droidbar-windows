#Requires -Version 5.1
<#
  Droid Bar - GUI-free helper library.

  droid-bar.ps1 imports this module from $PSScriptRoot\src at startup; the Pester
  suite (tests/) imports it directly so the helpers can be unit-tested on any host,
  including pwsh on Linux. The module must therefore stay free of
  System.Windows.Forms / System.Drawing references and must not touch %APPDATA%
  (or any other Windows-only resource) at import time.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------- module state
# The module owns the app's data-layer state; droid-bar.ps1 reads and writes it
# through the exported accessors so the GUI layer never touches module internals.
$script:Data      = $null   # parsed GET /api/billing/limits payload
$script:Cfg       = @{}     # app config slice (thresholds, notifyPools, trayPool)
$script:Alerts    = @{}     # per-window alert levels, persisted to state.json
$script:LastError = $null
$script:Updated   = $null
$script:Computers = $null   # parsed GET /api/v0/computers list (display-only)
$script:ComputersError = $null
$script:LogPath   = $null
$script:StatePath = $null

# Static lookup tables shared by the GUI (tab labels, tooltip) and the helpers.
$Pools   = [ordered]@{ standard = 'Standard'; core = 'Droid Core' }
$Windows = [ordered]@{ fiveHour = '5-hour usage'; weekly = 'Weekly usage'; monthly = 'Monthly usage' }
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSScriptAnalyzer', 'PSUseDeclaredVarsMoreThanAssignments', Justification = '$Short is exported for the importing script (tray tooltip); nothing inside the module reads it.')]
$Short   = @{ fiveHour = '5h'; weekly = 'week'; monthly = 'month' }

function Write-Log([string]$msg) {
    try {
        if (-not $script:LogPath) { return }
        if ((Test-Path $script:LogPath) -and (Get-Item $script:LogPath).Length -gt 512KB) { Remove-Item $script:LogPath }
        Add-Content -Path $script:LogPath -Value ("{0:yyyy-MM-dd HH:mm:ss}  {1}" -f (Get-Date), $msg) -Encoding UTF8
    } catch { }
}

function ConvertTo-Hashtable($obj) {
    $h = @{}
    if ($null -ne $obj) { foreach ($p in $obj.PSObject.Properties) { $h[$p.Name] = $p.Value } }
    return $h
}

# Strict-mode-safe member access: returns $null when the property (or dictionary key)
# does not exist instead of throwing. Required because Set-StrictMode turns references
# to non-existent properties into terminating errors, and API/mock JSON is dynamic.
function Get-MemberValue($obj, [string]$name) {
    if ($null -eq $obj) { return $null }
    if ($obj -is [System.Collections.IDictionary]) {
        if ($obj.Contains($name)) { return $obj[$name] } else { return $null }
    }
    $p = $obj.PSObject.Properties[$name]
    if ($null -ne $p) { return $p.Value }
    return $null
}

function Get-AlertState {
    if ($script:StatePath -and (Test-Path $script:StatePath)) {
        try { return ConvertTo-Hashtable (Get-Content $script:StatePath -Raw | ConvertFrom-Json) } catch { }
    }
    return @{}
}

# ---------------------------------------------------------------- data helpers

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
    # Dynamic JSON lookups go through Get-MemberValue so missing pool/window keys
    # (e.g. limits.notAvailable) yield $null instead of a strict-mode property error.
    $limits = Get-MemberValue $script:Data 'limits'
    if ($null -eq $limits) { return $info }
    $p = Get-MemberValue $limits $pool
    if ($null -eq $p) { return $info }
    $w = Get-MemberValue $p $key
    if ($null -eq $w) { return $info }
    $pct = 0.0
    $used = Get-MemberValue $w 'usedPercent'
    if ($null -ne $used) { $pct = [double]$used }
    $end = ConvertTo-LocalTime (Get-MemberValue $w 'windowEnd')
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

function Set-FetchResult($res) {
    if (Get-MemberValue $res 'ok') {
        try {
            $script:Data = $res.body | ConvertFrom-Json
            $script:LastError = $null
            $script:Updated = Get-Date
            $limits = Get-MemberValue $script:Data 'limits'
            if (Get-MemberValue $limits 'notAvailable') { $script:LastError = 'Limits unavailable for this account' }
        } catch {
            $script:LastError = 'Unexpected API response'
            Write-Log "json: $_ :: $(Get-MemberValue $res 'body')"
        }
    } elseif ((Get-MemberValue $res 'status') -eq 401 -or (Get-MemberValue $res 'status') -eq 403) {
        $script:LastError = 'Invalid API key or missing permission'
    } elseif (Get-MemberValue $res 'status') {
        $script:LastError = "HTTP error $(Get-MemberValue $res 'status')"
    } else {
        $script:LastError = "Can't reach Factory"
    }
    if ($script:LastError) { Write-Log "$($script:LastError) $(Get-MemberValue $res 'error')" }
}

# ---------------------------------------------------------------- computers (display-only)

# Defensive parse of a GET /api/v0/computers payload into display entries
# (name, status, providerType). Never throws: missing/ malformed data yields an
# empty list, and non-object entries are skipped.
function ConvertTo-ComputerList($payload) {
    $list = New-Object System.Collections.Generic.List[hashtable]
    if ($null -eq $payload) { return $list }
    $computers = Get-MemberValue $payload 'computers'
    if ($null -eq $computers) { return $list }
    foreach ($c in @($computers)) {
        if ($null -eq $c) { continue }
        $isEntry = ($c -is [System.Collections.IDictionary]) -or ($c -is [System.Management.Automation.PSCustomObject])
        if (-not $isEntry) { continue }
        # String-coerce via Get-MemberValue so missing fields become '' instead of
        # a strict-mode property error.
        $list.Add(@{
            name         = "$(Get-MemberValue $c 'name')"
            status       = "$(Get-MemberValue $c 'status')"
            providerType = "$(Get-MemberValue $c 'providerType')"
        })
    }
    return $list
}

# Builds the Computer tab summary as data: Total plus per-status Counts
# (unknown/missing statuses count under their own name / 'unknown').
function Get-ComputerSummary($Computers) {
    $counts = [ordered]@{}
    $total = 0
    foreach ($c in @($Computers)) {
        if ($null -eq $c) { continue }
        $total++
        $st = "$(Get-MemberValue $c 'status')".ToLowerInvariant()
        if ($st -eq '') { $st = 'unknown' }
        if (-not $counts.Contains($st)) { $counts[$st] = 0 }
        $counts[$st] = $counts[$st] + 1
    }
    return @{ Total = $total; Counts = $counts }
}

# Maps a computer status to a palette name (the GUI maps palette names to
# System.Drawing colors, same contract as Get-TrayLook). Unknown statuses are
# gray so a new server-side status can never break rendering.
function Get-ComputerStatusColor([string]$status) {
    switch ($status) {
        'active'       { return 'green' }
        'paused'       { return 'muted' }
        'provisioning' { return 'orange' }
        'failed'       { return 'red' }
        default        { return 'gray' }
    }
}

# Mirrors Set-FetchResult for the computers endpoint. Errors here are contained:
# they never touch the limits state, so the limits display keeps working and the
# Computer tab degrades to an unavailable state. Never logs the API key (the
# module never receives it; only generic error text reaches the log).
function Set-ComputersResult($res) {
    $script:Computers = $null
    $script:ComputersError = $null
    if (Get-MemberValue $res 'ok') {
        try {
            $payload = $res.body | ConvertFrom-Json
            $script:Computers = ConvertTo-ComputerList $payload
        } catch {
            $script:ComputersError = 'Unexpected computers response'
            Write-Log "computers json: $_"
        }
    } elseif ((Get-MemberValue $res 'status') -eq 401 -or (Get-MemberValue $res 'status') -eq 403) {
        $script:ComputersError = 'Invalid API key or missing permission'
    } elseif (Get-MemberValue $res 'status') {
        $script:ComputersError = "HTTP error $(Get-MemberValue $res 'status')"
    } else {
        $script:ComputersError = "Can't reach Factory"
    }
    if ($script:ComputersError) { Write-Log "computers: $($script:ComputersError) $(Get-MemberValue $res 'error')" }
}

function Get-Computers { return $script:Computers }
function Get-ComputersError { return $script:ComputersError }

# ---------------------------------------------------------------- alerts

# Computes threshold crossings for every window of every notify pool and updates
# the persisted alert state. Returns the notification texts as data (Messages plus
# the highest crossed threshold); droid-bar.ps1's Show-Alerts turns them into the
# tray balloon — the module itself never touches WinForms.
function Test-Alerts {
    # Config lookups go through Get-MemberValue so a config.json missing a key
    # degrades to "no thresholds / no pools" instead of a strict-mode error.
    $thresholds = @(Get-MemberValue $script:Cfg 'thresholds' | ForEach-Object { [double]$_ } | Sort-Object)
    $msgs = New-Object System.Collections.Generic.List[string]
    $worst = 0
    foreach ($pool in @(Get-MemberValue $script:Cfg 'notifyPools')) {
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
    try { $script:Alerts | ConvertTo-Json | Set-Content -Path $script:StatePath -Encoding UTF8 } catch { }

    return @{ Messages = $msgs; Worst = $worst }
}

# ---------------------------------------------------------------- tray look

# Returns the tray icon look as plain data (palette names, no GDI types); the GUI
# script maps gray/dark/orange/red/white to its System.Drawing colors.
function Get-TrayLook {
    $pool = Get-MemberValue $script:Cfg 'trayPool'
    $max = Get-PoolMax $pool
    if (-not $script:Data -or $null -eq $max) {
        $t = if ($script:LastError) { '!' } else { '…' }
        return @{ text = $t; bg = 'gray'; fg = 'white' }
    }
    $bg = 'dark'
    if ($max -ge 90) { $bg = 'red' } elseif ($max -ge 75) { $bg = 'orange' }
    return @{ text = ('{0:0}' -f [math]::Min(100, [math]::Floor($max))); bg = $bg; fg = 'white' }
}

# ---------------------------------------------------------------- init / state accessors

# Called once by droid-bar.ps1 at startup with the app's data-file paths. Also
# (re)loads the persisted alert state so Test-Alerts continues where the last run
# left off.
function Initialize-LibState {
    param([string]$LogPath, [string]$StatePath)
    $script:LogPath = $LogPath
    $script:StatePath = $StatePath
    $script:Alerts = Get-AlertState
}

function Set-LibConfig($Config) { $script:Cfg = $Config }
function Get-UsageData { return $script:Data }
function Get-FetchError { return $script:LastError }
function Set-FetchError([string]$msg) { $script:LastError = $msg }
function Get-LastUpdated { return $script:Updated }
function Set-LastUpdated($t) { $script:Updated = $t }

Export-ModuleMember -Function Write-Log, ConvertTo-Hashtable, Get-MemberValue, Get-AlertState, ConvertTo-LocalTime, Get-WinInfo, Get-PoolMax, Format-Pct, Format-Remaining, Set-FetchResult, Test-Alerts, Get-TrayLook, ConvertTo-ComputerList, Get-ComputerSummary, Get-ComputerStatusColor, Set-ComputersResult, Get-Computers, Get-ComputersError, Initialize-LibState, Set-LibConfig, Get-UsageData, Get-FetchError, Set-FetchError, Get-LastUpdated, Set-LastUpdated -Variable Pools, Windows, Short
