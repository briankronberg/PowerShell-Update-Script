@{
    RootModule        = 'UpdateEverything.psm1'
    ModuleVersion     = '1.6.0'
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
            ReleaseNotes = '# 1.6.0

Both gallery clients are read, two new steps arrive under two new tags, and
the fixes that shipped on GitHub as 1.5.1.

## The self-update reads both gallery clients

PSResourceGet ships in the box with PowerShell 7.4 and its receipts are
invisible to Get-InstalledModule, so a copy installed with Install-PSResource
was told it did not come from the gallery, and -UpdateSelf ran Update-Module,
which cannot move it. The status now consults both clients and runs the one
whose receipt covers the installed copy -- Update-PSResource, whose
CurrentUser default keeps the no-elevation promise, or Update-Module as
before. An all-users copy is reported as needing an elevated session, with
the command that matches, and no UAC prompt is raised either way.

-Tag Self now selects the self step; in 1.5.0 the tag alone ran nothing. A
machine holding a receipted older version beside a newer copy without a
receipt is told about the mixed lineage and the way out, rather than being
called a copy that shipped with the host.

## Two new steps

VS Code extensions runs "code --update-extensions" under the new Editor tag.
The editor itself moves through winget; its extensions only auto-update
while the editor is open to see them, so the step earns its keep on the
editor that is rarely opened or has auto-update off.

MiKTeX packages updates installed TeX packages under the new TeX tag,
through the modern miktex CLI. MiKTeX warns when per-user and all-users
updates mix, so the step runs exactly one mode, chosen by where the
executable lives. An all-users install updates only from an elevated
session, and is skipped with that reason otherwise.

The inventory covers 26 tools.

## The 1.5.1 fixes, new to the gallery

Duplicate-tool detection compares directories case-insensitively again. The
Python launcher probe runs from the system directory inside a try/catch, so
a file named help in the working directory can no longer be executed by it.
conda sits under the Python banner with the same ownership check as uv and
pipx. A step whose tool is absent reports the absent tool rather than a need
for Administrator when both are true, and skipped steps record their log
path. The task wizard reads its tag list from the command it drives. A copy
running from outside every module path is pointed at Install-Module.

## Also in the repository

Convert-PowerShell7ToMsi.ps1 moves a machine from the Store (MSIX)
PowerShell 7 -- which cannot run elevated, and breaks anything that recorded
its versioned path whenever it updates -- to the MSI install, in one
attended run from Windows PowerShell. The README shows the command.
'

        }
    }
}
