# UpdateEverything

A PowerShell module that updates a Windows machine through every package manager
and update channel it can find, running each as an isolated step so a single
failure does not stop the rest. It can also register itself as a scheduled task
and tell you what happened with a toast notification.

## Install

From a clone:

```powershell
git clone https://github.com/briankronberg/PowerShell-Update-Script.git
```

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\PowerShell-Update-Script\Install.ps1
```

That copies the module into your own module path, which needs no elevation, and
prints what it exported. Add `-Scope AllUsers` to install machine-wide, which
does need elevation.

To load it without installing, point `Import-Module` at the source:

```powershell
Import-Module .\PowerShell-Update-Script\src\UpdateEverything.psd1
```

Requires PowerShell 5.1 or later on Windows 10 or a matching Server release.

### Execution policy

`-ExecutionPolicy Bypass` applies to one process, changes no machine setting,
and is why the commands here use the long form. Without it a machine set to
`AllSigned` or `Restricted` refuses the script before it runs. Windows
PowerShell and PowerShell 7 hold separate policies, so one may refuse what the
other runs. Check with `Get-ExecutionPolicy -List`.

## Commands

| Command | Does |
|---|---|
| `Update-Everything` | Runs the update pass and returns a result object |
| `Register-UpdateEverythingTask` | Registers the scheduled task. Needs elevation |
| `Get-UpdateEverythingTask` | Reports the registered task, or nothing if there is none |
| `Unregister-UpdateEverythingTask` | Removes the task |
| `Test-PendingReboot` | Reports whether Windows is waiting on a restart, and why |

`Update-All` is an alias for `Update-Everything`.

## Running it

```powershell
Update-Everything
```

Skip the OS update pass:

```powershell
Update-Everything -IncludeWindowsUpdate $false
```

Run without elevating, reporting admin-only steps as skipped:

```powershell
Update-Everything -SkipElevation
```

### What it returns

`Update-Everything` hands back an object rather than exiting. As a script it
ended with `exit $failedSteps.Count`, which a module function cannot do without
killing the session that called it.

| Property | |
|---|---|
| `Ran` | `$false` when nothing was attempted, for example when the session could not become Administrator |
| `Reason` | Why it did not run, when `Ran` is `$false` |
| `Elevated` | Whether the run had administrator rights |
| `Steps` | One record per step, with `Status`, `Seconds` and `Log` |
| `OkCount`, `WarningCount`, `SkippedCount`, `FailedCount` | Step tallies |
| `RebootPending`, `RebootReason` | Whether Windows wants a restart, and what is holding it |
| `LogDirectory`, `MainLog` | Where the logs went |

Warning steps completed, so they do not count as failures.

```powershell
$result = Update-Everything -SkipElevation
$result.Steps | Where-Object Status -ne 'OK' | Format-Table Step, Status, Log
```

The scheduled task turns `FailedCount` into an exit code, which is the only
thing that crosses a process boundary.

## Parameters

| Parameter | Default | Effect |
|---|---|---|
| `-IncludeWindowsUpdate` | `$true` | Install pending updates via PSWindowsUpdate, scanning Microsoft Update so Office and other Microsoft products come along with the OS and drivers. Needs admin; may require a reboot. |
| `-IncludePowerShell7` | `$true` | Install or upgrade PowerShell 7. The machine-wide MSI install needs admin. |
| `-SetPwshTerminalDefault` | `$true` | Point Windows Terminal's default profile at PowerShell 7. Per-user; skipped if Terminal is not installed. |
| `-AutoReboot` | off | Let Windows Update reboot on its own. Off by default; the run reports a pending reboot instead. |
| `-IncludePrerelease` | off | Include prerelease builds where supported, currently PowerShell module updates. |
| `-UpdateGlobalNpm` | off | Upgrade global npm packages as well as npm itself. Off by default because global upgrades can break pinned toolchains. |
| `-SkipElevation` | off | Never relaunch elevated. Steps needing admin are reported as skipped. |
| `-PromptBeforeRun` | off | Pause before starting and offer: run now, skip, or wait. Takes the default after `-PromptTimeoutSeconds`. |
| `-PromptTimeoutSeconds` | `60` | How long that prompt waits before starting anyway. |
| `-DelayMinutes` | `60` | How long the "wait, then run" answer waits. |
| `-Notify` | off | Show a toast when the run finishes, plus an urgent one if a restart is needed. Intended for scheduled runs. |
| `-AllowInstall` | *(none)* | Which missing components may be installed: `All`, or any of `PowerShell7`, `PSWindowsUpdate`, `NuGetProvider`, `BurntToast`. |
| `-LogRetentionDays` | `30` | Prune logs and settings.json backups older than this. `0` keeps everything. |

## Channels covered

Each step runs only if its tool is on the machine. The summary lists the rest as
skipped:

winget (self-update, then all sources) · Microsoft Store apps · PowerShell 7 ·
Microsoft 365 Apps (OfficeC2RClient) · PowerShell modules and help ·
Python Install Manager · uv · pipx · npm · .NET global tools · .NET workloads ·
Chocolatey · Scoop · rustup · GitHub CLI extensions · WSL kernel ·
Defender signatures · Windows Terminal default profile · Windows Update

## Running without administrator rights

The module checks whether it can elevate before it asks. An account outside the
local Administrators group, or a machine with UAC switched off, stops with
`Ran = $false` and a reason, instead of raising a consent prompt that cannot
succeed.

Sometimes membership cannot be determined. A domain group nested inside local
Administrators does it, so does a group the module cannot read. In that case it
tries to elevate anyway. Treating "unknown" as "no" would lock out real
administrators, which is the worse mistake.

With `-SkipElevation`, the run proceeds and the admin-only steps (Windows
Update, Defender signatures, the PowerShell 7 install) are reported as skipped
rather than failing on permissions.

## Logs

The module writes logs to the first writable location among `%USERPROFILE%`,
`%LOCALAPPDATA%`, `%TEMP%` and the module directory, under `UpdateLogs\`:

- `Update-Everything-<timestamp>.log`, the transcript of the whole run
- `<step>-<timestamp>.log`, every stream from that one step

Many CLIs write ordinary progress to stderr, so a step earns `Warning` only when
PowerShell itself raises an error record.

## Installing versus updating

Updating something already installed needs no permission. Installing something
that was never there does, and the module will not do it silently.

| Component | Installs | Scope | Needed for |
|---|---|---|---|
| `PowerShell7` | PowerShell 7 via winget (MSI) | machine-wide | `-IncludePowerShell7` |
| `PSWindowsUpdate` | The PSWindowsUpdate module | **all users** | `-IncludeWindowsUpdate` |
| `NuGetProvider` | The NuGet package provider | current user | reaching the PowerShell Gallery |
| `BurntToast` | The BurntToast module | current user | `-Notify` |

Without `-AllowInstall`, an interactive run asks before each one and defaults to
*No*. A non-interactive run never prompts and never installs. There is nobody to
ask, so it declines and reports the step as skipped. Approve in advance instead:

```powershell
Update-Everything -AllowInstall PSWindowsUpdate,BurntToast
```

```powershell
Update-Everything -AllowInstall All
```

The module asks about each component at most once per run. A declined install
skips its step rather than failing it, so it stays out of `FailedCount`.

## Notifications

`-Notify` raises two Windows toasts, a summary when the run finishes and a
restart notice marked *urgent* when Windows is waiting on a reboot. Urgent
notifications break through Focus Assist; ordinary ones do not.

```powershell
Update-Everything -Notify
```

Notifications need the [BurntToast](https://github.com/Windos/BurntToast) module:

```powershell
Install-Module BurntToast -Scope CurrentUser
```

It is an optional dependency. If the module is missing, or the run has no
interactive desktop session, the update proceeds as normal and you are told in
three places: when registering the scheduled task, at the start of the run, and
again in the closing summary.

Toasts are drawn into an interactive desktop session, so a task running as
`SYSTEM` cannot show one. This is why the scheduled task runs as you.

## Pausing before a run

`-PromptBeforeRun` gives a scheduled run a way out before it starts:

```
A maintenance run is about to start.
  [1]* Run now
  [2]  Skip this run (the next scheduled run is unaffected)
  [3]  Wait 60 minutes, then run

Starting in  47s -- press 1-3 to choose, or wait.
```

- **Run now.** The default, taken automatically if nobody answers.
- **Skip.** Nothing changes and the result comes back with `Ran = $false`. The
  next scheduled run stands.
- **Wait.** Sleeps `-DelayMinutes`, then runs.

Silence counts as run now. An unanswered prompt usually means nobody is at the
machine, which is when the updates matter most. If the run cannot prompt at all,
because there is no console or input is redirected, it says so and starts
straight away rather than blocking.

## Running on a schedule

Registering needs an elevated session, because the task itself runs with the
highest privileges:

```powershell
Register-UpdateEverythingTask -Cadence Weekly -AllowInstall PSWindowsUpdate
```

```powershell
Register-UpdateEverythingTask -Cadence PatchTuesday
```

```powershell
Register-UpdateEverythingTask -Cadence Weekly -DayOfWeek Saturday -At 09:00
```

Inspecting and removing need no elevation:

```powershell
Get-UpdateEverythingTask
```

```powershell
Unregister-UpdateEverythingTask
```

The task imports the module by path and turns the result into an exit code, so
Task Scheduler records a failed run as a non-zero last result.

### Cadence

| Cadence | Runs | Suits |
|---|---|---|
| `Weekly` *(default)* | Every week on `-DayOfWeek`, default Wednesday | A personal machine. Picks up Patch Tuesday within a few days without a heavy job daily. |
| `PatchTuesday` | Third Wednesday of each month | Tracking Microsoft's cycle and nothing in between. |
| `Daily` | Every day | Rarely worth it. Windows already updates Defender signatures several times a day. |

Microsoft ships on the second Tuesday, around 17:00 UTC, and the usual advice is
to let a patch sit a few days. The intuitive way to say "the day after Patch
Tuesday" is the second Wednesday, and it is wrong. In 12 of the 84 months from
2026 to 2032 the second Wednesday falls *before* Patch Tuesday, so the run would
fire before the patches exist. The third Wednesday is always 1 to 8 days after
it. A test checks that for every month in the range.

### Quiet runs

```powershell
Register-UpdateEverythingTask -WindowStyle Minimized
```

`Hidden` is also accepted, though it still flashes a window briefly as the
process starts, which the module cannot suppress.

`-PromptBeforeRun` forces `Normal` and says so, because a window you cannot see
cannot ask you anything.

### Task settings

The task runs as you, elevated, while you are logged on. `SYSTEM` would not need
you logged in but cannot show a notification, so the summary and restart notice
would go nowhere. `StartWhenAvailable` covers the laptop case. A run missed
while the machine was off happens shortly after your next logon.

| Setting | Value | Reason |
|---|---|---|
| `StartWhenAvailable` | on | Catches up a missed run instead of waiting a whole cycle. |
| `RunOnlyIfNetworkAvailable` | on | Nothing to update without a network. |
| Battery | won't start, stops if unplugged | A full pass is heavy. Override with `-AllowBattery`. |
| `RandomDelay` | 15 min | Spreads the start time. Set with `-RandomDelayMinutes`. |
| `ExecutionTimeLimit` | 2 hours | A wedged installer would otherwise hold the task open until reboot. |
| `MultipleInstances` | `IgnoreNew` | A second run would fight the first for the same managers and logs. |
| `RestartCount` / `RestartInterval` | 2 / 30 min | Transient network failures are the common case. |
| `WakeToRun` | off | `StartWhenAvailable` picks it up once the machine is awake. |

## Repository layout

```
src/UpdateEverything.psd1     module manifest
src/UpdateEverything.psm1     loader, dot-sources Public and Private
src/Public/                   the five exported functions, one per file
src/Private/                  internal helpers, one per file
Install.ps1                   installs the module from a clone
test.ps1                      test runner, used locally and by CI
tests/                        Pester 6 suite
.github/workflows/ci.yml      runs test.ps1 on windows-latest
```

The layout follows [BurntToast](https://github.com/Windos/BurntToast), which
keeps its module under `src` with `Public` and `Private` folders and a loader
that dot-sources both and exports only the public names.

## Development

Requires [Pester 6](https://pester.dev) and PSScriptAnalyzer:

```powershell
Install-Module Pester -MinimumVersion 6.0.0 -Scope CurrentUser -Force -SkipPublisherCheck
```

```powershell
Install-Module PSScriptAnalyzer -Scope CurrentUser
```

`test.ps1` is the entry point CI uses, so a green run locally means a green run
in the pipeline:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\test.ps1
```

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\test.ps1 -Tag Static
```

Tests are tagged `Static`, `Module`, `Docs`, `Unit`, `Consent`, `Prompt`,
`Notification` and `Lint`.

### How the tests work

Running the module's work to test it would elevate, install software and
possibly reboot the machine doing the testing, so the suite never runs it.

The static checks read the source through the PowerShell AST and through
`Get-Command` and `Get-Help`, which report a parameter block and help without
executing a body. They hold the contract. A new parameter fails the suite until
it is documented in both the comment-based help and the table above. So does a
default flipped to reboot without asking. So do two steps sharing a name, which
would overwrite each other's log. A separate test fails on any `exit` anywhere
in the module, since that would end the session of whoever called it.

The behavioural checks dot-source the module's files individually and call the
private helpers directly. File work goes to `TestDrive`, `LOCALAPPDATA` is
redirected there while the Windows Terminal tests run, and registry probes are
mocked. There is no coverage metric, since measuring it means executing the code
under test.

`Set-StrictMode` is left out on purpose. It makes reading a missing property
fatal, and the module has to probe for optional keys in Windows Terminal's
`settings.json`, where those keys are often absent. Turning it on would break
that path on the machines it exists to handle. A test recovers the useful half
instead, walking the AST and failing if any function reads a variable it never
assigns.

## Support

**There is none.** This is a personal maintenance tool published in case it is
useful to someone else. It is not a product, it carries no warranty, and nobody
is obliged to fix it, answer questions, or keep it working.

Issues and pull requests are welcome and may well be read, but no response is
promised and none should be inferred from silence.

### Before your first run

It makes real and sometimes irreversible changes:

- It elevates to Administrator and can install software machine-wide.
- It installs pending Windows and Microsoft updates by default, which can
  require a reboot.
- It installs or upgrades PowerShell 7 by default.
- It edits Windows Terminal's `settings.json` to change the default profile,
  backing the file up into the log directory first.
- It upgrades packages across every manager it finds, which can move pinned
  toolchains. `-UpdateGlobalNpm` is off by default for that reason.

Read the source first, and try the cautious combination:

```powershell
Update-Everything -IncludeWindowsUpdate $false -IncludePowerShell7 $false -SetPwshTerminalDefault $false
```

Every step writes a log, so you can see exactly what happened afterwards.

## License

[MIT](LICENSE). Free to use, copy, modify and redistribute, commercially or
otherwise, provided the copyright notice and license text come along. The
software is provided as is, without warranty of any kind.
