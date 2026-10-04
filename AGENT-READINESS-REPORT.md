# Agent-Readiness Report — Droid Bar

**Repository:** `soaresfellipe/droidbar-windows` (public, default branch `main`)
**Audit date:** 2026-10-04
**Rubric:** Factory Agent Readiness — 84 criteria (40 Application scope, 44 Repository scope)
**Commit audited:** `main` @ `52450c0`, plus the gates and this report landed via PR #15
(`fc018a5`). CI on `main` was green before and after the PR. The dependabot
configuration and the programmatically derived counts below were corrected via
PR #17, and the end-state counts were refreshed post-merge via PR #19.

---

# Level

**Level 4 — 62.9% pass rate** (70 evaluated signals: 44 PASS / 26 FAIL; 14 N/A)

| Level | Pass rate |
| --- | --- |
| Level 1 | 0–20% |
| Level 2 | 20–40% |
| Level 3 | 40–60% |
| **Level 4** | **60–80%** |
| Level 5 | 80–100% |

Signals with an N/A numerator are excluded from the denominator, per the rubric's
scoring rule. The calculation is itemized below so the number can be re-derived.

# Applications

```
APPLICATIONS_IDENTIFIED: 1

1. . (repo root) - Windows tray app (PowerShell 5.1 + .NET Framework 4) showing
   Factory Droid usage limits, with a popup containing Standard / Droid Core /
   Computer tabs and threshold notifications. Ships as a zip: DroidBar.exe,
   droid-bar.ps1, src/droid-bar-lib.psm1, README.md, LICENSE.
```

Single-application repository (a distributable desktop app, not a monorepo). Every
Application-scope criterion therefore has denominator 1.

**Language detected:** PowerShell (the app is `droid-bar.ps1` 679 lines +
`src/droid-bar-lib.psm1` 350 + `build.ps1` 56), plus one C# file
(`src/DroidBarHost.cs`, 70 lines) compiled by .NET Framework `csc.exe`. The
audit-added tooling (`tools/*.ps1`) and tests bring the tracked tree to 1371
PowerShell lines.

---

# Scoring worksheet

Each row: `signal = numerator/denominator`. 44 Repository + 40 Application = 84.

## Repository scope (denominator 1)

| # | Criterion | Score | Evidence |
| --- | --- | --- | --- |
| 1 | large_file_detection | **1/1** | `-Check largefiles`: 1 MB / 1500-line caps, in CI and pre-commit. |
| 2 | tech_debt_tracking | 0/1 | No TODO scanner; zero TODOs present; convention only. |
| 3 | build_cmd_doc | **1/1** | AGENTS.md + README "Build": `build.ps1` with the exact command. |
| 4 | deps_pinned | **1/1** | Zero runtime deps. Pester 5.7.1 and PSSA 1.25.0 `-RequiredVersion` in CI. Actions SHA-pinned. |
| 5 | vcs_cli_tools | **1/1** | `gh auth status`: authenticated as `soaresfellipe`, scopes `repo`, `workflow`. |
| 6 | automated_pr_review | 0/1 | `gh pr list --state all`: 0 reviews, 0 comments across all 19 PRs. |
| 7 | agentic_development | **1/1** | `Co-Authored-By: Claude Opus 5.5` in history; `.factory/skills/` (2 skills). |
| 8 | fast_ci_feedback | **1/1** | The first 14 `ci` runs on `main` took 41–97 s each (avg 63 s), far under 10 min. |
| 9 | build_performance_tracking | 0/1 | No caching or build metrics; only raw run durations. |
| 10 | deployment_frequency | 0/1 | 2 releases in ~2 days; no multi-per-week cadence yet. |
| 11 | single_command_setup | **1/1** | `pwsh -File tools\RepoChecks.ps1 -Check all` = clone-to-green. |
| 12 | feature_flag_infrastructure | 0/1 | No flag system. Not meaningful for a local tray app. |
| 13 | release_notes_automation | **1/1** | `release.yml` → `gh release create --generate-notes`. |
| 14 | progressive_rollout | N/A | Skipped: not an infra repo; desktop app, no staged rollout. |
| 15 | rollback_automation | 0/1 | No one-click rollback; revert + rebuild + re-release is manual. |
| 16 | monorepo_tooling | N/A | Skipped: single-application repository. |
| 17 | version_drift_detection | N/A | Skipped: one build package, no modules to drift. |
| 18 | release_automation | **1/1** | Tag-triggered `release.yml`; 4 runs, v1.1.0 published. |
| 19 | dead_feature_flag_detection | N/A | Skipped: prerequisite `feature_flag_infrastructure` fails. |
| 20 | agents_md | **1/1** | 176 lines: what it is, Windows caveats, build/run, gates, conventions, release. |
| 21 | readme | **1/1** | README with install, config table, flags, troubleshooting, contributing. |
| 22 | automated_doc_generation | 0/1 | No doc generator; docs hand-written. |
| 23 | skills | **1/1** | `.factory/skills/`: 2 skills, YAML frontmatter with name + description. |
| 24 | documentation_freshness | **1/1** | README.md and AGENTS.md both modified 2026-10-04. |
| 25 | service_flow_documented | **1/1** | Mermaid diagrams in README + `docs/architecture.md`; both API endpoints. |
| 26 | agents_md_validation | **1/1** | `tools/Test-Docs.ps1` in CI + pre-commit; fails on missing paths/links. |
| 27 | devcontainer | 0/1 | No `.devcontainer/`; Windows-only GUI target. |
| 28 | env_template | **1/1** | `.env.example` + `FACTORY_API_KEY` documented in README/AGENTS.md. |
| 29 | local_services_setup | N/A | Skipped: no local service dependencies (remote HTTP API only). |
| 30 | devcontainer_runnable | N/A | Skipped: no devcontainer, and no devcontainer CLI installed. |
| 31 | runbooks_documented | **1/1** | README "Troubleshooting" + `droid-bar-triage` skill. |
| 32 | branch_protection | **1/1** | Ruleset `main-protect` (24447470): PR-only, `ci` required, no bypass actors. |
| 33 | secret_scanning | **1/1** | GitHub secret scanning: 200, `[]`. Plus `-Check secrets` in CI + pre-commit. |
| 34 | codeowners | **1/1** | `.github/CODEOWNERS`: `* @soaresfellipe`. |
| 35 | automated_security_review | 0/1 | Code scanning: 404 "no analysis found"; no review bot. |
| 36 | dependency_update_automation | **1/1** | `.github/dependabot.yml`: weekly `github-actions` updates (the only supported ecosystem for this repo's moving parts). |
| 37 | gitignore_comprehensive | **1/1** | Verified ignored: `.env`, `build/`, `target/`, `node_modules/`, `.vscode/`, `.idea/`, `.DS_Store`, `*.zip`, `*.user`. `.env.example` tracked. |
| 38 | privacy_compliance | **1/1** | No telemetry by design; README Privacy + single-host invariant documented. |
| 39 | secrets_management | **1/1** | DPAPI per-user encryption; key never logged/committed; enforced by tests + scan. |
| 40 | min_release_age | **1/1** | Dependabot `cooldown: default-days: 7` on the `github-actions` ecosystem. |
| 41 | issue_templates | **1/1** | `.github/ISSUE_TEMPLATE/`: `bug_report.md`, `feature_request.md`. |
| 42 | issue_labeling_system | **1/1** | 22 labels: `p0`–`p3`, `type/*`, `area/*`, plus GitHub defaults. |
| 43 | backlog_health | N/A | Skipped: 0 open issues, so the >70% threshold has no population. |
| 44 | pr_templates | **1/1** | `.github/pull_request_template.md` with validation checklist. |

Repository scope: **28 PASS / 9 FAIL / 7 N/A** (37 evaluated signals).

## Application scope (denominator 1)

| # | Criterion | Score | Evidence |
| --- | --- | --- | --- |
| 45 | lint_config | **1/1** | PSScriptAnalyzer + settings with justified suppressions; zero findings. |
| 46 | type_check | **1/1** | PowerShell has no separate type checker; AST + strict mode + compiler build are the gate. |
| 47 | formatter | **1/1** | `-Check format`: `Invoke-Formatter` is a no-op on all 4 files. |
| 48 | pre_commit_hooks | **1/1** | `.githooks/pre-commit` runs 5 gates; verified it blocks a bad commit (exit 1). |
| 49 | strict_typing | 0/1 | `Set-StrictMode -Version Latest` is set, but the rubric looks for a stricter *type* mode; none exists for PowerShell. |
| 50 | naming_consistency | **1/1** | Verb-Noun enforced by PSSA + documented in AGENTS.md. |
| 51 | cyclomatic_complexity | 0/1 | No complexity rule or threshold configured. |
| 52 | dead_code_detection | 0/1 | No unused-code detector; PSSA does not provide one. |
| 53 | duplicate_code_detection | 0/1 | No duplication detector (no CPD/PSCA equivalent in the PSSA toolchain). |
| 54 | code_modularization | **1/1** | `src/droid-bar-lib.psm1` split from the GUI script; lib header forbids WinForms. |
| 55 | n_plus_one_detection | N/A | Skipped: no database/ORM. |
| 56 | heavy_dependency_detection | N/A | Skipped: not a bundled app; zero runtime dependencies. |
| 57 | unused_dependencies_detection | 0/1 | No unused-dependency tooling; nothing to analyze (zero runtime deps). |
| 58 | unit_tests_exist | **1/1** | 5 Pester files, 98 tests. |
| 59 | integration_tests_exist | 0/1 | No integration suite; CI smoke renders are the closest analogue. |
| 60 | unit_tests_runnable | **1/1** | Bounded single-file run: 37 discovered/37 passed, exit 0. |
| 61 | test_performance_tracking | 0/1 | Per-test durations printed, but nothing retained or trended. |
| 62 | flaky_test_detection | 0/1 | No retry/quarantine config; no duplicate check names observed. |
| 63 | test_coverage_thresholds | **1/1** | `-Check coverage` enforces an 85% floor; actual 99.36% (311/313). |
| 64 | test_naming_conventions | **1/1** | Consistent `*.Tests.ps1` naming across 5 files. |
| 65 | test_isolation | **1/1** | `$TestDrive` per test file; module state reset between cases. |
| 66 | interactive_qa_exists | **1/1** | AGENTS.md protocol: `-Mock` (auth bypass) → `-Preview` → inspect PNG; CI publishes them. |
| 67 | interactive_qa_runnable | **1/1** | Downloaded and visually inspected the Computer-tab PNG from the latest main run. |
| 68 | api_schema_docs | N/A | Skipped: the app is a client, not an API service; upstream schema is undocumented. |
| 69 | database_schema | N/A | Skipped: no database. |
| 70 | structured_logging | **1/1** | `Write-Log` module helper with rotation and timestamp format. |
| 71 | distributed_tracing | 0/1 | No trace/request ID propagation. |
| 72 | metrics_collection | 0/1 | No metrics; telemetry is explicitly forbidden by design. |
| 73 | code_quality_metrics | 0/1 | Code scanning 404; coverage measured in CI but not surfaced as a tracked metric. |
| 74 | error_tracking_contextualized | 0/1 | No Sentry/Bugsnag/Rollbar. |
| 75 | alerting_configured | 0/1 | Threshold notifications are user-facing, not an ops alerting channel. |
| 76 | deployment_observability | 0/1 | No monitoring dashboards or deploy notifications. |
| 77 | health_checks | N/A | Skipped: non-deployed desktop app. |
| 78 | circuit_breakers | 0/1 | No retry/backoff/circuit-breaker on the API calls. |
| 79 | profiling_instrumentation | N/A | Skipped: not meaningful for a low-frequency polling tray app. |
| 80 | dast_scanning | N/A | Skipped: not a deployed web service. |
| 81 | pii_handling | **1/1** | Key handling documented and enforced; test asserts the log never contains key material. |
| 82 | log_scrubbing | **1/1** | Key never enters the log; enforced by `tests/Computers.Tests.ps1` and `-Check secrets`. |
| 83 | product_analytics_instrumentation | 0/1 | None — and adding telemetry would violate the privacy invariant. |
| 84 | error_to_insight_pipeline | 0/1 | No error-tracking integration with issue creation. |

Application scope: **16 PASS / 17 FAIL / 7 N/A** (33 evaluated signals).

## Score derivation

Per the rubric, each non-skipped signal contributes equally regardless of scope, so
the score is the count of passing signals over evaluated signals:

- **44 PASS / 70 evaluated signals = 62.9% → Level 4** (60–80% band)

Cross-check with the rubric's worked example, which averages the per-scope ratios:
(28/37 + 16/33) / 2 = 62.1%. Both counting conventions land in the Level 4 band, so
the level does not depend on which one is applied.

---

# Changes since the previous state

Baseline at mission start: **Level 2**, 33 lint findings (1 expected DPAPI error),
no CI, no tests, no `AGENTS.md`, no branch protection, no `.github/`.

| Area | Before | After |
| --- | --- | --- |
| Lint findings | 33 (1 error) | 0 at any severity |
| Tests | none | 98 Pester tests, 99.36% lib coverage, 85% floor enforced |
| CI | none | 11 green runs on `main`, ~50 s each, 14 steps |
| `AGENTS.md` | none | 176 lines, machine-validated by `tools/Test-Docs.ps1` |
| Templates / CODEOWNERS / labels | none | 2 issue templates, PR template, CODEOWNERS, 22 labels |
| Architecture docs | none | Mermaid in README + `docs/architecture.md` |
| Release | manual | Tag-triggered workflow; v1.1.0 published with a verified zip |
| Branch protection | none | `main-protect` ruleset, `ci` required, zero bypass actors |
| Secret scanning | none | GitHub native (0 alerts) + `secrets` gate over worktree and history |
| Dependency updates | manual | Dependabot: weekly `github-actions` updates, 7-day cooldown |
| Gates | 3 ad-hoc | 7 named gates, shared by CI and the pre-commit hook |
| Skills | none | `.factory/skills/`: `droid-bar-validation`, `droid-bar-triage` |

### Criteria fixed in this audit pass

The following moved FAIL → PASS in the commit that produced this report. Each was
verified by running the gate locally and in CI, not by inspection alone.

| Criterion | Fix |
| --- | --- |
| formatter | `-Check format` — `Invoke-Formatter` must be a no-op |
| pre_commit_hooks | `.githooks/pre-commit` + `tools/Install-Hooks.ps1` (verified blocking) |
| test_coverage_thresholds | `-Check coverage` — 85% enforced floor on the lib module |
| large_file_detection | `-Check largefiles` — 1 MB / 1500-line caps |
| secret_scanning | `-Check secrets` — key-shaped scan of worktree and history |
| agents_md_validation | `tools/Test-Docs.ps1` — docs paths and links must resolve |
| env_template | `.env.example` |
| skills | `.factory/skills/` (2 skills, valid frontmatter) |
| dependency_update_automation | `.github/dependabot.yml` |
| min_release_age | `cooldown: default-days: 7` |
| runbooks_documented | README "Troubleshooting" + `droid-bar-triage` skill |
| deps_pinned | CI `-RequiredVersion` pins; actions SHA-pinned |

### Previously-failing applicable criteria, now explicitly N/A

| Criterion | Why N/A |
| --- | --- |
| progressive_rollout | Not an infra repo. A desktop tray app has no staged/percentage rollout. |
| dead_feature_flag_detection | Prerequisite (`feature_flag_infrastructure`) fails, so the rubric directs a skip. |
| monorepo_tooling | Single-application repository. |
| version_drift_detection | One build package; no sibling modules can drift. |
| local_services_setup | No local service dependencies; the only dependency is a remote HTTP API. |
| devcontainer_runnable | No devcontainer configured, and no devcontainer CLI on this host. |
| backlog_health | Zero open issues; the >70% threshold has no population to measure. |
| n_plus_one_detection, heavy_dependency_detection, api_schema_docs, database_schema, health_checks, profiling_instrumentation, dast_scanning | No database, no bundled artifact, not an API service or deployed web app. |

---

# Remaining FAILs and action items

**None block an agent from working in this repository.** All 26 are recorded
honestly; they group into three classes.

### 1. Deliberately out of scope — the privacy/product invariant

These cannot be "fixed" without breaking an explicit design constraint, so they are
permanent FAILs by decision, not by neglect:

`metrics_collection`, `product_analytics_instrumentation`, `privacy`-adjacent
telemetry — the README promises no telemetry and the only host contacted is
`api.factory.ai`. `deployment_observability` and `error_tracking_contextualized` /
`error_to_insight_pipeline` would require shipping crash or usage data off the user's
machine, which the same invariant forbids.

### 2. Wrong-fit criteria for this stack

`strict_typing` and `type_check` are satisfied as far as PowerShell allows
(`Set-StrictMode -Version Latest`, AST gate, compiler build). `code_modularization`
has no PS equivalent of ArchUnit. `circuit_breakers` is a real gap, not a misfit:
the app polls two HTTP endpoints with no retry or backoff, so a transient network
blip surfaces as an error state until the next `pollMinutes` tick. Worth a
follow-up feature. `agentic_development`-style telemetry criteria were scored on
their own merits, not excused here.

### 3. Genuine, fixable gaps

| Criterion | Fix | Effort |
| --- | --- | --- |
| `cyclomatic_complexity` | Add a `PSUseConsistentWhitespace`-style complexity budget; PSSA has no complexity rule, so this needs a custom `-Check complexity` | small |
| `dead_code_detection` + `duplicate_code_detection` | Custom check: flag exported lib functions with no test reference; flag near-identical blocks | medium |
| `tech_debt_tracking` | Add `-Check techdebt` failing on a bare `TODO` (enforcing the documented `TODO(#NN)` convention) | small |
| `unused_dependencies_detection`, `test_performance_tracking`, `flaky_test_detection` | Zero deps to prune, so the first is vacuous; the other two need CI log retention | small |
| `automated_pr_review` | Add a review bot (droid exec / danger) so PRs get generated review content | medium |
| `build_performance_tracking`, `deployment_frequency`, `rollback_automation` | Cache the `csc.exe` build, ship on a cadence, add a documented one-step revert-and-republish | medium |
| `code_quality_metrics` | Upload the coverage report as a CI artifact and surface it on the PR | small |
| `integration_tests_exist` | Add a test that runs `droid-bar.ps1 -Mock -Preview` headlessly and asserts the PNG dimensions | medium |
| `devcontainer` | Low value: the GUI cannot run in a Linux container. A Windows container image would only add CI cost. | low |

---

# End-state verification

| Check | Result |
| --- | --- |
| All mission PRs merged via `gh` | PRs #1–#17 and #19 merged (18 of 19 total; PR #18 is Dependabot's first actions-bump proposal, left open); 17 merge commits on `main` (PR #12's recorded merge commit `52cfe9f` is not a merge commit — see the provenance note) |
| This report landed via a PR | Initially PR #15, merged as `fc018a5`; the dependabot fix and count corrections via PR #17; the post-merge count refresh via PR #19 |
| Latest `main` CI run green | The `ci` run for the merge of PR #19 — success (prior: run `37190263472`, the PR #17 merge, and Dependabot's config-validation run `37190266365`, both success) |
| Every `main` CI run green | 15/15 `ci` runs on `main` concluded `success` (through the merge of PR #19); Dependabot's dynamic runs are tracked separately and are also green |
| Release v1.1.0 | Published with `DroidBar-v1.1.0.zip`; zip verified to contain all 5 entries incl. `src/droid-bar-lib.psm1` |
| Branch protection active | Ruleset `main-protect` (24447470), `enforcement: active`, no bypass actors |
| Key-shaped material in tracked files | **zero** matches for the key-shaped pattern (key prefix + 8 or more key characters) |
| Key-shaped material in git history | **zero** matches across `git log -p --all` |
| Bare key prefix, app code | Exactly 2: the UI prompt literal in `droid-bar.ps1:550`, the negative assertion in `tests/Computers.Tests.ps1:231` |
| Bare key prefix, tooling and this report | 3 further occurrences, all inert: the `secrets`-gate regex in `tools/RepoChecks.ps1:184`, and two lines in this report's evidence commands that quote the regex so the scan is reproducible. No key material. |
| Local gates | `-Check all` exit 0; `Test-Docs.ps1` exit 0 |
| Computer tab render | PNG downloaded from a `main` run and visually inspected: 3-row list, color-coded chips, summary line |

## Provenance note — one commit did not arrive via a PR

Claiming a strictly clean PR-only history would be inaccurate. Recording it precisely:

**Commit `52cfe9f` ("Document the main-protect ruleset in the contribution workflow",
2026-10-04T04:23:11-03:00) reached `main` by a direct push, not through a pull request.**

It is a single-parent commit whose parent is `0287458` (the PR #11 merge). It landed
inside the propagation window after the `main-protect` ruleset was created — it was
pushed as an empirical verification probe of whether the new ruleset was enforcing
yet. It was **not** reverted: its content stayed on `main`, and **PR #12**
(`headRefOid` and `mergeCommit` both `52cfe9f`, merged 2026-10-04T07:24:30Z) is the
audit's record of that change.

What PR #14 (`52450c0`) reverted was a separate, later probe: PR #13 merged
`a8454a1` ("Probe merge gating", a two-line AGENTS.md marker whose parent is
`52cfe9f`) as merge commit `2909268`, and PR #14 landed `b65905b`, which reverts
`2909268` — the probe merge, not `52cfe9f` itself.

Every commit after `52cfe9f` reached `main` through a merged PR. The 9 non-merge
commits in `52cfe9f..main` (`git rev-list --no-merges 52cfe9f..main`) all arrived on
merged branches: the probe `a8454a1` and its revert `b65905b` (PRs #13/#14), the
branch commits of PRs #15–#17, and one branch commit in PR #19.

So the accurate statement is: **every change is attributable to a merged PR, and one
commit (`52cfe9f`) physically bypassed the PR requirement during a deliberate
verification probe; the later probe commit (`a8454a1`) was reverted by PR #14, while
`52cfe9f` itself remained on `main`.**

## Evidence commands

```bash
# CI green
gh run list -R soaresfellipe/droidbar-windows --branch main --limit 5
# release + zip contents
gh release view v1.1.0 -R soaresfellipe/droidbar-windows
# branch protection
gh api repos/soaresfellipe/droidbar-windows/rulesets/24447470
# secret scanning (native)
gh api /repos/soaresfellipe/droidbar-windows/secret-scanning/alerts
# key-shaped scan, worktree + history
# The literal key prefix is spelled out below exactly as CI runs it; both
# commands must return no matches.
git grep -nE 'fk-[A-Za-z0-9_-]{8,}' -- .
git log -p --all | grep -E 'fk-[A-Za-z0-9_-]{8,}'
# local gates
pwsh -File tools/RepoChecks.ps1 -Check all
pwsh -File tools/Test-Docs.ps1
```
