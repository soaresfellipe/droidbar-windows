# Installs the repo's git hooks into this clone.
#
#   pwsh -File tools/Install-Hooks.ps1
#
# Sets core.hooksPath to .githooks, which git then picks up automatically for
# every future commit in this clone. Safe to re-run (idempotent). Hooks cannot
# be committed into .git/hooks, so this is how the pre-commit gate reaches a
# contributor's machine.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
Push-Location $repoRoot
try {
    if (-not (Test-Path (Join-Path $repoRoot '.githooks/pre-commit'))) {
        throw '.githooks/pre-commit is missing; cannot install hooks'
    }
    git config core.hooksPath .githooks
    if ($LASTEXITCODE -ne 0) { throw 'git config core.hooksPath failed' }
    Write-Host 'installed: core.hooksPath = .githooks'
    Write-Host 'the pre-commit gate now runs parse, lint, largefiles and secrets before each commit'
} finally {
    Pop-Location
}
