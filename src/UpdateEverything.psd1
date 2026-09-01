@{
    RootModule        = 'UpdateEverything.psm1'
    ModuleVersion     = '1.2.0'
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
            ReleaseNotes = '# 1.2.0

A run now says what version produced it, names the packages winget could not
upgrade, and updates pip. Most of this came from reading two logs off a real
machine.

## A run says what it is

The banner names the running version, and the Inventory step compares it against
the gallery. Nothing in a run said this before, so a transcript could not be read
against the code that made it -- a step that failed two releases ago looked
identical to one failing now.

## winget failures name themselves

"winget upgrade --all" returns one exit code for the whole pass. The step now
reports which packages are still out of date and separates two outcomes that
need different answers:

  Still out of date after this run:
    astral-sh.uv 0.11.19 -> 0.12.7  (the install failed; a file was in use,
                                     so close the program and run again)

  Not upgradable on this machine, and expected to stay that way:
    Cisco.CiscoWebexMeetings 45.6.4 -> 45.6.4.8  (winget listed it and did not
                                     attempt it)

The step is marked Warning only for packages winget actually attempted. One it
declined is not a fault of the run.

## pip

A new step upgrades pip itself, through python -m pip -- on Windows pip cannot
replace its own running executable, so the direct form fails on a locked file.
pip is also in the inventory now.

Installed packages are left alone, and an active virtual environment is never
touched. Those packages belong to whatever project made it.

## Fixed

* The gallery tooling step logged "TerminatingError(Find-PackageProvider)" for a
  lookup it handled correctly. Start-Transcript records a terminating error
  whether or not it is caught, so an expected empty answer no longer throws.

## Documented rather than fixed

An error appears twice in a run transcript. It is one error: the step log holds
one copy and the summary counts one. PowerShell transcribes an error when it is
raised and again when it is displayed, and removing the second copy would make
errors invisible on the console. The README explains it and says which record to
trust.
'

        }
    }
}
