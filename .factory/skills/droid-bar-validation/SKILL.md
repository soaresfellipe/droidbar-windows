---
name: droid-bar-validation
description: Validate a change to the Droid Bar tray app without a Windows GUI - run the quality gates, render popup tabs to PNG from mock data, and verify the Computer tab and regression surfaces.
---

# Droid Bar validation

Use this when you change `droid-bar.ps1`, `src/droid-bar-lib.psm1`, or anything
that affects rendering, polling, or the Computer tab. It is the agent-facing
version of the protocol in `AGENTS.md`.

## The one command

Every gate lives in `tools/RepoChecks.ps1` (shared by CI and the pre-commit hook):

```powershell
pwsh -File tools/RepoChecks.ps1 -Check all
```

Individual gates: `parse`, `lint`, `format`, `largefiles`, `secrets`, `tests`,
`coverage`. All are PowerShell 5.1-compatible; the `format` and `coverage` gates
need pwsh 7 plus PSScriptAnalyzer / Pester 5.7.1.

## Rules that break CI

- PowerShell 5.1 syntax only. No `?.`, no `??`, no ternary, no `&&`/`||`
  between statements. The `parse` gate runs on the 5.1 host for this reason.
- Pure logic goes in `src/droid-bar-lib.psm1`; GUI, polling and P/Invoke stay in
  `droid-bar.ps1`. The module must never load WinForms or `System.Drawing` - it
  is imported by the Linux/macOS test run.
- Read dynamic JSON members with `Get-MemberValue`, never by direct property
  access: `Set-StrictMode -Version Latest` turns a missing member into a
  terminating error.
- `@()` around a pipeline whose result you call `.Count` on. Under strict mode
  `Where-Object` returns `$null`, not an empty collection, when nothing matches.
- Do not call Pester with `-CI` from inside a wrapper; it exits the process and
  you lose `$result`. Use `-PassThru` and exit yourself.

## Seeing the GUI without Windows

The GUI needs WinForms, so render it headlessly with mock data:

```powershell
# Standard tab (the default) and the tray icon
powershell -NoProfile -ExecutionPolicy Bypass -File droid-bar.ps1 -Mock samples\mock.json -Preview out.png

# Computer tab - proves the third-tab layout and the content-aware height
powershell -NoProfile -ExecutionPolicy Bypass -File droid-bar.ps1 -Mock samples\mock.json -Preview out-computer.png -PreviewTab computer
```

On Linux, get those PNGs from CI instead:

```bash
gh run download <run-id> -R soaresfellipe/droidbar-windows -n preview-pngs -D /tmp/preview
```

To inspect raw API/parse behavior, use `-Dump`.

## Never break these invariants

- Threshold notifications, tray icon and tooltip for Standard/Core are
  unchanged. The Computer tab is display-only: `computer` must never appear in
  `$Pools`, `notifyPools` or `Test-Alerts`.
- `samples/mock.json` must stay in parity with the real API shapes, and must
  stay free of non-`apiBase` host strings (the real computers payload contains
  `relay.factory.ai` URLs that the mock deliberately omits).
- The API key is never logged, committed or echoed. `droid-bar.ps1` and
  `tests/Computers.Tests.ps1` contain the only two places in the repo where the key
  prefix appears as a literal (a UI prompt and a negative test assertion); the
  `secrets` gate fails on any key-shaped match in the worktree or in git history.

## Landing the change

Branch from `main`, run `tools/Install-Hooks.ps1` once per clone so the local
pre-commit gate is active, then PR. `main` is protected by the `main-protect`
ruleset: the `ci` check must pass and no bypass actor exists, including for
admins.
