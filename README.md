# UpdateEverything

A PowerShell module that updates a Windows machine through every package manager
and update channel it can find, running each as an isolated step so a single
failure does not stop the rest. It can also register itself as a scheduled task
and tell you what happened with a toast notification.

## Install

From the PowerShell Gallery:

```powershell
Install-Module UpdateEverything -Scope CurrentUser
```

Then:

```powershell
Import-Module UpdateEverything
```

`-Scope AllUsers` installs machine-wide and needs elevation. `Update-Module
UpdateEverything` moves to the next published release.

Requires PowerShell 5.1 or later on Windows 10 or a matching Server release.

### Install from GitHub

The gallery carries releases. `main` carries what is being worked on, which is
where to get a fix that has landed but not shipped. Nothing but the URL is
needed:

```powershell
$i = Join-Path $env:TEMP 'Install-UpdateEverything.ps1'; Invoke-WebRequest https://raw.githubusercontent.com/briankronberg/UpdateEverything/main/Install.ps1 -OutFile $i -UseBasicParsing; Unblock-File $i; powershell -NoProfile -ExecutionPolicy Bypass -File $i -Force
```

It downloads the installer, which fetches the module from GitHub and installs it
into your own module path. No elevation, and it prints what it exported. Add
`-Scope AllUsers` to install machine-wide, which does need elevation.

`-Force` is in the command because the module installs into a folder named for
its version, and the installer refuses to overwrite one that is already there.
The version does not change with every commit, so a second install from `main`
is an overwrite of `1.0.0` by `1.0.0` and stops without it. On a first install
it does nothing; on every one after, it is what makes the line safe to paste
again. Nothing is lost if it is interrupted: the installer stages the new copy
and validates it before it replaces the old one.

`Update-Everything -UpdateSelf` does the same thing from inside a run, and also
tracks `main` rather than the gallery.

### Why that command is shaped the way it is

It is one line so it survives a copy and paste, but each piece is load-bearing.

`Unblock-File` clears the mark of the web that Windows puts on a download, which
an execution policy of `RemoteSigned` would otherwise refuse. `-ExecutionPolicy
Bypass` covers the stricter `AllSigned`, and applies to that one process only.

The file is downloaded and then run, rather than piped through
`Invoke-Expression`. The shorter `irm ... | iex` idiom is widely published and
does not work on a machine with Defender's attack surface reduction turned on,
because the block is on the command line text rather than on what the command
does:

```
pwsh -Command '"harmless"'                          runs
pwsh -Command 'irm https://example.com | Out-Null'  runs
pwsh -Command '$x = "irm" + " | iex"; "ok"'         Access is denied
```

The last one only builds a string, and Windows still refuses to create the
process.

From a clone instead:

```powershell
git clone https://github.com/briankronberg/UpdateEverything.git
```

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\UpdateEverything\Install.ps1 -Force
```

Add `-FromGitHub` to install what is published rather than what is in the
working copy.

To load it without installing, point `Import-Module` at the source:

```powershell
Import-Module .\UpdateEverything\src\UpdateEverything.psd1
```

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
| `-AllowInstall` | *(none)* | Which missing components may be installed: `All`, or any of `PowerShell7`, `PSWindowsUpdate`, `NuGetProvider`, `BurntToast`, `PowerShellGet`, `PSResourceGet`. |
| `-Tag` | *(all)* | Run only the steps carrying one of these tags. Everything else is reported as skipped. |
| `-ExcludeTag` | *(none)* | Run everything except the steps carrying one of these tags. Exclusion wins when both are given. |
| `-LogRetentionDays` | `30` | Prune logs and settings.json backups older than this. `0` keeps everything. |
| `-UpdateSelf` | off | Reinstall this module from GitHub first, whether or not the version differs. Takes effect on the **next** run: the module is already loaded, so the files change and the running code does not. Off by default because it fetches and runs an installer from a branch. |

## Selecting steps

`-Tag` and `-ExcludeTag` narrow a run to part of the work. A step carries one or
more of:

`Windows` `Microsoft` `PowerShell` `PackageManager` `Python` `Node` `DotNet`
`Rust` `Git` `Self`

```powershell
Update-Everything -Tag Python
Update-Everything -ExcludeTag Python
```

Both may be given at once and exclusion wins, so `-Tag Python -ExcludeTag Node`
is not a contradiction and `-Tag Python -ExcludeTag Python` selects nothing
rather than erroring.

A step ruled out this way is reported as `Skipped` with the reason rather than
dropped, so the summary still accounts for every step and the count does not
quietly change between runs.

The point is two scheduled tasks dividing the work. Something pinned to a
version another application depends on wants updating on its own schedule, not
on the one that keeps everything else current:

```powershell
Register-UpdateEverythingTask -ExcludeTag Python -Cadence Daily
Register-UpdateEverythingTask -Tag Python -Cadence Monthly
```

## What it updates

The module keeps no list of software. It drives the update tools already on the
machine, so what gets updated is whatever those tools manage. Every step looks
for its tool with `Get-Command` first and reports `Skipped` when it finds
nothing. It never installs a tool just to make a step possible.

So the answer comes in two halves. Some products it updates by name. For the
rest, a package manager's own inventory decides.

### Products updated by name

| Product | How it updates |
|---|---|
| Windows itself, with drivers and the servicing stack | `Get-WindowsUpdate -AcceptAll -Install` through PSWindowsUpdate. It registers the Microsoft Update service first, which widens the scan from Windows alone to Office, Visual Studio and other Microsoft products. Needs administrator rights. |
| Microsoft 365 Apps, meaning Word, Excel, Outlook, PowerPoint, Teams and OneNote | `OfficeC2RClient.exe /update user`, the same action as the Update Now button without the prompts. Click-to-run does the work in the background, so the step reports "requested" rather than "applied". |
| Microsoft Store apps | The `msstore` source, covered by `winget upgrade --all`. |
| Microsoft Defender antivirus signatures | `Update-MpSignature`. It skips when a third-party antivirus has taken over, which it detects by asking `Get-MpComputerStatus` whether the antimalware service is on. Otherwise a managed machine would report a failed step every run. |
| PowerShell 7 | winget, forced to the MSI package with `--installer-type wix`. It installs only with your consent and upgrades in place when it is already there. |
| PowerShell modules from the Gallery | `Update-PSResource -Name *` where PSResourceGet exists, otherwise `Update-Module`. |
| PowerShell help | `Update-Help`, pinned to `en-US` under any other UI culture, where most modules publish no help at all. |
| WSL, both the Linux kernel and the platform | `wsl --update`, once `wsl --status` confirms WSL is enabled. `wsl.exe` ships on every Windows 11 machine, so finding it proves nothing. |
| winget itself, packaged as App Installer | It asks for App Installer by ID, because `upgrade --all` does not reliably update the tool running the upgrade. |
| Windows Terminal | Not an update. It can set PowerShell 7 as the default profile, backing up `settings.json` first. |

One more step shows up in every summary without updating anything. `Trust
PSGallery` marks the PowerShell Gallery as trusted, because it ships untrusted
and every module update otherwise stops on a confirmation prompt that
`-ErrorAction SilentlyContinue` cannot suppress. The setting is per user and
survives elevation, so it sticks after the first run.

### Package managers it drives

Whatever these manage on your machine is what they update. The module does not
choose the packages; the manager's own inventory does.

| Manager | Found by | What runs | Covers |
|---|---|---|---|
| winget | `winget` on `PATH` | `winget source update`, then `winget upgrade --all --include-unknown --silent` | Desktop applications from the winget community repository and the Microsoft Store. The broadest step by far, covering browsers, editors, runtimes and drivers shipped as apps. |
| Chocolatey | `choco` | `choco upgrade all -y` | Everything installed as a Chocolatey package. Exit codes 1641 and 3010 pass, since those are the MSI "reboot required" codes rather than failures. |
| Scoop | `scoop` | `scoop update`, `scoop update *`, `scoop cleanup *`, each run on its own | Scoop, its buckets, installed apps, then old versions. The phases run separately so a broken bucket cannot hide the rest. |
| npm | `npm` | `npm install -g npm@latest`, then `npm update -g` only with `-UpdateGlobalNpm` | npm itself, every run. Global packages only on request, because upgrading them can move a pinned toolchain. |
| pipx | `pipx` | `pipx upgrade-all` | Every Python application pipx installed. |
| uv | `uv`, plus an ownership check | `uv self update` | uv itself, and only when nothing else owns it. |
| Python Install Manager | `pymanager`, else `py` | `pymanager install --update` | Installed Python runtimes. |
| .NET SDK | `dotnet`, plus an SDK version of 6 or higher | `dotnet tool update --all --global`, falling back to updating each tool by name | Global .NET tools. `dotnet` exists for runtime-only installs too, so the step confirms the SDK before using it. |
| .NET workloads | `dotnet` | `dotnet workload update` | MAUI, Android, iOS and WASM workloads. |
| rustup | `rustup` | `rustup update` | Every installed Rust toolchain. |
| GitHub CLI | `gh`, plus a non-empty `gh extension list` | `gh extension upgrade --all` | Installed `gh` extensions. That second check matters, because the upgrade command exits non-zero when nothing is installed. |

### How it decides who owns a tool

Presence is not enough for anything that can update itself. Scoop has to be the
one to update a `uv` that Scoop installed, because `uv self update` fights
whichever manager owns it and the next `scoop update` undoes the result.

`Get-ToolInstallSource` answers the ownership question from where the executable
lives, the only signal it can get without asking every manager on the machine
in turn:

| Path contains | Owner |
|---|---|
| a Scoop `shims` or `apps` directory | Scoop |
| WinGet's `Links` or `Packages` directory | WinGet |
| the Chocolatey `bin` | Chocolatey |
| a Python `Scripts` directory | pip or pipx |
| `~\.local\bin` or `~\bin` | a standalone vendor installer |
| anywhere else | Unknown |

Self-update runs only for `Standalone` and `Unknown`. Anything it can pin on a
manager, it skips, naming that manager in the reason. The summary says why
rather than going quiet.

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
| `PowerShellGet` | PowerShellGet 2.x, replacing the 1.0.0.1 Windows ships | **all users** when elevated, else current user | module updates that see everything installed |

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
Publish.ps1                   validates and publishes to the PowerShell Gallery
test.ps1                      test runner, used locally and by CI
tests/                        Pester 6 suite
CONTRIBUTING.md               the rules, and how the tests have lied before
.github/workflows/ci.yml      runs test.ps1 on windows-latest
```

The layout follows [BurntToast](https://github.com/Windos/BurntToast), which
keeps its module under `src` with `Public` and `Private` folders and a loader
that dot-sources both and exports only the public names.

## Development

[CONTRIBUTING.md](CONTRIBUTING.md) has the rules a change is expected to follow,
why each one exists, and a catalogue of the ways this suite has been green over
broken code. Read it before writing a test.

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
