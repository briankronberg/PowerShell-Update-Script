@{
    RootModule        = 'UpdateEverything.psm1'
    ModuleVersion     = '1.3.1'
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
            ReleaseNotes = '# 1.3.1

Three fixes to what a run reports, and a documentation pass that held every
claim against the code. GitHub-only: the gallery carries minor versions, and
this lands there with 1.4.0.

## The duplicate-copy warning names the right copy

When a tool is installed in more than one place, the inventory warns that the
first is the one that runs. The list behind that warning was alphabetised, not
PATH-ordered, so the named copy could be the wrong one -- node in C:\tools
loses alphabetically to C:\Program Files even when PATH runs it first. The
list now keeps PATH-resolution order.

## The Python step skips the classic launcher instead of failing

"py install --update" only works on the Python Install Manager''s py alias.
The classic python.org launcher treats install as a script path and errors,
which marked the step Failed on every machine that has py but not pymanager.
The step now tells the two apart and reports the classic launcher as Skipped,
with the reason.

## A package that appears mid-run is not called permanently blocked

The winget summary put every package it had not attempted under "Not
upgradable on this machine, and expected to stay that way" -- including one
listed for the first time by the closing table, about which nothing is known.
Those now print under their own line, and the next run picks them up.

## Documentation held against the code

A max-effort review compared every rewritten comment, help topic and README
claim to the code it describes. Among the corrections: the README documented
a -Cadence value that does not exist (the monthly cadence is PatchTuesday);
the winget command in the manager table omitted the --accept-* flags that
accept licence agreements on your behalf; the help promised an exit code the
module conversion removed; and the verbatim tool messages people grep for --
winget''s "does not apply to your system or requirements", PowerShellGet''s
"was not installed by using Install-Module" -- are back in the source,
findable again.
'

        }
    }
}
