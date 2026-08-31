@{
    RootModule        = 'UpdateEverything.psm1'
    ModuleVersion     = '1.0.0'
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
            ReleaseNotes = '# 1.0.0

First release. Updates a Windows machine through every package manager and
update channel it can find, running each as an isolated step so one failure
does not stop the rest.

## Commands

* Update-Everything runs the update pass and returns a result object rather
  than exiting, so calling it from a session does not end that session. A
  scheduled task turns FailedCount into an exit code itself.
* Register-UpdateEverythingTask, Get-UpdateEverythingTask and
  Unregister-UpdateEverythingTask manage the scheduled task.
* Test-PendingReboot reports whether Windows is waiting on a restart, and names
  what is holding it.

## Consent

Nothing is installed for the first time without permission. -AllowInstall
approves in advance; an interactive run asks and defaults to No; a
non-interactive run declines and reports the step as skipped.

## Running unelevated

Elevation is checked before it is requested, so a standard user, a machine with
UAC switched off, or an MSIX PowerShell that Windows will not run elevated each
get an explanation instead of a UAC prompt that cannot succeed. -SkipElevation
runs the steps that do not need administrator rights. Logging starts before the
elevation decision, so a run that declines to start still leaves a log.

## Also in this release

* Optional toast notifications through BurntToast, including an urgent restart
  notice that breaks through Focus Assist.
* -UpdateSelf reinstalls the module from the main branch on GitHub.
* Per-run step logs and transcripts, pruned by -LogRetentionDays.
* Windows PowerShell 5.1 and PowerShell 7 are both supported. Parameters absent
  from the PowerShellGet 1.0.0.1 that Windows ships are probed rather than
  assumed.
'
        }
    }
}
