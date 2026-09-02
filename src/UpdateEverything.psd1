@{
    RootModule        = 'UpdateEverything.psm1'
    ModuleVersion     = '1.5.1'
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
            ReleaseNotes = '# 1.5.1

Fixes from a review of the whole 1.4.0-1.5.0 feature stack. GitHub-only: the
gallery carries minor versions, and these land there with 1.6.0.

## Self-update

-UpdateSelf skipped elevation on the premise that a self-update never needs
it. For an all-users install that premise failed the update on Windows
PowerShell and let newer PowerShellGet side-install a per-user copy instead.
The step still raises no UAC prompt; an all-users copy is now reported as
needing an elevated session.

-Tag Self selected nothing, because the self step was gated on the switch
alone. The tag now selects the step too, so a scheduled task built with
-Tag Self performs the self-update it names.

A machine holding a receipted older version beside a newer copy without a
receipt is no longer told the newer copy shipped with this host. The self and
gallery-tooling steps name the mixed lineage and the command that resolves
it, and a receipt carrying a prerelease or build suffix no longer throws
during the check.

A copy running from outside every module path is pointed at Install-Module,
which -UpdateSelf could not have reached.

## Steps and reporting

Duplicate-tool detection compares directories case-insensitively again, so a
PATH that lists the same directory twice in different casing counts as one
install rather than drawing a warning.

The Python launcher probe runs from the system directory inside a try/catch.
A file named help in the working directory can no longer be executed by the
probe, and a launcher that fails to start no longer inherits the previous
command exit code.

conda moved under the Python banner and gained the same ownership check as
uv and pipx: a copy that another package manager installed is left to that
manager.

A step whose tool is absent reports the absent tool rather than a need for
Administrator when both are true, and skipped steps record the path of the
log they wrote.

The task wizard reads its tag list from the cmdlet it drives, so the Go and
Cloud tags introduced in 1.4.0 are offered instead of missing.
'

        }
    }
}
