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
            LicenseUri   = 'https://github.com/briankronberg/PowerShell-Update-Script/blob/main/LICENSE'
            ProjectUri   = 'https://github.com/briankronberg/PowerShell-Update-Script'
            ReleaseNotes = '# 1.0.0

First release as a module. Previously a single script.

* Update-Everything returns a result object instead of exiting, so calling it
  from a session no longer ends that session. A scheduled task turns
  FailedCount into an exit code itself.
* Register-UpdateEverythingTask, Get-UpdateEverythingTask and
  Unregister-UpdateEverythingTask replace the switches on the old
  Register-UpdateTask.ps1.
* Nothing is installed for the first time without permission. -AllowInstall
  approves in advance; an interactive run asks and defaults to No; a scheduled
  run declines and reports the step as skipped.
* Optional toast notifications through BurntToast, including an urgent restart
  notice that breaks through Focus Assist.
'
        }
    }
}
