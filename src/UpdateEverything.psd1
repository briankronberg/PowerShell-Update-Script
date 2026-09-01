@{
    RootModule        = 'UpdateEverything.psm1'
    ModuleVersion     = '1.1.0'
    GUID              = 'e4e1f3eb-5967-4311-94af-c650fe192e95'
    Author            = 'Brian Kronberg'
    Copyright         = '(c) 2026 Brian Kronberg. Released under the MIT License.'
    Description       = 'Updates a Windows machine through every package manager and update channel it can find, running each as an isolated step so one failure does not stop the rest. Covers winget, the Microsoft Store, Windows Update, Microsoft 365 Apps, Defender, PowerShell modules, npm, pipx, uv, Chocolatey, Scoop, rustup, .NET tools and more. Can register itself as a scheduled task with toast notifications.'

    # 5.1 is the floor because the script has always supported Windows PowerShell,
    # and a maintenance tool that cannot run on a machine before it has been
    # updated is not much use.
    PowerShellVersion = '5.1'

    # Declared so the gallery can filter on it, and so a Core-only or
    # Desktop-only consumer is told before installing rather than after.
    CompatiblePSEditions = @('Desktop', 'Core')

    FunctionsToExport = @(
        'Update-Everything'
        'Initialize-UpdateEverything'
        'Register-UpdateEverythingTask'
        'Unregister-UpdateEverythingTask'
        'Get-UpdateEverythingTask'
        'Test-PendingReboot'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @('Update-All')

    PrivateData = @{
        PSData = @{
            Tags         = @('Windows', 'Update', 'Maintenance', 'winget', 'WindowsUpdate', 'Chocolatey', 'Scoop', 'ScheduledTask', 'PSEdition_Desktop', 'PSEdition_Core')
            LicenseUri   = 'https://github.com/briankronberg/UpdateEverything/blob/main/LICENSE'
            ProjectUri   = 'https://github.com/briankronberg/UpdateEverything'
            ReleaseNotes = '# 1.1.0

Adds a setup menu, step selection by tag, and an inventory of what the machine
actually has. Fixes three defects that shipped in 1.0.0.

## Fixed

* -Cadence PatchTuesday could not register a task at all, on either edition.
  Register-ScheduledTask will not accept a client-only monthly trigger, so the
  task is now registered and its XML rewritten.
* A caller whose session set $ErrorActionPreference to Stop got failed steps
  from tools that write to stderr as a matter of course -- npm, winget, wsl.
  Each step threw before reaching the exit-code check written to handle it.
* The gallery tooling (NuGet provider, PowerShellGet, PSResourceGet) was
  installed when missing and then never brought forward.

## Selecting steps

-Tag and -ExcludeTag narrow a run. Both are accepted by
Register-UpdateEverythingTask, so one machine can carry a daily task that skips
a toolchain and a monthly one that updates only it -- for something pinned to a
version another application depends on.

Tags: Windows, Microsoft, PowerShell, PackageManager, Python, Node, DotNet,
Rust, Git, Self, Inventory.

## Initialize-UpdateEverything

A setup menu: prerequisites, scheduled task, developer tools, or a full first
run. Typed numbers, no new dependency. A first run now says it exists.

The developer-tools catalogue is the one exception to "this module updates, it
does not install", and it is reachable only from the menu. -AllowInstall All
does not reach it: All approves the components a run needs, and widening it to a
dozen developer tools would turn an unattended task into a provisioning job.

## Reporting

* An Inventory step reports what is installed, at what version, and who owns it,
  so a first run is not an unexplained column of skips. -Tag Inventory reports
  and updates nothing.
* The module pass says what moved rather than only that it finished.
* Get-UpdateEverythingTask returns every task that runs this module, found by
  what they run rather than by what they are called.

## Also

* -IncludePowerShellModules turns the module pass off.
* -UpdateSelfSource takes Gallery or Main, and defaults to Gallery.
* A package manager now runs before the toolchains it may own.
'
        }
    }
}
