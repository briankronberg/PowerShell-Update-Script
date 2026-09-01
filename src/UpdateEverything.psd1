@{
    RootModule        = 'UpdateEverything.psm1'
    ModuleVersion     = '1.4.0'
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
            ReleaseNotes = '# 1.4.0

One behaviour change to know about before upgrading, eight new update steps,
and the fixes that shipped on GitHub as 1.3.1.

## -UpdateSelf now updates only this module

The switch is a shortcut for "Install-Module UpdateEverything -Force" (or the
Main installer with -UpdateSelfSource Main): it updates the module and runs
nothing else. -Tag and -ExcludeTag are ignored for that run, and no elevation
is requested, because a CurrentUser install needs none.

In 1.3.0 the switch meant "also update the module during a full run". A
scheduled task passing -UpdateSelf gets only the self-update after this
upgrade -- give it a second task, or drop the switch, if it should keep doing
both.

## Eight new steps

Deno, Bun and pnpm join npm under the Node tag, each behind the same
ownership check as uv, so a copy a package manager installed is left to that
manager. cargo binaries runs "cargo install-update --all" where the
cargo-update crate is present, and Go binaries runs "gup update" -- both skip
naming the missing prerequisite rather than installing it. The Azure and
Google Cloud CLIs arrive under a new Cloud tag, so "-ExcludeTag Cloud" drops
the pair on a metered or offline machine. conda updates conda itself in the
base environment; environment packages are left alone for the same reason
pip''s are.

The tag set gains Go and Cloud, and the inventory covers 24 tools.

## The 1.3.1 fixes, new to the gallery

When a tool is installed twice, the warning now names the copy PATH actually
resolves rather than the alphabetically first one. The Python step reports
the classic py launcher as Skipped instead of Failed on machines without the
Install Manager. A winget package listed for the first time during a run is
reported as newly listed, not as permanently blocked. And a documentation
pass held every README and help claim against the code, restoring the
verbatim tool messages people grep for.
'

        }
    }
}
