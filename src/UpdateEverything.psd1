@{
    RootModule        = 'UpdateEverything.psm1'
    ModuleVersion     = '1.5.0'
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
            ReleaseNotes = '# 1.5.0

One fix, for machines that installed from the gallery once and from GitHub
later.

## Updatable means the receipt covers the newest installed copy

Get-GalleryModuleStatus answered Updatable from the existence of any
PowerShellGet receipt for the module name. A gallery install followed by the
GitHub one-liner leaves a receipted older version beside an unreceipted newer
one, and the helper then called the newest copy updatable while Update-Module
moves only the receipted lineage -- so the self-update step could describe an
update it was not performing.

Updatable is now true only when the receipt names the same version as the
newest installed copy. On a mixed machine the self step takes the guidance
branch instead, naming Install-Module -Force and -UpdateSelfSource Main,
both of which do what they say there.

## Verified before publishing

Found and fixed through a new release harness that downloads the published
package from the gallery and runs it as installed, on a machine in exactly
the mixed state above. The self-elevation handoff was re-verified end to end
on a real machine with UAC on -- eight checks, none skipped -- before this
version shipped.
'

        }
    }
}
