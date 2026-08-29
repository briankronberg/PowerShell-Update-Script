# PowerShell-Update-Script

`Update-Everything.ps1` is a one-shot Windows maintenance runner. It updates
everything on a laptop through whichever package managers and update channels it
can find, isolating each channel so one failure never stops the rest.

## Quick start

```powershell
# Full run (self-elevates, includes Windows Update)
.\Update-Everything.ps1

# Everything except the OS update pass
.\Update-Everything.ps1 -IncludeWindowsUpdate $false

# Unattended / standard user: no elevation prompt, admin steps flagged as failed
.\Update-Everything.ps1 -SkipElevation -IncludeWindowsUpdate $false
```

Requires PowerShell 5.1 or later (`#Requires -Version 5.1`). The script relaunches
itself elevated unless `-SkipElevation` is passed.

## Parameters

| Parameter | Default | Effect |
|---|---|---|
| `-IncludeWindowsUpdate` | `$true` | Install pending updates via PSWindowsUpdate, scanning **Microsoft** Update so Office and other Microsoft products come along with the OS and drivers. Needs admin; may require a reboot. |
| `-IncludePowerShell7` | `$true` | Install PowerShell 7 if missing, or upgrade it. Machine-wide MSI install needs admin. |
| `-SetPwshTerminalDefault` | `$true` | Point Windows Terminal's default profile at PowerShell 7. Per-user; skipped silently if Terminal is not installed. |
| `-AutoReboot` | off | Let Windows Update reboot on its own. Off by default — the script reports a pending reboot instead. |
| `-IncludePrerelease` | off | Include prerelease builds where supported (currently PowerShell module updates). |
| `-UpdateGlobalNpm` | off | Upgrade global npm packages as well as npm itself. Off by default because global upgrades occasionally break pinned toolchains. |
| `-SkipElevation` | off | Never relaunch elevated. Admin-only steps fail and are flagged in the summary. |
| `-LogRetentionDays` | `30` | Prune logs and settings.json backups older than this. `0` keeps everything. |

Exit code is the number of **failed** steps. Steps that were skipped, or that
finished with warnings, do not count.

## Channels covered

Each step runs only if its tool is actually present, otherwise it is reported as
skipped:

winget (self-update, then all sources) · Microsoft Store apps · PowerShell 7 ·
Microsoft 365 Apps (OfficeC2RClient) · PowerShell modules and help ·
Python Install Manager · uv · pipx · npm · .NET global tools · .NET workloads ·
Chocolatey · Scoop · rustup · GitHub CLI extensions · WSL kernel ·
Defender signatures · Windows Terminal default profile · Windows Update

## Logs

Logs go to the first writable location among `%USERPROFILE%`, `%LOCALAPPDATA%`,
`%TEMP%`, and the script directory, under an `UpdateLogs\` folder:

- `Update-Everything-<timestamp>.log` — full transcript of the run
- `<step>-<timestamp>.log` — every stream captured for that one step

`UpdateLogs/` and `*.log` are gitignored, so a run inside a clone stays clean.

Many CLIs write ordinary progress to stderr, so a step is only marked `Warning`
when PowerShell itself raised an error record — that design note, and the rest of
the reasoning behind the script's shape, is in the comment-based help at the top
of the file.

## Repository layout

```
Update-Everything.ps1           the script
PSScriptAnalyzerSettings.psd1   lint rules (5.1 + 7.0 compatibility)
tests/                          Pester smoke tests: parses, lints, params intact
.github/workflows/ci.yml        runs the same checks on windows-latest
```

## Development

```powershell
Install-Module Pester, PSScriptAnalyzer -Scope CurrentUser
Invoke-Pester .\tests
Invoke-ScriptAnalyzer .\Update-Everything.ps1 -Settings .\PSScriptAnalyzerSettings.psd1
```

History note: the first three commits are the v1 → v2 → v3 revisions of the
script as it was developed, so `git log -p Update-Everything.ps1` shows why each
guard exists.
