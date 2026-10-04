---
name: droid-bar-triage
description: Triage a user-reported Droid Bar problem on Windows - read the log and config in %APPDATA%\droid-bar, decide whether it is a key, API, parse or rendering fault, and pick the right fix.
---

# Droid Bar triage

Use this for bug reports ("the number is wrong", "no notification fired",
"Computer tab is empty", "it says no API key"). All state is under
`%APPDATA%\droid-bar\` and is readable without admin rights.

## Read these first

| File | Why |
| --- | --- |
| `droid-bar.log` | Rotated at ~512 KB. Every fetch outcome, error and GUI paint is logged. It never contains the API key. |
| `config.json` | `apiKeyProtected` is a DPAPI blob. **Never paste its contents anywhere.** Confirm only that it is non-empty. |
| `state.json` | Which thresholds already fired per window. If `standard.fiveHour` is `100` and usage is still high, no new notification is expected - that is by design, not a bug. |

## Map the symptom to a cause

- **Popup shows "no data" / an error** - the fetch failed. The log line carries
  the HTTP status. `400` means the key is malformed, `401` means it is missing,
  wrong, or deleted, `429` is rate limiting, anything else is a network problem.
- **Tray number stale or wrong** - `trayPool` decides which pool the number
  reflects (`standard` by default). The tray only ever reads `limits.standard`
  / `limits.core`; it is unaffected by the Computer tab.
- **No notification at a crossed threshold** - check `thresholds` and
  `notifyPools` in `config.json`, then `state.json`. A threshold fires once per
  window; it re-arms when usage drops back below it.
- **Computer tab empty or "unavailable"** - the computers call failed or
  returned a shape the parser did not recognize. The Standard and Droid Core
  tabs keep working in that case, by design. Check the log for a `computers`
  line before suspecting the key.
- **"No API key" prompt on every start** - `apiKeyProtected` is empty or was
  written by a different Windows user (DPAPI is per-user). Re-enter it via
  right-click → **Set API key**.

## Fix path

1. Reproduce headlessly before changing anything: with `-Mock samples\mock.json`
   you can render and dump without any key at all.
2. Pure logic changes go in `src/droid-bar-lib.psm1` with a Pester test; GUI
   changes go in `droid-bar.ps1` and get a `-Preview` PNG inspected.
3. Use the `droid-bar-validation` skill for the exact gate and render commands.

Never ask the user to paste their API key, a DPAPI blob, or a config file
verbatim - ask for the log lines instead.
