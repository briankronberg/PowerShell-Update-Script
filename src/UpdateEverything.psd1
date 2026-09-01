@{
    RootModule        = 'UpdateEverything.psm1'
    ModuleVersion     = '1.3.0'
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
            ReleaseNotes = '# 1.3.0

One fix, and it matters on managed machines: UpdateEverything refused to elevate
on any machine using a privilege-management broker.

## Elevation is attempted rather than refused

Test-ElevationCapability treated "not a member of the local Administrators
group" as proof that Windows would not grant elevation. That is false wherever a
privilege-management broker is in use -- BeyondTrust, CyberArk EPM, Admin By
Request -- because the account is deliberately not in the group and elevates
anyway, often per application.

On such a machine 1.2.0 is unusable: it refuses before raising a prompt, and
tells the user something untrue about their computer.

Group membership is now a caution rather than a refusal, warned about before the
attempt. The two genuine certainties still refuse, because neither depends on
who is asking: UAC switched off, and a packaged PowerShell with no MSI build
beside it.

## A failed elevation says more

Get-ElevationPolicyNote names a running privilege broker. Those grant or deny
elevation per application and leave nothing in the registry, so in 1.2.0 a
refusal on such a machine came with no explanation at all.

## Verified

The self-elevation handoff is tested end to end for the first time, by a harness
in tests/Elevation that runs on a real machine with UAC on and asks for one
click. Development machines and CI runners are already administrators, and
Windows Sandbox ships with UAC off, so nothing before this could reach the code
that once shipped unable to parse.
'

        }
    }
}
