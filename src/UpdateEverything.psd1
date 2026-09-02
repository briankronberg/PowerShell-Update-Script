@{
    RootModule        = 'UpdateEverything.psm1'
    ModuleVersion     = '1.7.0'
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
            ReleaseNotes = '# 1.7.0

The Store-to-MSI migration ships in the box.

## Convert-PowerShell7ToMsi

The Store (MSIX) PowerShell 7 cannot run elevated, its versioned install
path breaks anything that recorded it whenever it updates, and winget has
installed it by default since 7.6 -- so machines arrive in that state
without anyone choosing it.

The module now ships Convert-PowerShell7ToMsi.ps1 beside its manifest: a
standalone script, run under Windows PowerShell 5.1 with one command,
because a packaged pwsh can neither elevate nor remove the package hosting
it. It installs the current MSI release straight from the PowerShell
project -- not through winget, which would hand back the package being
removed -- verifies the installed pwsh answers, and only then removes the
Store package and its provisioning. Windows Terminal is pointed at the MSI
profile when its old default would disappear with the package. Profiles,
per-user modules and command history already live in paths both installs
share, and the report says so instead of moving anything.

The exported Convert-PowerShell7ToMsi command launches the script from any
session, with -ReportOnly to see the plan and change nothing. A maintenance
run that finds the Store package on the machine now ends by recommending
the migration, with the full path to the shipped script.

Both self-elevation handoffs -- Windows PowerShell to an elevated 5.1, and
pwsh to an elevated MSI pwsh -- were verified attended on a real machine
with UAC on before this version shipped.
'

        }
    }
}
