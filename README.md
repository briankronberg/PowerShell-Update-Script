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

**The gallery carries minor versions only** -- 1.2.0, 1.3.0, 1.4.0. A patch
release such as 1.2.1 is published here and nowhere else, so this is the
supported way to get a fix that has landed but is not in a minor release yet.

`main` also carries whatever is being worked on. Nothing but the URL is
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
is an overwrite of a version by the same version, and stops without it. On a first install
it does nothing; on every one after, it is what makes the line safe to paste
again. Nothing is lost if it is interrupted: the installer stages the new copy
and validates it before it replaces the old one.

`Update-Everything -UpdateSelf -UpdateSelfSource Main` does the same thing as
a command: with `-UpdateSelf` the run updates this module and does nothing
else. The default source is `Gallery`, which is right for most people and
wrong for anyone tracking a patch.

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
| `Initialize-UpdateEverything` | Setup menu: prerequisites, scheduled task, developer tools, first run |
| `Register-UpdateEverythingTask` | Registers the scheduled task. Needs elevation |
| `Get-UpdateEverythingTask` | Reports every task that runs this module, or nothing if there are none |
| `Unregister-UpdateEverythingTask` | Removes the task |
| `Test-PendingReboot` | Reports whether Windows is waiting on a restart, and why |

`Update-All` is an alias for `Update-Everything`.

## Setting up

```powershell
Initialize-UpdateEverything
```

A menu, for a machine that has just had the module installed:

```
UpdateEverything setup

  1. Run prerequisites only (PowerShell 7, notifications, gallery tooling)
  2. Set up a scheduled task
  3. Install developer tools
  4. Perform a full first run
  5. Exit

Choose [1-5]:
```

Typed numbers rather than arrow keys, so it needs no extra module, works over a
remote session and in a host with no cursor control, and can be tested without
simulating key events. The menu repeats until you choose Exit.

`-Choice` takes one option and returns, for a caller that already knows what it
wants:

```powershell
Initialize-UpdateEverything -Choice DeveloperTools
```

### Scheduled tasks

Option 2 lists what is already registered and offers to add another, replace
one, or remove one.

**Another task, not another trigger.** Every trigger on a task runs the same
action, so two triggers cannot express "everything but Python daily, only Python
weekly" — which is the reason for wanting a second run at all. Something pinned
to a version another application depends on wants its own schedule, not the one
that keeps everything else current:

```powershell
Register-UpdateEverythingTask -TaskName 'Update-Everything' -ExcludeTag Python -Cadence Daily
Register-UpdateEverythingTask -TaskName 'Update-Everything-Python' -Tag Python -Cadence Weekly
```

`Get-UpdateEverythingTask` finds all of them, **by what they run rather than by
what they are called**. A task renamed by hand is still this module's task, and a
task called `Update-Everything` that runs something else is not — which matters,
because removing it because of its name would be destructive.

### Developer tools

Option 3 is the one deliberate exception to "this module updates, it does not
install". On a fresh machine the honest first question is why nothing is
installed, and the answer is a script everyone writes once and badly.

```
  1. Git                           Version control
  2. Python                        Python, through the Install Manager this module updates
  3. Node.js LTS                   JavaScript runtime, with npm
  4. VS Code                       Editor
  5. Windows Terminal              Terminal this module can set a default profile on
  6. PowerShell 7      installed   PowerShell 7, MSI build so it can elevate
  ...
```

You pick numbers; nothing else is installed. A tool already on PATH is marked
and skipped, because the update run covers it from then on.

**The catalogue is not an `-AllowInstall` component, and `-AllowInstall All`
cannot reach it.** `All` means "approve the components this update run needs" —
six named things, each a prerequisite for updating something else. Letting it
also mean "install a dozen developer tools" would turn an unattended scheduled
task from a maintenance job into a provisioning one, through a flag people
already have in their task definitions.

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
| `-IncludePowerShellModules` | `$true` | Update every installed PowerShell module. Set to `$false` when one is pinned to a version something else depends on. |
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
| `-UpdateSelf` | off | Update this module through `Update-Module` and run nothing else. `-Tag`/`-ExcludeTag` are ignored; no UAC prompt is raised, and an all-users copy is reported as needing an elevated session. Takes effect on the **next** run: the module is already loaded, so the files change and the running code does not. |
| `-UpdateSelfSource` | `Gallery` | Where `-UpdateSelf` gets it from. `Gallery` is the newest published release; `Main` is the development head, fetched from GitHub. |

## Selecting steps

`-Tag` and `-ExcludeTag` narrow a run to part of the work. A step carries one or
more of:

`Windows` `Microsoft` `PowerShell` `PackageManager` `Python` `Node` `DotNet`
`Rust` `Go` `Cloud` `Git` `Self` `Inventory`

```powershell
Update-Everything -Tag Python
Update-Everything -ExcludeTag Python
```

Every run opens by naming the version that produced it, so a transcript can be
read against the code that made it:

```
Maintenance run started 09/01/2026 08:14  |  Admin: True  |  Main Log: ...
UpdateEverything 1.5.0
```

The Inventory step then compares that against the gallery:

```
UpdateEverything 1.5.0 is running, which is the newest published version.
```

The comparison lives there rather than in the banner because it costs a network
call, and `-ExcludeTag Inventory` turns it off for a scheduled run that does not
want one. A gallery it could not reach says so rather than claiming currency, and
a copy installed from GitHub — which is often *ahead* of the gallery — is never
called out of date.

`-Tag Inventory` reports what the machine has and updates nothing, which is the
quickest way to see why a run skipped what it skipped:

```
12 of 24 tools present.

  winget           Unknown     v1.29.290
  PowerShell 7     Unknown     PowerShell 7.6.5
  uv               Standalone  uv 0.12.7

Not installed: .NET SDK, Azure CLI, Bun, Chocolatey, conda, Deno, Google Cloud CLI, gup, pipx, pnpm, rustup, Scoop
Their steps report Skipped, which is the expected result rather than a fault.

WARNING: PowerShell 7 is installed in 2 places; the first is the one that runs:
         C:\Program Files\PowerShell; ...\WindowsApps
```

That last warning is worth reading. A tool installed twice is updated by
whichever manager owns the copy you are not running.

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
Register-UpdateEverythingTask -Tag Python -Cadence PatchTuesday
```

## What it updates

The module keeps no list of software. It drives the update tools already on the
machine, so what gets updated is whatever those tools manage. Every step looks
for its tool with `Get-Command` first and reports `Skipped` when it finds
nothing. It never installs a tool just to make a step possible.

So the answer comes in two halves. Some products it updates by name. For the
rest, a package manager's own inventory decides.

### When winget leaves something behind

`winget upgrade --all` returns one exit code for the whole pass, so a partial
failure says only that *something* did not upgrade. The step names them, and
separates three cases:

```
Still out of date after this run:
  astral-sh.uv 0.11.19 -> 0.12.7  (the install failed; a file was in use,
                                   so close the program and run again)

Not upgradable on this machine, and expected to stay that way:
  Cisco.CiscoWebexMeetings 45.6.4 -> 45.6.4.8  (winget listed it and did not
                                   attempt it, usually because the newer
                                   package does not apply to this system)

Newly listed during this run; the next run picks these up:
  Some.Package 1.0 -> 1.1
```

The distinction matters. The first is worth doing something about; the second
will not change until the vendor ships a package that applies, and reporting it
as a failure on every run is how people learn to skim past the ones that are.
The third only appeared in the closing table, so the next run is when it moves.

**The step is marked `Warning` only when something may really have failed** — a
package winget attempted, or a non-zero exit it could not attribute to one. A
package it declined is not a fault of the run and does not colour it.

### Products updated by name

| Product | How it updates |
|---|---|
| Windows itself, with drivers and the servicing stack | `Get-WindowsUpdate -AcceptAll -Install` through PSWindowsUpdate. It registers the Microsoft Update service first, which widens the scan from Windows alone to Office, Visual Studio and other Microsoft products. Needs administrator rights. |
| Microsoft 365 Apps, meaning Word, Excel, Outlook, PowerPoint, Teams and OneNote | `OfficeC2RClient.exe /update user`, the same action as the Update Now button without the prompts. Click-to-run does the work in the background, so the step reports "requested" rather than "applied". |
| Microsoft Store apps | The `msstore` source, covered by `winget upgrade --all`. |
| Microsoft Defender antivirus signatures | `Update-MpSignature`. It skips when a third-party antivirus has taken over, which it detects by asking `Get-MpComputerStatus` whether the antimalware service is on. Otherwise a managed machine would report a failed step every run. |
| PowerShell 7 | winget. A fresh install is forced to the MSI with `--installer-type wix`, and only with your consent; an existing copy upgrades in place as whatever package it already is, so an MSIX copy stays MSIX and the step prints how to switch. |
| PowerShell modules from the Gallery | `Update-PSResource -Name *` where PSResourceGet exists, otherwise `Update-Module`. |
| PowerShell help | `Update-Help`, pinned to `en-US` under any other UI culture, where most modules publish no help at all. |
| PowerShell Gallery tooling | `PowerShellGet`, `PSResourceGet` and the NuGet package provider, which every other gallery step runs on. A copy the host shipped cannot be updated in place, so moving it forward is a side-by-side install and asks first. |
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
| winget | `winget` on `PATH` | `winget source update --disable-interactivity`, then `winget upgrade --all --include-unknown --silent --accept-source-agreements --accept-package-agreements --disable-interactivity` | Desktop applications from the winget community repository and the Microsoft Store. The broadest step by far, covering browsers, editors, runtimes and drivers shipped as apps. The `--accept-*` flags accept source and vendor licence agreements on your behalf. |
| Chocolatey | `choco` | `choco upgrade all -y` | Everything installed as a Chocolatey package. Exit codes 1641 and 3010 pass, since those are the MSI "reboot required" codes rather than failures. |
| Scoop | `scoop` | `scoop update`, `scoop update *`, `scoop cleanup *`, each run on its own | Scoop, its buckets, installed apps, then old versions. The phases run separately so a broken bucket cannot hide the rest. |
| npm | `npm` | `npm install -g npm@latest`, then `npm update -g` only with `-UpdateGlobalNpm` | npm itself, every run. Global packages only on request, because upgrading them can move a pinned toolchain. |
| Deno | `deno`, plus an ownership check | `deno upgrade` | Deno itself, when nothing else owns it. |
| Bun | `bun`, plus an ownership check | `bun upgrade` | Bun itself, when nothing else owns it. |
| pnpm | `pnpm`, plus an ownership check | `pnpm self-update` | The standalone pnpm only. A Corepack-managed pnpm is pinned per project and left to Corepack. |
| pip | `py`, else `python` | `<interpreter> -m pip install --upgrade pip --disable-pip-version-check` | pip itself, for the first of those found. Where `py` is present that is the launcher's default interpreter, which is not always the `python` on `PATH`. Installed packages are left alone -- see [Python](#python). |
| pipx | `pipx` | `pipx upgrade-all` | Every Python application pipx installed. |
| uv | `uv`, plus an ownership check | `uv self update` | uv itself, and only when nothing else owns it. |
| conda | `conda` | `conda update --name base conda --yes` | conda itself, in the base environment. Environment packages are left alone for the same reason pip's are -- see [Python](#python). |
| Python Install Manager | `pymanager`, else a `py` that answers `py help install` | `pymanager install --update`, or `py install --update` through the Install Manager's `py` alias | Installed Python runtimes. The classic `py` launcher cannot update runtimes, so a machine that has only it reports Skipped. |
| .NET SDK | `dotnet`, plus an SDK version of 6 or higher | `dotnet tool update --all --global`, falling back to updating each tool by name | Global .NET tools. `dotnet` exists for runtime-only installs too, so the step confirms the SDK before using it. |
| .NET workloads | `dotnet` | `dotnet workload update` | MAUI, Android, iOS and WASM workloads. |
| rustup | `rustup` | `rustup update` | Every installed Rust toolchain. |
| cargo binaries | `cargo`, plus the `cargo-update` crate | `cargo install-update --all` | Every binary `cargo install` put on the machine. Skips naming `cargo install cargo-update` when the subcommand is absent. |
| Go binaries | `go`, plus `gup` | `gup update` | Every binary `go install` put in `GOBIN`. Skips naming `go install github.com/nao1215/gup@latest` when gup is absent. |
| Azure CLI | `az` | `az upgrade --yes --only-show-errors` | The CLI and its installed extensions. Reruns the MSI, so it needs administrator rights. Tagged `Cloud`: `-ExcludeTag Cloud` drops it on a metered or offline machine. |
| Google Cloud CLI | `gcloud`, plus an ownership check | `gcloud components update --quiet` | Every installed component of the bundled install. A Chocolatey or Scoop gcloud disables its own component manager and is left to that manager. Tagged `Cloud`. |
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

### Python

Five steps, and they cover different things:

| Step | Updates |
|---|---|
| `Python (Install Manager)` | the Python runtimes |
| `pip` | pip itself, for the first of `py`, `python` found |
| `uv` | uv itself, and only when no package manager owns it |
| `pipx packages` | isolated CLI applications |
| `conda` | conda itself, in the base environment |

**Installed packages are deliberately left alone**, and conda environments with
them. pip has no `upgrade-all`, and
the usual recipe — list outdated, upgrade each — does not keep the dependency set
consistent, because upgrading one package can silently downgrade another's
dependency. That is the problem `pipx` and `uv` exist to solve by isolating, and
both have their own steps.

**An active virtual environment is never touched.** If `VIRTUAL_ENV` is set the
step reports skipped and says so: those packages belong to whatever project made
the environment, not to the machine.

Only one interpreter's pip is updated: the launcher's default when `py` is
present, else the `python` on `PATH`. Others the launcher knows about are named
in the output and left alone — upgrading pip in every Python on a machine is a
larger claim than a maintenance run should make on its own.

pip is upgraded through `python -m pip`, never the bare `pip.exe`: on Windows pip
cannot replace its own running executable, so the direct form fails on a locked
file.

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
Update, Defender signatures, the PowerShell 7 install, the Azure CLI) are
reported as skipped
rather than failing on permissions.

## Logs

The module writes logs to the first writable location among `%USERPROFILE%`,
`%LOCALAPPDATA%`, `%TEMP%` and the module directory, under `UpdateLogs\`:

- `Update-Everything-<timestamp>.log`, the transcript of the whole run
- `<step>-<timestamp>.log`, every stream from that one step. Progress repaints
  — bars, spinner ticks, bare percentages — are dropped, so a redrawing download
  does not arrive as a column of noise

Many CLIs write ordinary progress to stderr, so a step earns `Warning` only when
PowerShell itself raises an error record.

### An error appears twice in the transcript

One error, two identical blocks in `Update-Everything-<timestamp>.log`. **This is
one error, not two.** The step log holds one copy and the summary counts one, so
trust those; the count in `COMPLETED WITH ERRORS: <step> (N error record(s))` is
right.

PowerShell transcribes an error record when it is raised, whatever the pipeline
then does with it, and transcribes it again when it is displayed. Both are the
same error arriving by two routes.

It is left alone deliberately. Measured, with a marker in the error text:

| | console | transcript |
|---|---|---|
| as it is | **visible** | 2 |
| error records kept out of the display | **nothing** | 1 |

The raise-time transcript entry comes with no console rendering, so removing the
duplicate would make every error invisible to whoever is watching the run. Two
lines in a log is the cheaper problem.

Only the error stream does this. Output, warnings, verbose and native stdout all
appear once.

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
