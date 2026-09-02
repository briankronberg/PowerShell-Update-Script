@{
    RootModule        = 'UpdateEverything.psm1'
    ModuleVersion     = '1.7.1'
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
        'Convert-PowerShell7ToMsi'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @('Update-All')

    PrivateData = @{
        PSData = @{
            Tags         = @('Windows', 'Update', 'Maintenance', 'winget', 'WindowsUpdate', 'Chocolatey', 'Scoop', 'ScheduledTask', 'PSEdition_Desktop', 'PSEdition_Core')
            LicenseUri   = 'https://github.com/briankronberg/UpdateEverything/blob/main/LICENSE'
            ProjectUri   = 'https://github.com/briankronberg/UpdateEverything'
            ReleaseNotes = '# 1.7.1

One fix, for machines that install the module for all users.

## The self-update sees the machine-wide receipt

Get-InstalledPSResource without -Scope reads only the per-user paths, so a
copy installed with Install-PSResource -Scope AllUsers -- receipt on disk,
returned by the AllUsers query -- reported no gallery lineage at all. Once
the gallery moved ahead, the self step would have called it a copy the
gallery did not install.

The status now asks PSResourceGet both ways and carries the scope of the
covering receipt. The self step targets that scope: elevated,
Update-PSResource runs with -Scope AllUsers; unelevated, the step reports
the elevation need up front instead of calling at all, because
Update-PSResource would not refuse -- its CurrentUser default would quietly
install the new version per-user beside the all-users copy.

A per-user receipt wins when both scopes cover: that copy shadows the
machine one in PSModulePath order, and moving it needs no elevation.
'

        }
    }
}
