# PowerShell-Update-Script

`Update-Everything.ps1` updates a Windows machine through every package manager
and update channel it can find, running each one as an isolated step so a single
failure does not stop the rest.

## Quick start

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\Update-Everything.ps1
```

Skip the OS update pass:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\Update-Everything.ps1 -IncludeWindowsUpdate $false
```

Run without elevating, reporting admin-only steps as skipped:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\Update-Everything.ps1 -SkipElevation
```

Requires PowerShell 5.1 or later. The script relaunches itself elevated unless
`-SkipElevation` is passed.

### Execution policy

`-ExecutionPolicy Bypass` applies to that one process, changes no machine
setting, and is why every example here uses the long form. Without it, a machine
set to `AllSigned` or `Restricted` refuses the script before it runs:

```
File ...\Update-Everything.ps1 cannot be loaded. The file is not digitally signed.
```

Windows PowerShell (`powershell`) and PowerShell 7 (`pwsh`) hold separate
policies, so one may refuse a script the other runs. Check with
`Get-ExecutionPolicy -List`. If `pwsh` is not installed, substitute `powershell`
in any command below.

## Parameters

| Parameter | Default | Effect |
|---|---|---|
| `-IncludeWindowsUpdate` | `$true` | Install pending updates via PSWindowsUpdate, scanning Microsoft Update so Office and other Microsoft products come along with the OS and drivers. Needs admin; may require a reboot. |
| `-IncludePowerShell7` | `$true` | Install or upgrade PowerShell 7. The machine-wide MSI install needs admin. |
| `-SetPwshTerminalDefault` | `$true` | Point Windows Terminal's default profile at PowerShell 7. Per-user; skipped if Terminal is not installed. |
| `-AutoReboot` | off | Let Windows Update reboot on its own. Off by default; the script reports a pending reboot instead. |
| `-IncludePrerelease` | off | Include prerelease builds where supported (currently PowerShell module updates). |
| `-UpdateGlobalNpm` | off | Upgrade global npm packages as well as npm itself. Off by default because global upgrades can break pinned toolchains. |
| `-SkipElevation` | off | Never relaunch elevated. Steps needing admin are reported as skipped. |
| `-PromptBeforeRun` | off | Pause before starting and offer: run now, skip, or wait. Takes the default after `-PromptTimeoutSeconds`. |
| `-PromptTimeoutSeconds` | `60` | How long that prompt waits before starting anyway. |
| `-DelayMinutes` | `60` | How long the "wait, then run" answer waits. |
| `-Notify` | off | Show a toast when the run finishes, plus an urgent one if a restart is needed. Intended for scheduled runs. |
| `-AllowInstall` | *(none)* | Which missing components may be installed: `All`, or any of `PowerShell7`, `PSWindowsUpdate`, `NuGetProvider`, `BurntToast`. |
| `-LogRetentionDays` | `30` | Prune logs and settings.json backups older than this. `0` keeps everything. |

### Exit codes

| Code | Meaning |
|---|---|
| `0` | Every step succeeded or was skipped |
| `1` to `63` | That many steps failed. Steps finishing with warnings do not count |
| `64` | Nothing ran, because the script could not become Administrator |

`64` sits outside the step-count range so a wrapper can tell "did not run" from
"ran, and something failed".

## Channels covered

Each step runs only if its tool is on the machine. The summary lists the rest as
skipped:

winget (self-update, then all sources) · Microsoft Store apps · PowerShell 7 ·
Microsoft 365 Apps (OfficeC2RClient) · PowerShell modules and help ·
Python Install Manager · uv · pipx · npm · .NET global tools · .NET workloads ·
Chocolatey · Scoop · rustup · GitHub CLI extensions · WSL kernel ·
Defender signatures · Windows Terminal default profile · Windows Update

## Running without administrator rights

The script checks whether it can elevate before it asks. An account outside the
local Administrators group, or a machine with UAC switched off, stops with exit
`64` instead of raising a consent prompt that cannot succeed:

```
WARNING: Cannot run elevated: This account is not a member of the local
Administrators group, so Windows will not grant elevation.
WARNING: Nothing has been changed. Re-run with -SkipElevation to run the steps
that do not need administrator rights.
```

Sometimes membership cannot be determined. A domain group nested inside local
Administrators does it, so does a group the script cannot read. In that case it
tries to elevate anyway. Treating "unknown" as "no" would lock out real
administrators, which is the worse mistake.

With `-SkipElevation`, the run proceeds and the admin-only steps (Windows
Update, Defender signatures, the PowerShell 7 install) are reported as skipped
rather than failing on permissions.

The elevated relaunch passes `-ExecutionPolicy Bypass` itself, so only the first
launch is subject to your policy.

## Logs

The script writes logs to the first writable location among `%USERPROFILE%`,
`%LOCALAPPDATA%`, `%TEMP%` and the script directory, under `UpdateLogs\`:

- `Update-Everything-<timestamp>.log`, the transcript of the whole run
- `<step>-<timestamp>.log`, every stream from that one step

`UpdateLogs/` and `*.log` are gitignored, so a run inside a clone stays clean.

Many CLIs write ordinary progress to stderr, so a step earns `Warning` only when
PowerShell itself raises an error record.

## Installing versus updating

Updating something already installed needs no permission. Installing something
that was never there does, and the script will not do it silently.

| Component | Installs | Scope | Needed for |
|---|---|---|---|
| `PowerShell7` | PowerShell 7 via winget (MSI) | machine-wide | `-IncludePowerShell7` |
| `PSWindowsUpdate` | The PSWindowsUpdate module | **all users** | `-IncludeWindowsUpdate` |
| `NuGetProvider` | The NuGet package provider | current user | reaching the PowerShell Gallery |
| `BurntToast` | The BurntToast module | current user | `-Notify` |

Without `-AllowInstall`, an interactive run asks before each one and defaults to
*No*:

```
Install PSWindowsUpdate?
The PSWindowsUpdate module is not installed. Windows Update cannot be driven
without it. This would install it from the PowerShell Gallery for all users on
this machine.

This is a first-time install, not an update.
[Y] Yes  [N] No  (default is "N"):
```

A non-interactive run never prompts and never installs. There is nobody to ask,
so it declines and reports the step as skipped. Approve in advance instead:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\Update-Everything.ps1 -AllowInstall PSWindowsUpdate,BurntToast
```

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\Update-Everything.ps1 -AllowInstall All
```

The script asks about each component at most once per run. A declined install
skips its step rather than failing it, so it stays out of the exit code.

## Notifications

`-Notify` raises two Windows toasts: a summary when the run finishes, and a
restart notice marked *urgent* when Windows is waiting on a reboot. Urgent
notifications break through Focus Assist; ordinary ones do not.

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\Update-Everything.ps1 -Notify
```

Notifications need the [BurntToast](https://github.com/Windos/BurntToast)
module:

```powershell
Install-Module BurntToast -Scope CurrentUser
```

It is an optional dependency. If the module is missing, or the run has no
interactive desktop session, the update run proceeds as normal and you are told
in three places: when registering the scheduled task, at the start of the run,
and again in the closing summary.

```
[!] Notifications were requested but could not be sent.
    Reason: the BurntToast module is not installed. Install it with
    "Install-Module BurntToast -Scope CurrentUser", or re-run with
    -AllowInstall BurntToast.
    The update run itself was unaffected.
```

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
- **Skip.** Nothing changes and the script exits 0. The next scheduled run
  stands.
- **Wait.** Sleeps `-DelayMinutes`, then runs.

Silence counts as run now. An unanswered prompt usually means nobody is at the
machine, which is when the updates matter most. If the run cannot prompt at all,
because there is no console or input is redirected, it says so and starts
straight away rather than blocking.

## Running on a schedule

`Register-UpdateTask.ps1` creates a Windows scheduled task. Registering needs an
elevated session, since the task itself runs with the highest privileges. This
opens one and keeps it open so you can read the result, and works from any
directory:

```powershell
Start-Process pwsh -Verb RunAs -ArgumentList '-NoExit','-NoProfile','-ExecutionPolicy','Bypass','-File','D:\PowerShell-Update-Script\Register-UpdateTask.ps1','-Cadence','Weekly'
```

Substitute your own path to the repository. Other cadences:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\Register-UpdateTask.ps1 -Cadence PatchTuesday
```

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\Register-UpdateTask.ps1 -Cadence Weekly -DayOfWeek Saturday -At 09:00
```

Inspecting and removing need no elevation:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\Register-UpdateTask.ps1 -Show
```

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\Register-UpdateTask.ps1 -Unregister
```

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
pwsh -NoProfile -ExecutionPolicy Bypass -File .\Register-UpdateTask.ps1 -WindowStyle Minimized
```

`Hidden` is also accepted, though it still flashes a window briefly as the
process starts, which the script cannot suppress.

`-PromptBeforeRun` forces `Normal` and says so, because a window you cannot see
cannot ask you anything:

```
WARNING: -PromptBeforeRun needs a visible window, so -WindowStyle Hidden is
being ignored and the task will run Normal.
```

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
Update-Everything.ps1                              the script
Register-UpdateTask.ps1                            registers it as a scheduled task
test.ps1                                           test runner, used locally and by CI
PSScriptAnalyzerSettings.psd1                      lint rules (5.1 + 7.0 compatibility)
tests/Update-Everything.Tests.ps1                  static contract: parameters, help, docs, guard
tests/Update-Everything.Functions.Tests.ps1        logging, steps, reboot detection, elevation
tests/Set-PwshAsWindowsTerminalDefault.Tests.ps1   the settings.json rewrite, in a sandbox
tests/Register-UpdateTask.Tests.ps1                cadences, triggers and task settings
tests/Notification.Tests.ps1                       toast behaviour, with BurntToast stubbed
tests/InstallConsent.Tests.ps1                     the first-time-install consent gate
tests/RunPrompt.Tests.ps1                          the pre-run prompt and window styles
.github/workflows/ci.yml                           runs test.ps1 on windows-latest
```

## Development

Requires [Pester 6](https://pester.dev) and PSScriptAnalyzer:

```powershell
Install-Module Pester -MinimumVersion 6.0.0 -Scope CurrentUser -Force -SkipPublisherCheck
Install-Module PSScriptAnalyzer -Scope CurrentUser
```

`test.ps1` is the entry point CI uses, so a green run locally means a green run
in the pipeline:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\test.ps1                   # everything
pwsh -NoProfile -ExecutionPolicy Bypass -File .\test.ps1 -Tag Static       # script contract only
pwsh -NoProfile -ExecutionPolicy Bypass -File .\test.ps1 -ExcludeTag Lint  # skip the analyzer pass
pwsh -NoProfile -ExecutionPolicy Bypass -File .\test.ps1 -CI               # non-zero exit on failure
```

Tests are tagged `Static`, `Docs`, `Unit`, `Consent`, `Prompt`, `Notification`
and `Lint`.

### How the tests work

Running the script to test it would elevate, install software and possibly
reboot the machine doing the testing, so the suite never runs it.

The static checks read the script through the PowerShell AST and through
`Get-Command` and `Get-Help`, which report a parameter block and help without
executing the body. They hold the contract. A new parameter fails the suite
until it is documented in both the comment-based help and the table above. So
does a default flipped to reboot without asking. So do two steps sharing a name,
which would overwrite each other's log.

The behavioural checks dot-source the script and call its functions. That is
safe because of the dot-source guard, so

```powershell
. .\Update-Everything.ps1
```

loads the functions and returns without updating anything. A static test asserts
the guard exists, that every statement above it is a function definition, and
that no `Invoke-Step` call precedes it.

File work goes to `TestDrive`, `LOCALAPPDATA` is redirected there while the
Windows Terminal tests run, and registry probes are mocked. There is no coverage
metric, since measuring it means executing the code under test.

`Set-StrictMode` is left out on purpose. It makes reading a missing property
fatal, and the script has to probe for optional keys in Windows Terminal's
`settings.json`, where those keys are often absent. Turning it on would break
that path on the machines it exists to handle. A test recovers the useful half
instead, walking the AST and failing if the script reads a variable it never
assigns.

## Support

**There is none.** This is a personal maintenance script published in case it is
useful to someone else. It is not a product, it carries no warranty, and nobody
is obliged to fix it, answer questions, or keep it working.

Issues and pull requests are welcome and may well be read, but no response is
promised and none should be inferred from silence.

### Before your first run

The script makes real and sometimes irreversible changes:

- It elevates to Administrator and can install software machine-wide.
- It installs pending Windows and Microsoft updates by default, which can
  require a reboot.
- It installs or upgrades PowerShell 7 by default.
- It edits Windows Terminal's `settings.json` to change the default profile,
  backing the file up into the log directory first.
- It upgrades packages across every manager it finds, which can move pinned
  toolchains. `-UpdateGlobalNpm` is off by default for that reason.

Read the script first, and try the cautious combination:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\Update-Everything.ps1 -IncludeWindowsUpdate $false -IncludePowerShell7 $false -SetPwshTerminalDefault $false
```

Every step writes a log, so you can see exactly what happened afterwards.

## License

[MIT](LICENSE). Free to use, copy, modify and redistribute, commercially or
otherwise, provided the copyright notice and license text come along. The
software is provided as is, without warranty of any kind.
