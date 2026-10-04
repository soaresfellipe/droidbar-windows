# Architecture

This is the target architecture of Droid Bar; components land incrementally as
milestones ship (the GUI-free helper module and the Droid Computers fetch are the
newest additions).

```mermaid
flowchart TB
    subgraph app["DroidBar.exe (Windows)"]
        HOST["src/DroidBarHost.cs - tiny C# host compiled by build.ps1 with the .NET Framework 4 csc.exe"]
        SCRIPT["droid-bar.ps1 - PowerShell 5.1, runs in-process"]
        LIB["src/droid-bar-lib.psm1 - GUI-free helpers (parsing, formatting, alert logic)"]
        GUI["GUI - tray icon, popup with tabs, threshold notifications"]
        SCRIPT --> LIB
        SCRIPT --> GUI
        HOST --> SCRIPT
    end

    subgraph files["Data files - %APPDATA%\\droid-bar\\"]
        CFG["config.json - settings + DPAPI-protected API key"]
        STATE["state.json - per-window alert levels"]
        LOG["droid-bar.log - rotated log, never contains the key"]
    end

    subgraph api["https://api.factory.ai - only host the app talks to"]
        LIMITS["GET /api/billing/limits - Standard and Droid Core windows, fiveHour / weekly / monthly"]
        COMPUTERS["GET /api/v0/computers - Droid Computers list: name, status, providerType"]
    end

    SCRIPT -->|"Bearer key, every pollMinutes"| api
    SCRIPT <-->|"read / write"| files
```

## How the pieces fit

- **`DroidBar.exe`** (`src/DroidBarHost.cs`) is a minimal C# host so Windows shows the
  process as "Droid Bar" instead of "Windows PowerShell". It runs `droid-bar.ps1`
  in-process; `$PSScriptRoot` still resolves to the exe folder.
- **`droid-bar.ps1`** owns everything GUI and lifecycle: WinForms/GDI drawing, P/Invoke,
  the tray icon and popup, polling timer, threshold notifications, and the DPAPI key
  handling. Dev flags (`-Mock`, `-Preview`, `-Dump`) short-circuit the GUI for validation.
- **`src/droid-bar-lib.psm1`** holds the GUI-free, testable helpers (parsing, formatting,
  alert computation). It imports cleanly on pwsh/Linux so the Pester suite can run anywhere;
  the release zip ships it alongside the script.
- **State** lives in `%APPDATA%\droid-bar\`: `config.json` (settings, DPAPI-protected key),
  `state.json` (which alert thresholds already fired per window), and `droid-bar.log`.
- **The API key** is only ever sent as a Bearer token to `api.factory.ai`. It is never
  logged and the app makes no other network calls (no telemetry).
