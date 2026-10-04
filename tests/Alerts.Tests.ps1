# Pester 5 suite for Test-Alerts (pure threshold computation) in src/droid-bar-lib.psm1.
# Test-Alerts returns the notification messages as data; the GUI layer (droid-bar.ps1
# Show-Alerts) turns them into the tray balloon.
# Run (pinned, see AGENTS.md):
#   Import-Module Pester -RequiredVersion 5.7.1; Invoke-Pester -Path tests -Output Detailed -CI
Set-StrictMode -Version Latest

BeforeAll {
    $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    Import-Module (Join-Path (Join-Path $RepoRoot 'src') 'droid-bar-lib.psm1') -Force

    # Reset module state and seed it the way droid-bar.ps1 does at startup.
    function Set-AlertTestState {
        param([string]$DataJson, $NotifyPools = @('standard', 'core'))
        Initialize-LibState -StatePath (Join-Path $TestDrive 'state.json')
        # Start from an empty alert state so tests never depend on execution order.
        InModuleScope droid-bar-lib { $script:Alerts = @{} }
        Set-LibConfig -Config @{ thresholds = @(75, 90, 100); notifyPools = $NotifyPools; trayPool = 'standard' }
        if ($DataJson) { Set-FetchResult @{ ok = $true; body = $DataJson } }
    }

    function Get-SavedState {
        $raw = Get-Content (Join-Path $TestDrive 'state.json') -Raw
        ConvertTo-Hashtable ($raw | ConvertFrom-Json)
    }
}

Describe 'Test-Alerts' {
    It 'fires a first crossing message and records the level in state.json' {
        Set-AlertTestState -DataJson '{"limits": {"standard": {"fiveHour": {"usedPercent": 80, "windowEnd": "2099-01-01T00:00:00.000Z"}}}}'
        $r = Test-Alerts
        $r.Messages.Count | Should -Be 1
        $r.Messages[0] | Should -BeLike '*Standard*5-hour usage*80%*'
        $r.Worst | Should -Be 75
        (Get-SavedState)['standard.fiveHour'] | Should -Be 75
    }

    It 'fires exactly at the threshold (>= boundary)' {
        Set-AlertTestState -DataJson '{"limits": {"standard": {"fiveHour": {"usedPercent": 75, "windowEnd": "2099-01-01T00:00:00.000Z"}}}}'
        $r = Test-Alerts
        $r.Messages.Count | Should -Be 1
        $r.Worst | Should -Be 75
    }

    It 'does not repeat a notification while the level is unchanged' {
        Set-AlertTestState -DataJson '{"limits": {"standard": {"fiveHour": {"usedPercent": 80, "windowEnd": "2099-01-01T00:00:00.000Z"}}}}'
        $first = Test-Alerts
        $first.Messages.Count | Should -Be 1
        $second = Test-Alerts
        $second.Messages.Count | Should -Be 0
    }

    It 'escalates to the next threshold with a new message' {
        Set-AlertTestState -DataJson '{"limits": {"standard": {"fiveHour": {"usedPercent": 80, "windowEnd": "2099-01-01T00:00:00.000Z"}}}}'
        [void](Test-Alerts)
        Set-FetchResult @{ ok = $true; body = '{"limits": {"standard": {"fiveHour": {"usedPercent": 95, "windowEnd": "2099-01-01T00:00:00.000Z"}}}}' }
        $r = Test-Alerts
        $r.Messages.Count | Should -Be 1
        $r.Worst | Should -Be 90
        (Get-SavedState)['standard.fiveHour'] | Should -Be 90
    }

    It 'announces availability again after a 100% window resets' {
        Set-AlertTestState -DataJson '{"limits": {"standard": {"fiveHour": {"usedPercent": 100, "windowEnd": "2099-01-01T00:00:00.000Z"}}}}'
        $maxed = Test-Alerts
        $maxed.Worst | Should -Be 100
        $maxed.Messages[0] | Should -BeLike '*limit reached*'

        Set-FetchResult @{ ok = $true; body = '{"limits": {"standard": {"fiveHour": {"usedPercent": 50, "windowEnd": "2099-01-01T00:00:00.000Z"}}}}' }
        $r = Test-Alerts
        $r.Messages.Count | Should -Be 1
        $r.Messages[0] | Should -BeLike '*limit available again*'
        $r.Worst | Should -Be 0
        (Get-SavedState)['standard.fiveHour'] | Should -Be 0
    }

    It 'resets silently when usage drops more than 5 points below the level' {
        Set-AlertTestState -DataJson '{"limits": {"standard": {"fiveHour": {"usedPercent": 75, "windowEnd": "2099-01-01T00:00:00.000Z"}}}}'
        [void](Test-Alerts)

        Set-FetchResult @{ ok = $true; body = '{"limits": {"standard": {"fiveHour": {"usedPercent": 60, "windowEnd": "2099-01-01T00:00:00.000Z"}}}}' }
        $r = Test-Alerts
        $r.Messages.Count | Should -Be 0
        $r.Worst | Should -Be 0
        (Get-SavedState)['standard.fiveHour'] | Should -Be 0
    }

    It 'stays silent below all thresholds' {
        Set-AlertTestState -DataJson '{"limits": {"standard": {"fiveHour": {"usedPercent": 10, "windowEnd": "2099-01-01T00:00:00.000Z"}}}}'
        $r = Test-Alerts
        $r.Messages.Count | Should -Be 0
        $r.Worst | Should -Be 0
    }

    It 'checks every window of every notify pool' {
        Set-AlertTestState -DataJson '{"limits": {"standard": {"fiveHour": {"usedPercent": 80, "windowEnd": "2099-01-01T00:00:00.000Z"}}, "core": {"weekly": {"usedPercent": 95, "windowEnd": "2099-01-08T00:00:00.000Z"}}}}'
        $r = Test-Alerts
        $r.Messages.Count | Should -Be 2
        $r.Messages[0] | Should -BeLike '*Standard*5-hour usage*'
        $r.Messages[1] | Should -BeLike '*Droid Core*Weekly usage*'
        $r.Worst | Should -Be 90
        $state = Get-SavedState
        $state['standard.fiveHour'] | Should -Be 75
        $state['core.weekly'] | Should -Be 90
    }

    It 'never alerts for pools outside the registry (computer is display-only)' {
        Set-AlertTestState -NotifyPools @('standard', 'computer') -DataJson '{"limits": {"computer": {"fiveHour": {"usedPercent": 100, "windowEnd": "2099-01-01T00:00:00.000Z"}}, "standard": {"fiveHour": {"usedPercent": 10, "windowEnd": "2099-01-01T00:00:00.000Z"}}}}'
        $r = Test-Alerts
        $r.Messages.Count | Should -Be 0
        $r.Worst | Should -Be 0
        $state = Get-SavedState
        $state.Keys | Should -Not -Contain 'computer.fiveHour'
        # @() so the assertion holds under Set-StrictMode: Where-Object returns
        # $null (not an empty collection) when nothing matches, and .Count on
        # $null is a terminating error there.
        @($state.Keys | Where-Object { $_ -like 'computer*' }).Count | Should -Be 0
    }
}
