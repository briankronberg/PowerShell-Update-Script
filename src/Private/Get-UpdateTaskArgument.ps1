function Get-UpdateTaskArgument {
    <#
        .SYNOPSIS
        Builds the command line the scheduled task runs.

        .DESCRIPTION
        -Command rather than -File, because the task has to import the module and
        turn the returned object into an exit code. Only an exit code crosses a
        process boundary, and Task Scheduler records it as the last run result.

        The module is imported by path, not by name. A task runs in its own
        session, which may resolve a different copy of the module or none at all
        when it is installed for the current user only.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string] $ModuleRoot,

        [bool] $Notify = $true,

        [ValidateSet('Normal', 'Minimized', 'Hidden')]
        [string] $WindowStyle = 'Normal',

        [switch] $PromptBeforeRun,

        [int] $PromptTimeoutSeconds = 60,

        [string[]] $AllowInstall = @(),

        [string[]] $ExtraArgument = @()
    )

    $call = 'Update-Everything'
    if ($Notify) { $call += ' -Notify' }
    if ($PromptBeforeRun) { $call += " -PromptBeforeRun -PromptTimeoutSeconds $PromptTimeoutSeconds" }
    if ($AllowInstall) {
        $call += ' -AllowInstall ' + (($AllowInstall | ForEach-Object { "'" + ($_ -replace "'", "''") + "'" }) -join ',')
    }
    if ($ExtraArgument) { $call += ' ' + ($ExtraArgument -join ' ') }

    $escModule = "'" + ($ModuleRoot -replace "'", "''") + "'"
    $command = "Import-Module $escModule -Force; exit ($call).FailedCount"

    # -WindowStyle is a host argument, so it belongs to pwsh and has to come
    # before -Command.
    $parts = @('-NoProfile')
    if ($WindowStyle -ne 'Normal') { $parts += @('-WindowStyle', $WindowStyle) }
    $parts += @('-ExecutionPolicy', 'Bypass', '-Command', ('"{0}"' -f $command))

    $parts -join ' '
}
