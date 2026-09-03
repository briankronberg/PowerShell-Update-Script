@{
    RootModule        = 'UpdateEverything.psm1'
    ModuleVersion     = '1.7.3'
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
            ReleaseNotes = '# 1.7.3

Fixes from a full run of 1.7.2 on a live machine.

## The Terminal default stays where you put it

Windows Terminal generates one PowerShell 7 profile per pwsh install it has
seen, so a machine that moved from the Store package to the MSI has two. The
Terminal-default step compared against the first one only and moved a
default that already named the second, on every run. It now recognises any
pwsh profile -- generated or hand-written, by GUID or by name -- and leaves
a default that points at one alone.

## The inventory reports every version it can

The Python install manager prints its version at the head of help and
nothing for --version, so help is what gets asked. wsl.exe writes UTF-16,
which used to arrive unreadable; it is now read as what it is, so WSL shows
its version too.

## Windows Update says what it found

When the scan offers nothing, the step says so, and names whether Microsoft
Update was part of the scan, instead of finishing in silence.
'

        }
    }
}
