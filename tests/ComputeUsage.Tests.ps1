# Pester 5 suite for the compute-usage data layer (GET
# /api/organization/compute-usage) in src/droid-bar-lib.psm1: defensive
# parsing, the Managed Computers Usage display math (percent + hours), error
# mapping/graceful degradation, and the display-only guarantee (failures here
# never touch the limits or computers state).
# Run (pinned, see AGENTS.md):
#   Import-Module Pester -RequiredVersion 5.7.1; Invoke-Pester -Path tests -Output Detailed -CI
Set-StrictMode -Version Latest

BeforeAll {
    $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    Import-Module (Join-Path (Join-Path $RepoRoot 'src') 'droid-bar-lib.psm1') -Force

    # Reset module state and seed it the way droid-bar.ps1 does at startup.
    function Reset-ComputeTest {
        InModuleScope droid-bar-lib {
            $script:Data = $null
            $script:LastError = $null
            $script:Computers = $null
            $script:ComputersError = $null
            $script:ComputeUsage = $null
            $script:ComputeUsageError = $null
            $script:Updated = $null
        }
        Initialize-LibState -LogPath (Join-Path $TestDrive 'droid-bar.log') -StatePath (Join-Path $TestDrive 'state.json')
        Set-LibConfig -Config @{ thresholds = @(75, 90, 100); notifyPools = @('standard', 'core'); trayPool = 'standard' }
    }

    function Set-TestComputeUsage([string]$json) {
        Set-ComputeUsageResult @{ ok = $true; body = $json }
    }

    function Get-TestLog {
        Get-Content (Join-Path $TestDrive 'droid-bar.log') -Raw
    }
}

Describe 'Set-ComputeUsageResult' {
    It 'parses an ok body into the compute usage state' {
        Reset-ComputeTest
        Set-TestComputeUsage '{"orgUsageMs": 53210309, "limitMs": 288000000, "periodEnd": "2099-11-03T08:00:00.000Z"}'
        $u = Get-ComputeUsage
        $u | Should -Not -BeNullOrEmpty
        $u['UsedMs'] | Should -Be 53210309
        $u['LimitMs'] | Should -Be 288000000
        $u['End'] | Should -Not -BeNullOrEmpty
        Get-ComputeUsageError | Should -BeNullOrEmpty
    }

    It 'tolerates a missing periodEnd (only the bar fields are required)' {
        Reset-ComputeTest
        Set-TestComputeUsage '{"orgUsageMs": 1000, "limitMs": 2000}'
        Get-ComputeUsageError | Should -BeNullOrEmpty
        (Get-ComputeUsage)['End'] | Should -BeNullOrEmpty
    }

    It 'maps a 200 body without orgUsageMs or limitMs to an unexpected-response error' {
        Reset-ComputeTest
        Set-TestComputeUsage '{"periodEnd": "2099-11-03T08:00:00.000Z"}'
        Get-ComputeUsageError | Should -Be 'Unexpected compute usage response'
        Get-ComputeUsage | Should -BeNullOrEmpty
        Reset-ComputeTest
        Set-TestComputeUsage '{"orgUsageMs": 1000}'
        Get-ComputeUsageError | Should -Be 'Unexpected compute usage response'
        Reset-ComputeTest
        Set-TestComputeUsage '{"limitMs": 2000}'
        Get-ComputeUsageError | Should -Be 'Unexpected compute usage response'
        Reset-ComputeTest
        Set-TestComputeUsage '{}'
        Get-ComputeUsageError | Should -Be 'Unexpected compute usage response'
    }

    It 'maps invalid JSON to an unexpected-response error and no state' {
        Reset-ComputeTest
        Set-TestComputeUsage 'not json {'
        Get-ComputeUsageError | Should -Be 'Unexpected compute usage response'
        Get-ComputeUsage | Should -BeNullOrEmpty
    }

    It 'maps HTTP 401/403 to an invalid-key message' {
        Reset-ComputeTest
        Set-ComputeUsageResult @{ ok = $false; status = 401 }
        Get-ComputeUsageError | Should -Be 'Invalid API key or missing permission'
        Reset-ComputeTest
        Set-ComputeUsageResult @{ ok = $false; status = 403 }
        Get-ComputeUsageError | Should -Be 'Invalid API key or missing permission'
    }

    It 'maps HTTP 400 and 429 to a generic HTTP error' {
        Reset-ComputeTest
        Set-ComputeUsageResult @{ ok = $false; status = 400 }
        Get-ComputeUsageError | Should -Be 'HTTP error 400'
        Reset-ComputeTest
        Set-ComputeUsageResult @{ ok = $false; status = 429 }
        Get-ComputeUsageError | Should -Be 'HTTP error 429'
    }

    It 'maps timeouts and network failures to a reachability error' {
        Reset-ComputeTest
        Set-ComputeUsageResult @{ ok = $false; error = 'timed out' }
        Get-ComputeUsageError | Should -Be "Can't reach Factory"
        Reset-ComputeTest
        Set-ComputeUsageResult @{ }
        Get-ComputeUsageError | Should -Be "Can't reach Factory"
    }

    It 'never clears the limits or computers state when the compute usage fetch fails' {
        Reset-ComputeTest
        Set-FetchResult @{ ok = $true; body = '{"limits": {"standard": {"fiveHour": {"usedPercent": 42, "windowEnd": "2099-01-01T00:00:00.000Z"}}}}' }
        Set-ComputersResult @{ ok = $true; body = '{"computers": [{"name": "bench01", "providerType": "e2b", "status": "active"}]}' }
        Set-ComputeUsageResult @{ ok = $false; status = 500 }
        Get-FetchError | Should -BeNullOrEmpty
        Get-ComputersError | Should -BeNullOrEmpty
        @(Get-Computers).Count | Should -Be 1
        (Get-WinInfo 'standard' 'fiveHour').Pct | Should -Be 42
        Get-ComputeUsage | Should -BeNullOrEmpty
        Get-ComputeUsageError | Should -Be 'HTTP error 500'
    }

    It 'does not clear a limits error when the compute usage fetch succeeds' {
        Reset-ComputeTest
        Set-FetchError "Can't reach Factory"
        Set-TestComputeUsage '{"orgUsageMs": 1000, "limitMs": 2000}'
        Get-FetchError | Should -Be "Can't reach Factory"
        Get-ComputeUsageError | Should -BeNullOrEmpty
    }

    It 'never logs key material on a compute usage failure' {
        Reset-ComputeTest
        Set-ComputeUsageResult @{ ok = $false; status = 400; error = 'The remote server returned an error: (400) Bad Request.' }
        $log = Get-TestLog
        $log | Should -Match 'compute usage'
        $log | Should -Not -Match 'fk-'
        $log | Should -Not -Match 'Bearer'
    }
}

Describe 'Get-ComputeUsageInfo' {
    It 'computes the percent and exposes the millisecond fields and reset time' {
        Reset-ComputeTest
        Set-TestComputeUsage '{"orgUsageMs": 53210309, "limitMs": 288000000, "periodEnd": "2099-11-03T08:00:00.000Z"}'
        $i = Get-ComputeUsageInfo
        [math]::Round($i.Pct, 4) | Should -Be 18.4758
        $i.UsedMs | Should -Be 53210309
        $i.LimitMs | Should -Be 288000000
        $i.End | Should -Not -BeNullOrEmpty
    }

    It 'formats through Format-Pct to the dashboard floor behavior (14.78h of 80h -> 18%)' {
        Reset-ComputeTest
        Set-TestComputeUsage '{"orgUsageMs": 53210309, "limitMs": 288000000}'
        Format-Pct (Get-ComputeUsageInfo).Pct | Should -Be '18%'
    }

    It 'hides the card (null Pct) when the quota is missing, zero or negative' {
        Reset-ComputeTest
        Set-TestComputeUsage '{"orgUsageMs": 1000, "limitMs": 0}'
        (Get-ComputeUsageInfo).Pct | Should -BeNull
        Reset-ComputeTest
        Set-TestComputeUsage '{"orgUsageMs": 1000, "limitMs": -5}'
        (Get-ComputeUsageInfo).Pct | Should -BeNull
    }

    It 'returns all-null info when nothing was fetched yet' {
        Reset-ComputeTest
        $i = Get-ComputeUsageInfo
        $i.Pct | Should -BeNull
        $i.UsedMs | Should -BeNull
        $i.LimitMs | Should -BeNull
        $i.End | Should -BeNull
    }

    It 'clamps negative usage to zero percent instead of a negative bar' {
        Reset-ComputeTest
        InModuleScope droid-bar-lib { $script:ComputeUsage = @{ UsedMs = -100.0; LimitMs = 200.0; End = $null } }
        (Get-ComputeUsageInfo).Pct | Should -Be 0
        Format-Pct (Get-ComputeUsageInfo).Pct | Should -Be '0%'
    }

    It 'treats missing orgUsageMs on a valid quota as zero usage' {
        Reset-ComputeTest
        Set-TestComputeUsage '{"limitMs": 288000000}'
        # Missing usage field never parses (shape check), but the info path also
        # defends against a zeroed UsedMs reaching it.
        (Get-ComputeUsageInfo).Pct | Should -BeNull
        InModuleScope droid-bar-lib { $script:ComputeUsage = @{ UsedMs = $null; LimitMs = 288000000.0; End = $null } }
        (Get-ComputeUsageInfo).Pct | Should -Be 0
        Format-Pct (Get-ComputeUsageInfo).Pct | Should -Be '0%'
    }
}

Describe 'Format-ComputeHours' {
    It 'renders dashboard-style hours with one decimal' {
        Format-ComputeHours 53210309 | Should -Be '14.8h'
        Format-ComputeHours 288000000 | Should -Be '80.0h'
        Format-ComputeHours 3600000 | Should -Be '1.0h'
        Format-ComputeHours 0 | Should -Be '0.0h'
    }

    It 'renders an em dash for missing values' {
        Format-ComputeHours $null | Should -Be '—'
    }
}

Describe 'mock parity (samples/mock.json)' {
    BeforeAll {
        $MockJson = Get-Content (Join-Path $RepoRoot 'samples' 'mock.json') -Raw
        $MockPayload = $MockJson | ConvertFrom-Json
    }

    It 'has the compute-usage fields at the top level (real-API shape parity: one body feeds all three endpoints)' {
        Get-MemberValue $MockPayload 'orgUsageMs' | Should -Not -BeNullOrEmpty
        Get-MemberValue $MockPayload 'limitMs' | Should -Not -BeNullOrEmpty
        Get-MemberValue $MockPayload 'periodEnd' | Should -Not -BeNullOrEmpty
    }

    It 'loads through the same state accessors the -Mock path uses' {
        Reset-ComputeTest
        Set-ComputeUsageResult @{ ok = $true; body = $MockJson }
        Get-ComputeUsageError | Should -BeNullOrEmpty
        $i = Get-ComputeUsageInfo
        $i.Pct | Should -BeGreaterThan 0
        $i.LimitMs | Should -Be 288000000
        Format-ComputeHours $i.UsedMs | Should -Be '14.8h'
        Format-ComputeHours $i.LimitMs | Should -Be '80.0h'
    }
}
