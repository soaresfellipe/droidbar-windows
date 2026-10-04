# Pester 5 suite for the computers data layer (GET /api/v0/computers) in
# src/droid-bar-lib.psm1: defensive parsing, summary building, status colors,
# error mapping/graceful degradation, and the display-only guarantee
# (Test-Alerts never consumes computer data).
# Run (pinned, see AGENTS.md):
#   Import-Module Pester -RequiredVersion 5.7.1; Invoke-Pester -Path tests -Output Detailed -CI
Set-StrictMode -Version Latest

BeforeAll {
    $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    Import-Module (Join-Path (Join-Path $RepoRoot 'src') 'droid-bar-lib.psm1') -Force

    # Reset module state and seed it the way droid-bar.ps1 does at startup.
    function Reset-ComputerTest {
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

    function Set-TestComputers([string]$json) {
        Set-ComputersResult @{ ok = $true; body = $json }
    }

    function Get-TestLog {
        Get-Content (Join-Path $TestDrive 'droid-bar.log') -Raw
    }
}

Describe 'ConvertTo-ComputerList' {
    It 'parses the computers array into name/status/providerType entries' {
        $payload = '{"computers": [{"id": "1", "name": "bench01", "providerType": "e2b", "status": "active", "createdAt": 1791060994007}, {"id": "2", "name": "lenovolocal", "providerType": "byom", "status": "paused"}]}' | ConvertFrom-Json
        $entries = @(ConvertTo-ComputerList $payload)
        $entries.Count | Should -Be 2
        $entries[0]['name'] | Should -Be 'bench01'
        $entries[0]['status'] | Should -Be 'active'
        $entries[0]['providerType'] | Should -Be 'e2b'
        $entries[1]['name'] | Should -Be 'lenovolocal'
        $entries[1]['status'] | Should -Be 'paused'
        $entries[1]['providerType'] | Should -Be 'byom'
    }

    It 'returns an empty list for a null payload' {
        @(ConvertTo-ComputerList $null).Count | Should -Be 0
    }

    It 'returns an empty list when the computers property is missing' {
        $entries = @(ConvertTo-ComputerList ('{}' | ConvertFrom-Json))
        $entries.Count | Should -Be 0
    }

    It 'wraps a single computer object into a one-entry list' {
        $payload = '{"computers": {"name": "bench01", "providerType": "e2b", "status": "active"}}' | ConvertFrom-Json
        $entries = @(ConvertTo-ComputerList $payload)
        $entries.Count | Should -Be 1
        $entries[0]['name'] | Should -Be 'bench01'
    }

    It 'defaults missing fields to empty strings (strict-mode safety)' {
        $payload = '{"computers": [{"id": "1"}, null, "not-a-computer"]}' | ConvertFrom-Json
        $entries = @(ConvertTo-ComputerList $payload)
        $entries.Count | Should -Be 1
        $entries[0]['name'] | Should -Be ''
        $entries[0]['status'] | Should -Be ''
        $entries[0]['providerType'] | Should -Be ''
    }

    It 'returns an empty list when computers is not a collection of objects' {
        $entries = @(ConvertTo-ComputerList ('{"computers": "nope"}' | ConvertFrom-Json))
        $entries.Count | Should -Be 0
    }
}

Describe 'Get-ComputerSummary' {
    It 'computes the total and per-status counts' {
        $computers = @(
            @{ name = 'a'; status = 'active'; providerType = 'e2b' },
            @{ name = 'b'; status = 'paused'; providerType = 'byom' },
            @{ name = 'c'; status = 'active'; providerType = 'byom' }
        )
        $s = Get-ComputerSummary $computers
        $s.Total | Should -Be 3
        $s.Counts['active'] | Should -Be 2
        $s.Counts['paused'] | Should -Be 1
        $s.Counts.Contains('failed') | Should -BeFalse
    }

    It 'returns a zero total for an empty or missing list' {
        (Get-ComputerSummary @()).Total | Should -Be 0
        (Get-ComputerSummary $null).Total | Should -Be 0
        (Get-ComputerSummary $null).Counts.Count | Should -Be 0
    }

    It 'counts unknown statuses under their own name and missing status as unknown' {
        $computers = @(
            @{ name = 'a'; status = 'maintenanced'; providerType = 'e2b' },
            @{ name = 'b'; status = 'active'; providerType = 'e2b' },
            @{ name = 'c'; status = ''; providerType = 'byom' }
        )
        $s = Get-ComputerSummary $computers
        $s.Total | Should -Be 3
        $s.Counts['maintenanced'] | Should -Be 1
        $s.Counts['active'] | Should -Be 1
        $s.Counts['unknown'] | Should -Be 1
    }
}

Describe 'Get-ComputerStatusColor' {
    It 'maps the known statuses to palette names' {
        Get-ComputerStatusColor 'active' | Should -Be 'green'
        Get-ComputerStatusColor 'paused' | Should -Be 'muted'
        Get-ComputerStatusColor 'provisioning' | Should -Be 'orange'
        Get-ComputerStatusColor 'failed' | Should -Be 'red'
    }

    It 'maps unknown statuses safely to gray' {
        Get-ComputerStatusColor 'maintenanced' | Should -Be 'gray'
        Get-ComputerStatusColor '' | Should -Be 'gray'
        Get-ComputerStatusColor $null | Should -Be 'gray'
    }

    It 'is case-insensitive' {
        Get-ComputerStatusColor 'Active' | Should -Be 'green'
        Get-ComputerStatusColor 'FAILED' | Should -Be 'red'
    }
}

Describe 'Set-ComputersResult' {
    It 'parses an ok body into the computers state' {
        Reset-ComputerTest
        Set-TestComputers '{"computers": [{"name": "bench01", "providerType": "e2b", "status": "active"}]}'
        @(Get-Computers).Count | Should -Be 1
        @(Get-Computers)[0]['name'] | Should -Be 'bench01'
        Get-ComputersError | Should -BeNullOrEmpty
    }

    It 'maps invalid JSON to an unexpected-response error and no computers' {
        Reset-ComputerTest
        Set-TestComputers 'not json {'
        Get-ComputersError | Should -Be 'Unexpected computers response'
        Get-Computers | Should -BeNullOrEmpty
    }

    It 'maps a 200 body without the computers property to an unexpected-response error' {
        Reset-ComputerTest
        Set-TestComputers '{"extraUsageBalanceCents": 0}'
        Get-ComputersError | Should -Be 'Unexpected computers response'
        Get-Computers | Should -BeNullOrEmpty
    }

    It 'maps a 200 body with a wrong-typed computers property to an unexpected-response error' {
        Reset-ComputerTest
        Set-TestComputers '{"computers": "nope"}'
        Get-ComputersError | Should -Be 'Unexpected computers response'
        Get-Computers | Should -BeNullOrEmpty
        Reset-ComputerTest
        Set-TestComputers '{"computers": 5}'
        Get-ComputersError | Should -Be 'Unexpected computers response'
        Get-Computers | Should -BeNullOrEmpty
        Reset-ComputerTest
        Set-TestComputers '{"computers": {"name": "bench01"}}'
        Get-ComputersError | Should -Be 'Unexpected computers response'
        Get-Computers | Should -BeNullOrEmpty
    }

    It 'still accepts a legitimate empty computers array on a 200' {
        Reset-ComputerTest
        Set-TestComputers '{"computers": []}'
        Get-ComputersError | Should -BeNullOrEmpty
        @(Get-Computers).Count | Should -Be 0
        Format-ComputerSummary (Get-Computers) | Should -Be 'No computers'
    }

    It 'maps HTTP 401/403 to an invalid-key message' {
        Reset-ComputerTest
        Set-ComputersResult @{ ok = $false; status = 401 }
        Get-ComputersError | Should -Be 'Invalid API key or missing permission'
        Reset-ComputerTest
        Set-ComputersResult @{ ok = $false; status = 403 }
        Get-ComputersError | Should -Be 'Invalid API key or missing permission'
    }

    It 'maps HTTP 400 and 429 to a generic HTTP error' {
        Reset-ComputerTest
        Set-ComputersResult @{ ok = $false; status = 400 }
        Get-ComputersError | Should -Be 'HTTP error 400'
        Reset-ComputerTest
        Set-ComputersResult @{ ok = $false; status = 429 }
        Get-ComputersError | Should -Be 'HTTP error 429'
    }

    It 'maps timeouts and network failures to a reachability error' {
        Reset-ComputerTest
        Set-ComputersResult @{ ok = $false; error = 'timed out' }
        Get-ComputersError | Should -Be "Can't reach Factory"
        Reset-ComputerTest
        Set-ComputersResult @{ }
        Get-ComputersError | Should -Be "Can't reach Factory"
    }

    It 'keeps the limits display working when the computers fetch fails' {
        Reset-ComputerTest
        Set-FetchResult @{ ok = $true; body = '{"limits": {"standard": {"fiveHour": {"usedPercent": 42, "windowEnd": "2099-01-01T00:00:00.000Z"}}}}' }
        Set-ComputersResult @{ ok = $false; status = 400 }
        Get-FetchError | Should -BeNullOrEmpty
        Get-UsageData | Should -Not -BeNullOrEmpty
        (Get-WinInfo 'standard' 'fiveHour').Pct | Should -Be 42
        Get-Computers | Should -BeNullOrEmpty
        Get-ComputersError | Should -Be 'HTTP error 400'
    }

    It 'does not clear a limits error when the computers fetch succeeds' {
        Reset-ComputerTest
        Set-FetchError "Can't reach Factory"
        Set-TestComputers '{"computers": []}'
        Get-FetchError | Should -Be "Can't reach Factory"
        @(Get-Computers).Count | Should -Be 0
        Get-ComputersError | Should -BeNullOrEmpty
    }

    It 'never logs key material on a computers failure' {
        Reset-ComputerTest
        Set-ComputersResult @{ ok = $false; status = 400; error = 'The remote server returned an error: (400) Bad Request.' }
        $log = Get-TestLog
        $log | Should -Match 'computers'
        $log | Should -Not -Match 'fk-'
        $log | Should -Not -Match 'Bearer'
    }
}

Describe 'Test-Alerts never consumes computer data' {
    It 'ignores computer data even when it is loaded and the pool list names computer' {
        Reset-ComputerTest
        Set-FetchResult @{ ok = $true; body = '{"limits": {"standard": {"fiveHour": {"usedPercent": 80, "windowEnd": "2099-01-01T00:00:00.000Z"}}}}' }
        Set-TestComputers '{"computers": [{"name": "bench01", "providerType": "e2b", "status": "active"}, {"name": "lenovolocal", "providerType": "byom", "status": "paused"}, {"name": "deufs1amkag001", "providerType": "byom", "status": "active"}]}'
        Set-LibConfig -Config @{ thresholds = @(75, 90, 100); notifyPools = @('standard', 'core', 'computer'); trayPool = 'standard' }
        $r = Test-Alerts
        $r.Messages.Count | Should -Be 1
        $r.Messages[0] | Should -BeLike '*Standard*5-hour usage*'
        $r.Messages[0] | Should -Not -BeLike '*computer*'
        $state = ConvertTo-Hashtable (Get-Content (Join-Path $TestDrive 'state.json') -Raw | ConvertFrom-Json)
        ($state.Keys | Where-Object { $_ -like 'computer*' }).Count | Should -Be 0
        # The computers state itself is untouched by the alert pass.
        @(Get-Computers).Count | Should -Be 3
    }
}

Describe 'mock parity (samples/mock.json)' {
    BeforeAll {
        $MockJson = Get-Content (Join-Path $RepoRoot 'samples' 'mock.json') -Raw
        $MockPayload = $MockJson | ConvertFrom-Json
    }

    It 'has a computers array with the real-API field shape (3 machines, active + paused)' {
        $entries = @(ConvertTo-ComputerList $MockPayload)
        $entries.Count | Should -Be 3
        foreach ($e in $entries) {
            $e['name'] | Should -Not -BeNullOrEmpty
            $e['status'] | Should -Not -BeNullOrEmpty
            $e['providerType'] | Should -Not -BeNullOrEmpty
        }
        $statuses = @($entries | ForEach-Object { $_['status'] })
        $statuses | Should -Contain 'active'
        $statuses | Should -Contain 'paused'
    }

    It 'has secondsRemaining on every limit window (real /api/billing/limits parity)' {
        foreach ($pool in @('standard', 'core')) {
            foreach ($w in @('fiveHour', 'weekly', 'monthly')) {
                $win = Get-MemberValue (Get-MemberValue (Get-MemberValue $MockPayload 'limits') $pool) $w
                Get-MemberValue $win 'secondsRemaining' | Should -Not -BeNullOrEmpty
            }
        }
    }

    It 'loads through the same state accessors the -Mock path uses' {
        Reset-ComputerTest
        Set-FetchResult @{ ok = $true; body = $MockJson }
        Set-ComputersResult @{ ok = $true; body = $MockJson }
        @(Get-Computers).Count | Should -Be 3
        Get-ComputersError | Should -BeNullOrEmpty
        Get-UsageData | Should -Not -BeNullOrEmpty
        (Get-ComputerSummary (Get-Computers)).Total | Should -Be 3
    }
}
