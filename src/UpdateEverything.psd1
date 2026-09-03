@{
    RootModule        = 'UpdateEverything.psm1'
    ModuleVersion     = '1.8.0'
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
            ReleaseNotes = '# 1.8.0

Three additions from comparing this module with a smaller daily-update
script, and one fix since 1.7.3.

## Notifications are on by default

A run now raises its toasts without being asked. -Notify:$false turns them
off. -Notify stays a switch, so every task registered by an earlier version
keeps working unchanged; what changed is that not passing it means on. When
BurntToast is not installed and -Notify was not passed, the closing summary
says so in one line and offers nothing for install, so the default cannot
nag. A run that passed -Notify keeps the warning and the consent prompt.

## -Attended holds the window

A run started from a shortcut or a Start-menu pin closes its window before
the summary can be read. -Attended holds it until a key is pressed, and
closes on its own after -PromptTimeoutSeconds when given, otherwise ten
minutes. The default stays unattended; a task carrying -Attended in
-ExtraArgument is warned at registration.

## PATH is refreshed between steps

A step that installs a manager changes the machine or user PATH, and the
process used to keep the PATH it started with, so the new tool was found by
the next run. The run now re-reads both hives after each step and says
"PATH gained: ..." when there is anything to say. Entries this session added
itself stay in front.

## A run that did not finish is reported

A run stopped by the task execution time limit, or by a closed window, left
a transcript that simply stopped. The next run reads it and warns at the
top, naming when it started, its last step and the file. Registering a task
prints the time limit alongside the schedule.

## Fixes

The Inventory row for WSL read as garbage inside a run: wsl.exe writes
UTF-16 from a bare shell and single-byte text inside a run. The probe now
sets WSL_UTF8=1 for the one call, which makes it write UTF-8 in both.
'

        }
    }
}
