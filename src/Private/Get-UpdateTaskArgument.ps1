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

        [string[]] $Tag = @(),

        [string[]] $ExcludeTag = @(),

        [string[]] $ExtraArgument = @()
    )

    $call = 'Update-Everything'
    if ($Notify) { $call += ' -Notify' }
    if ($PromptBeforeRun) { $call += " -PromptBeforeRun -PromptTimeoutSeconds $PromptTimeoutSeconds" }
    if ($AllowInstall) {
        $call += ' -AllowInstall ' + (($AllowInstall | ForEach-Object { "'" + ($_ -replace "'", "''") + "'" }) -join ',')
    }
    foreach ($set in @(@{ Name = 'Tag'; Value = $Tag }, @{ Name = 'ExcludeTag'; Value = $ExcludeTag })) {
        if ($set.Value) {
            $call += " -$($set.Name) " + (($set.Value | ForEach-Object { "'" + ($_ -replace "'", "''") + "'" }) -join ',')
        }
    }
    if ($ExtraArgument) { $call += ' ' + ($ExtraArgument -join ' ') }

    # The manifest, not the folder holding it. Given a directory, Import-Module
    # looks for a manifest named after that directory, so a versioned install
    # path ending in \1.0.0 sends it hunting for 1.0.0.psd1 and reports "no
    # valid module file was found". Calling Update-Everything would still
    # auto-load the module by name a moment later, but from whatever the module
    # path resolves to rather than from the copy the task names.
    $manifest = Join-Path $ModuleRoot 'UpdateEverything.psd1'
    $escModule = "'" + ($manifest -replace "'", "''") + "'"
    $command = "Import-Module $escModule -Force; exit ($call).FailedCount"

    # -WindowStyle is a host argument, so it belongs to pwsh and has to come
    # before -Command.
    $parts = @('-NoProfile')
    if ($WindowStyle -ne 'Normal') { $parts += @('-WindowStyle', $WindowStyle) }
    $parts += @('-ExecutionPolicy', 'Bypass', '-Command', ('"{0}"' -f $command))

    $parts -join ' '
}
