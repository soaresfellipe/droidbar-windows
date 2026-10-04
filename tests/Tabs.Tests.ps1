# Pester 5 suite for the popup tab registry (Get-TabRegistry), the Computer tab
# summary line (Format-ComputerSummary) and the display-only invariants the
# registry encodes: Computer is a tab but never a $Pools key, and the tray look
# is identical whether or not computer data is loaded.
# Run (pinned, see AGENTS.md):
#   Import-Module Pester -RequiredVersion 5.7.1; Invoke-Pester -Path tests -Output Detailed -CI
Set-StrictMode -Version Latest

BeforeAll {
    $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    Import-Module (Join-Path (Join-Path $RepoRoot 'src') 'droid-bar-lib.psm1') -Force

    function Reset-TabTest {
        InModuleScope droid-bar-lib {
            $script:Data = $null
            $script:LastError = $null
            $script:Computers = $null
            $script:ComputersError = $null
            $script:Updated = $null
        }
        Initialize-LibState -LogPath (Join-Path $TestDrive 'droid-bar.log') -StatePath (Join-Path $TestDrive 'state.json')
        Set-LibConfig -Config @{ thresholds = @(75, 90, 100); notifyPools = @('standard', 'core'); trayPool = 'standard' }
    }
}

Describe 'Get-TabRegistry' {
    It 'defines exactly standard, core and computer, in that order' {
        $registry = Get-TabRegistry
        @($registry.Keys).Count | Should -Be 3
        @($registry.Keys)[0] | Should -Be 'standard'
        @($registry.Keys)[1] | Should -Be 'core'
        @($registry.Keys)[2] | Should -Be 'computer'
    }

    It 'carries a non-empty label and a positive width for every tab' {
        foreach ($id in @((Get-TabRegistry).Keys)) {
            $tab = (Get-TabRegistry)[$id]
            $tab.label | Should -Not -BeNullOrEmpty
            $tab.width | Should -BeGreaterThan 0
        }
    }

    It 'labels standard and core from the $Pools table' {
        $registry = Get-TabRegistry
        $registry['standard'].label | Should -Be $Pools['standard']
        $registry['core'].label | Should -Be $Pools['core']
    }

    It 'labels the computer tab Computer' {
        (Get-TabRegistry)['computer'].label | Should -Be 'Computer'
    }

    It 'keeps Computer out of $Pools (Test-Alerts allowlist must never see it)' {
        $Pools.Contains('computer') | Should -BeFalse
        # The registry tab id and the notification pool key must stay distinct
        # even if a future label changes.
        @((Get-TabRegistry).Keys) | Should -Contain 'computer'
    }
}

Describe 'Format-ComputerSummary' {
    It 'renders total and active counts, e.g. 3 computers · 3 active' {
        $computers = @(
            @{ name = 'a'; status = 'active'; providerType = 'e2b' },
            @{ name = 'b'; status = 'paused'; providerType = 'byom' },
            @{ name = 'c'; status = 'active'; providerType = 'byom' }
        )
        Format-ComputerSummary $computers | Should -Be '3 computers · 2 active'
    }

    It 'uses the singular for a single machine' {
        $computers = @(@{ name = 'a'; status = 'active'; providerType = 'e2b' })
        Format-ComputerSummary $computers | Should -Be '1 computer · 1 active'
    }

    It 'renders an empty or missing list as No computers' {
        Format-ComputerSummary @() | Should -Be 'No computers'
        Format-ComputerSummary $null | Should -Be 'No computers'
    }

    It 'is case-insensitive about the active status' {
        $computers = @(
            @{ name = 'a'; status = 'ACTIVE'; providerType = 'e2b' },
            @{ name = 'b'; status = 'failed'; providerType = 'byom' }
        )
        Format-ComputerSummary $computers | Should -Be '2 computers · 1 active'
    }
}

Describe 'Tray look regression (Computer must not touch the tray)' {
    It 'returns the identical tray look with and without computer data loaded' {
        Reset-TabTest
        Set-FetchResult @{ ok = $true; body = '{"limits": {"standard": {"fiveHour": {"usedPercent": 80, "windowEnd": "2099-01-01T00:00:00.000Z"}}}}' }
        $without = Get-TrayLook

        Set-ComputersResult @{ ok = $true; body = '{"computers": [{"name": "bench01", "providerType": "e2b", "status": "active"}, {"name": "lenovolocal", "providerType": "byom", "status": "paused"}, {"name": "deufs1amkag001", "providerType": "byom", "status": "active"}]}' }
        $with = Get-TrayLook

        $with.text | Should -Be $without.text
        $with.bg | Should -Be $without.bg
        $with.fg | Should -Be $without.fg
        $with.text | Should -Be '80'
        $with.bg | Should -Be 'orange'
    }

    It 'still derives the tray number only from the trayPool windows after computer data loads' {
        Reset-TabTest
        Set-FetchResult @{ ok = $true; body = '{"limits": {"standard": {"fiveHour": {"usedPercent": 10, "windowEnd": "2099-01-01T00:00:00.000Z"}}, "core": {"fiveHour": {"usedPercent": 95, "windowEnd": "2099-01-01T00:00:00.000Z"}}}}' }
        Set-ComputersResult @{ ok = $true; body = '{"computers": [{"name": "bench01", "providerType": "e2b", "status": "failed"}]}' }
        $look = Get-TrayLook
        $look.text | Should -Be '10'
        $look.bg | Should -Be 'dark'
    }
}
