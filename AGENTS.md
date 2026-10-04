# AGENTS.md — Droid Bar

Guidance for coding agents working in this repository.

## What this app is

Droid Bar is a **Windows tray app** that shows your [Factory](https://factory.ai) Droid
usage limits (5-hour, weekly, monthly — for **Standard** and **Droid Core**) and
notifies you when you approach a limit. It polls `GET https://api.factory.ai/api/billing/limits`
with a DPAPI-protected API key, shows a tray icon (highest Standard percentage,
color-coded), renders a dark popup with tabs, and fires threshold notifications
(75% / 90% / 100%) once per threshold. No telemetry; the only host it talks to is `api.factory.ai`.

## Windows-only caveats (do not "fix" these)

- The app targets **Windows PowerShell 5.1 + .NET Framework 4** only (`#Requires -Version 5.1`).
- `DroidBar.exe` is a tiny C# host (`src/DroidBarHost.cs`) that runs `droid-bar.ps1`
  **in-process** via `build.ps1` (compiled with the .NET Framework 4 `csc.exe`; no SDK needed).
- The GUI depends on **WinForms / GDI+ / P-Invoke / DPAPI / the registry** — none of which
  run on Linux or macOS. You cannot run or dot-source the full script on a non-Windows host;
  GUI behavior must be smoke-tested via GitHub Actions (`windows-latest`) or `-Preview` renders there.
- DPAPI protects the API key so only the Windows user can decrypt it; this is intentional.

## Build / run

```powershell
# Build DroidBar.exe (Windows only)
powershell -NoProfile -ExecutionPolicy Bypass -File build.ps1

# Run (script directly, no build needed)
powershell -NoProfile -ExecutionPolicy Bypass -File droid-bar.ps1

# Run (compiled host)
DroidBar.exe
```

Install = extract the release zip anywhere and run `DroidBar.exe`. Nothing to install;
the app ships as the zip only.

## Validation protocol (developer flags)

Use these flags to validate without the live GUI:

| Flag | What it does |
| --- | --- |
| `-Mock samples\mock.json` | Use a local JSON file instead of the API. |
| `-Preview out.png` | Render the popup (and tray icon) to a PNG and exit. |
| `-PreviewTab <id>` | With `-Preview`: which tab to render — `standard` (default), `core` or `computer`. |
| `-Dump` | Print the raw API response and exit. |

Protocol for changes that touch rendering or data logic:

1. Unit-test pure helpers with Pester (see below).
2. `droid-bar.ps1 -Mock samples\mock.json -Preview out.png` and inspect the PNG.
3. `-Dump` to verify raw API/parse behavior.
4. CI on `windows-latest` runs the same smoke checks and uploads the PNGs as artifacts.

## Tests and lint

Every gate lives in **`tools/RepoChecks.ps1`** and is invoked from both CI and the
local pre-commit hook, so the two can never drift. Run them all with:

```powershell
pwsh -File tools\RepoChecks.ps1 -Check all
```

Individual gates: `-Check parse`, `lint`, `format`, `largefiles`, `secrets`,
`tests`, `coverage` (each exits non-zero on failure).

- **Parse** (`parse`): `[System.Management.Automation.Language.Parser]::ParseFile`
  must report zero errors for `droid-bar.ps1`, `src/droid-bar-lib.psm1`,
  `build.ps1` and `tools/RepoChecks.ps1`. CI enforces this on PowerShell 5.1,
  which is what guards against PS 7-only syntax.
- **Lint** (`lint`): PSScriptAnalyzer 1.25.0 with `PSScriptAnalyzerSettings.psd1`.
  Zero Error-severity findings required, currently zero findings at any severity.
  Every rule excluded in the settings file carries a justification comment
  (DPAPI key path, intentional silent catches, `Draw-*` GUI helpers, `Write-Log`,
  fixed event-handler signatures, positional internal calls). Analyze **one path
  per call** — `-Path` takes a single string.
- **Format** (`format`): `Invoke-Formatter` must be a no-op on every analyzed
  file. PSSA's formatter is the canonical PowerShell formatter; if it would
  change a file, the file is not committed in formatted shape.
- **Hygiene** (`largefiles`, `secrets`): no tracked file over 1 MB, no code or
  doc over 1500 lines, and no key-shaped material (`fk-` plus 8 or more
  key characters) in the worktree **or in git history**.
- **Tests** (`tests`): Pester pinned to 5.7.1, 98 cases in `tests/`.
- **Coverage** (`coverage`): Pester code coverage on `src/droid-bar-lib.psm1`
  must stay at or above **85%** (currently 99.4%). The GUI script is excluded
  on purpose: its WinForms paths are only reachable on Windows.

### Local pre-commit hook

Hooks cannot be committed into `.git/hooks`, so install them once per clone:

```powershell
pwsh -File tools\Install-Hooks.ps1
```

This sets `core.hooksPath = .githooks`, after which `.githooks/pre-commit` runs
the `parse`, `lint`, `largefiles` and `secrets` gates before each commit. The
`format` and `coverage` gates are CI-only (they need the PSScriptAnalyzer engine
and a full Pester run). All gates also run in CI
(`.github/workflows/ci.yml`) on every PR and push to `main`.

## Config / state / log paths (Windows)

All under `%APPDATA%\droid-bar\`:

| File | Purpose |
| --- | --- |
| `config.json` | Settings: `pollMinutes`, `thresholds`, `notifyPools`, `trayPool`, `apiBase`, `apiKeyProtected` (DPAPI). |
| `state.json` | Per-window alert state (which thresholds already fired). |
| `droid-bar.log` | Rotated log (~512 KB). Never logs the API key. |

`FACTORY_API_KEY` env var overrides the stored key. See README "Configuration" for the full table.

## Coding conventions

- **PowerShell 5.1-compatible syntax only**: no `?.`/`??`, no ternary `? :`, no `&&`/`||`
  between statements, no PS 7-only cmdlets. `[ordered]@{}` and `Join-Path` are fine.
- **No external runtime modules** — the app must run on a stock Windows 10/11 install.
  `System.Windows.Forms` / `System.Drawing` live only in `droid-bar.ps1`, never in `src/droid-bar-lib.psm1`
  (the lib module must import cleanly on pwsh/Linux for unit testing).
- **Verb-Noun** function names (existing examples: `Get-WinInfo`, `Format-Pct`, `Draw-Popup`, `Test-Alerts`).
- `Set-StrictMode -Version Latest` at the top of script and module — guard `$null` before property access.
  Strict mode makes references to non-existent properties terminating errors, so dynamic
  API/mock JSON members must be read via `Get-MemberValue` (returns `$null` when missing).
- Pure/testable logic goes in `src/droid-bar-lib.psm1`; GUI, polling and P/Invoke stay in `droid-bar.ps1`.
- English comments; comment intent where it is non-obvious.
- **`TODO(#NN)` convention**: tracked tech debt uses `TODO(#123)` referencing a GitHub issue
  (never a bare `TODO`).
- Privacy invariants: the only network host is `api.factory.ai` (`apiBase`); the API key is
  never logged, committed, or echoed.

## Contribution workflow

- Branch from `main` → commit → PR → CI must pass → merge. Do not push directly to `main`.
- Commit messages: short imperative subject (e.g. `Extract pure helpers into src/droid-bar-lib.psm1`).
- PRs require a CI pass; `CODEOWNERS` assigns review to `@soaresfellipe`.
- Use the repo issue/PR templates. Label taxonomy: `p0`–`p3` (priority), `type/*` (change kind),
  `area/*` (subsystem).
- The API key is a secret: never commit, echo, or log it.

### Branch protection on `main` (enforced by ruleset)

`main` is protected by the repository ruleset **`main-protect`** (ruleset id `24447470`),
so the flow above is enforced by GitHub, not just by convention:

| Rule | Effect |
| --- | --- |
| `pull_request` | Every change to `main` must arrive via a PR (merge, squash or rebase merge allowed). |
| `required_status_checks` | The `ci` check (GitHub Actions workflow `ci`, integration id `15368`) must pass, and branches must be up to date with `main` before merging (`strict` policy). |
| `non_fast_forward` | Force-pushes to `main` are rejected. |
| `deletion` | Deleting `main` is rejected. |

No bypass actors are configured (`current_user_can_bypass: never`), which includes repository
admins: there is no "push anyway" escape hatch. If a change must bypass CI, amend the workflow
rather than weakening the ruleset.

Inspect or update it with:

```bash
# read back the ruleset (id is stable, name is the human handle)
gh api repos/soaresfellipe/droidbar-windows/rulesets
gh api repos/soaresfellipe/droidbar-windows/rulesets/24447470
```

## Release steps

1. Merge all feature work into `main` with green CI.
2. Push a tag: `git tag v1.2.0 && git push origin v1.2.0` (semver `vMAJOR.MINOR.PATCH`).
3. The tag triggers `.github/workflows/release.yml` (on `windows-latest`): runs `build.ps1`,
   zips `DroidBar.exe` + `droid-bar.ps1` + `src/droid-bar-lib.psm1` + README + LICENSE, and
   creates a GitHub Release with auto-generated notes and the zip attached.
4. Verify at [Releases](https://github.com/soaresfellipe/droidbar-windows/releases) that the
   zip asset contains the expected files.
