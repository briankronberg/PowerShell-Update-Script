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
| `-SkipElevation` | off | Never relaunch elevated. Steps that need admin are reported as skipped with that reason. |
| `-Notify` | off | Show Windows toast notifications when the run finishes, plus an urgent one if a restart is needed. Meant for scheduled runs. |
| `-InstallNotificationModule` | off | Install BurntToast from the PowerShell Gallery if `-Notify` is set and the module is missing. |
| `-LogRetentionDays` | `30` | Prune logs and settings.json backups older than this. `0` keeps everything. |

### Exit codes

| Code | Meaning |
|---|---|
| `0` | Every step succeeded or was skipped |
| `1`–`63` | That many steps failed. Steps that finished with warnings completed, and do not count |
| `64` | **Nothing was attempted** — the run could not become Administrator |

`64` is deliberately outside the step-count range so a scheduled task or wrapper
can tell "did not run" apart from "ran, and something failed".

## Running without administrator rights

The script checks whether elevation is *possible* before requesting it. If the
account is not in the local Administrators group, or UAC is switched off, it
stops immediately with an explanation and exit `64` rather than raising a
consent prompt that cannot succeed:

```
WARNING: Cannot run elevated: This account is not a member of the local
Administrators group, so Windows will not grant elevation.
WARNING: Nothing has been changed. Re-run with -SkipElevation to run the steps
that do not need administrator rights.
```

When membership *cannot* be determined — a domain group nested inside local
Administrators, or a machine where the group cannot be read — the script
attempts elevation anyway rather than refusing. Guessing "no" there would block
legitimate administrators, so an unknown answer is treated as "try it".

With `-SkipElevation`, the run proceeds and the steps that genuinely need admin
— Windows Update, Defender signatures, the PowerShell 7 machine-wide install —
are reported as skipped with that reason, instead of failing on a permissions
error that reads like a bug:

```powershell
.\Update-Everything.ps1 -SkipElevation
```

### Execution policy

The elevated relaunch passes `-ExecutionPolicy Bypass`, but the *first* launch
obeys whatever policy is in force. On a machine set to `AllSigned` or
`Restricted` the script is blocked before it runs, with a "not digitally signed"
error. Start it like this instead:

```bash
powershell -ExecutionPolicy Bypass -File .\Update-Everything.ps1
```

Check the current setting with `Get-ExecutionPolicy -List`.

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

## Notifications

An interactive run prints everything to the console. A scheduled one has nobody
watching, so `-Notify` raises Windows toast notifications instead:

- **A summary** when the run finishes — how many steps updated, failed, warned
  or were skipped, and where the logs are.
- **A restart notice**, marked *urgent*, when Windows is waiting on a reboot.
  Urgent notifications break through Focus Assist, which ordinary ones do not.
  A machine that has installed updates but not restarted has not finished
  updating, and that is worth interrupting for.

Notifications need the [BurntToast](https://github.com/Windos/BurntToast) module:

```powershell
Install-Module BurntToast -Scope CurrentUser
```

It is an optional dependency, never a hard one. If the module is missing, or the
run has no interactive desktop session to draw on, the script warns once and
carries on. A notification failing must never be the reason a machine goes
un-updated. Pass `-InstallNotificationModule` to have the script install it on
first use.

```powershell
.\Update-Everything.ps1 -Notify
```

**Toasts need a desktop session.** They are drawn by the shell into an
interactive session, so a task running as `SYSTEM` cannot show one — the run
finishes silently and the restart notice never appears. This is why the
scheduled task below runs as *you* rather than as `SYSTEM`.

## Running on a schedule

`Register-UpdateTask.ps1` creates a Windows scheduled task. It must be run from
an **elevated** session, because the task itself runs with the highest
privileges:

```powershell
.\Register-UpdateTask.ps1                     # weekly, Wednesday at noon
.\Register-UpdateTask.ps1 -Cadence PatchTuesday
.\Register-UpdateTask.ps1 -Cadence Weekly -DayOfWeek Saturday -At 09:00
.\Register-UpdateTask.ps1 -Show               # what is registered right now
.\Register-UpdateTask.ps1 -Unregister         # remove it
```

### Choosing a cadence

| Cadence | Runs | When to pick it |
|---|---|---|
| `Weekly` *(default)* | Every week on `-DayOfWeek` (default Wednesday) | A personal machine. Picks up Patch Tuesday within a few days and keeps package managers current, without a heavy job every day. |
| `PatchTuesday` | The third Wednesday of each month | You want to track Microsoft's cycle and install nothing else in between. |
| `Daily` | Every day | Rarely worth it. A full pass across every package manager is heavy, and Windows already updates Defender signatures on its own several times a day. |

**Why the third Wednesday, and not the second?** Microsoft ships on the second
Tuesday of the month, around 17:00 UTC. The usual advice is to let a patch sit
for a few days rather than installing it the hour it lands. The obvious way to
express "the day after Patch Tuesday" is the second Wednesday — and that is
wrong. In 12 of the 84 months from 2026 to 2032 the second Wednesday falls
*before* Patch Tuesday, so the run would happen before the patches exist. The
third Wednesday is always 1 to 8 days after it. There is a test that checks this
for every month in that range.

### Task settings, and why

The task runs **as you, elevated, while you are logged on**. Running as `SYSTEM`
would be simpler and would not need you logged in, but `SYSTEM` cannot show a
notification to anybody, so the summary and the restart notice would go
nowhere. Running as the user with `RunLevel Highest` gets both administrator
rights and a session that toasts can reach.

The cost is that the task only runs while you are logged on. `StartWhenAvailable`
covers the usual laptop case: a run missed because the machine was asleep or
switched off happens shortly after your next logon.

| Setting | Value | Reason |
|---|---|---|
| `StartWhenAvailable` | on | Catches up a run missed while the laptop was off, instead of waiting a whole cycle. |
| `RunOnlyIfNetworkAvailable` | on | Nothing to update without a network. |
| Battery | won't start, stops if unplugged | A full update pass is heavy. Override with `-AllowBattery`. |
| `RandomDelay` | 15 min | Spreads the start time. Set with `-RandomDelayMinutes`. |
| `ExecutionTimeLimit` | 2 hours | One wedged installer would otherwise hold the task open until the next reboot. |
| `MultipleInstances` | `IgnoreNew` | A second run would fight the first for the same package managers and log files. |
| `RestartCount` / `RestartInterval` | 2 / 30 min | Transient network failures are the common case. |
| `WakeToRun` | off | Don't wake a sleeping laptop; `StartWhenAvailable` picks it up later anyway. |

## Repository layout

```
Update-Everything.ps1                          the script
Register-UpdateTask.ps1                        registers it as a scheduled task
test.ps1                                       test runner, used locally and by CI
PSScriptAnalyzerSettings.psd1                  lint rules (5.1 + 7.0 compatibility)
tests/Update-Everything.Tests.ps1              static contract: parameters, help, docs, guard
tests/Update-Everything.Functions.Tests.ps1    behaviour: logging, steps, reboot, elevation
tests/Set-PwshAsWindowsTerminalDefault.Tests.ps1   the settings.json rewrite, in a sandbox
tests/Register-UpdateTask.Tests.ps1            cadences, triggers and task settings
tests/Notification.Tests.ps1                   toast behaviour, with BurntToast stubbed
.github/workflows/ci.yml                       runs test.ps1 on windows-latest
```

## Development

Requires [Pester 6](https://pester.dev) and PSScriptAnalyzer:

```powershell
Install-Module Pester -MinimumVersion 6.0.0 -Scope CurrentUser -Force -SkipPublisherCheck
Install-Module PSScriptAnalyzer -Scope CurrentUser
```

Run the suite through `test.ps1`, the same entry point CI uses, so a green run
locally means a green run in the pipeline:

```powershell
.\test.ps1                      # everything
.\test.ps1 -Tag Static          # script contract only
.\test.ps1 -ExcludeTag Lint     # skip the analyzer pass
.\test.ps1 -CI                  # non-zero exit on failure, writes testResults.xml
```

Tests are tagged `Static` (the script's parameter contract, help and step
definitions), `Docs` (README and LICENSE stay in sync with the script) and
`Lint` (PSScriptAnalyzer).

### How the tests work, and why

Running this script to test it would elevate, install software and potentially
reboot the machine doing the testing. So the suite never *runs* it. It works in
two layers instead.

**Static checks** read the script without loading it — through the PowerShell
AST, and through `Get-Command` / `Get-Help`, which report a script's parameter
block and help without executing its body. These hold the contract: add a
parameter and the suite fails until it is documented in both the comment-based
help and the README table; flip a default so the script reboots without being
asked and the suite fails; give two steps the same name — they would overwrite
each other's log file — and the suite fails.

**Behavioural checks** dot-source the script and call its functions directly.
That is safe because of the dot-source guard: everything above it is a function
definition, so

```powershell
. .\Update-Everything.ps1
```

loads the functions and returns without updating anything. The guard is not
taken on trust — a static test asserts it exists, that every statement above it
is a function definition, and that no `Invoke-Step` call appears before it. Put
one stray executable line above the guard and that test fails, because such a
line would run on every dot-source.

File work goes to `TestDrive`, and `LOCALAPPDATA` is redirected there while the
Windows Terminal tests run, so a real `settings.json` is never opened. Registry
probes are mocked.

There is no code coverage metric, for the same reason: measuring coverage
requires executing the code under test.

#### Why not `Set-StrictMode`?

Most PowerShell style guides open a script with `Set-StrictMode -Version Latest`.
It is not used here, deliberately. Strict mode makes reading a *missing property*
fatal, and this script legitimately probes for optional keys in Windows
Terminal's `settings.json` (`if ($cfg.profiles -and $cfg.profiles.list)`) — a
file where those keys are frequently absent. Turning strict mode on would break
that path on exactly the machines it exists to handle.

The useful half is recovered statically instead: a test walks the AST and fails
if the script ever reads a variable it never assigns, which is the typo class
strict mode is really there to catch.

History note: the first three commits are the v1 → v2 → v3 revisions of the
script as it was developed, so `git log -p Update-Everything.ps1` shows why each
guard exists.

## Support

**There is none.** This is a personal maintenance script published in the hope
it is useful to someone else. It is not a product, it carries no warranty, and
nobody is on the hook to fix it, answer questions, or keep it working.

Issues and pull requests are welcome and may well be read, but no response is
promised and none should be inferred from silence.

### Read this before your first run

The script makes real, sometimes irreversible changes to a machine:

- It **elevates to Administrator** and installs software machine-wide.
- It **installs pending Windows and Microsoft updates** by default
  (`-IncludeWindowsUpdate $true`), which can require a reboot.
- It **installs or upgrades PowerShell 7** by default (`-IncludePowerShell7 $true`).
- It **edits Windows Terminal's `settings.json`** to change the default profile
  (`-SetPwshTerminalDefault $true`). The file is backed up first, into the log
  directory.
- It upgrades packages across every manager it finds, which can move pinned
  toolchains to versions your projects were not expecting. `-UpdateGlobalNpm`
  is off by default for exactly this reason.

Read the script before running it, and try the cautious combination first:

```powershell
.\Update-Everything.ps1 -IncludeWindowsUpdate $false -IncludePowerShell7 $false -SetPwshTerminalDefault $false
```

Every step writes a log, so you can see precisely what happened afterwards.

## License

[MIT](LICENSE) — free to use, copy, modify, and redistribute, commercially or
otherwise, provided the copyright notice and license text come along. The
software is provided **as is**, without warranty of any kind.
