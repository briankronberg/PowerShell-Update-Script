function Get-UpdateEverythingTask {
    <#
    .SYNOPSIS
        Reports the registered Update-Everything scheduled task.

    .DESCRIPTION
        Returns nothing when no such task exists, so it can be tested with an if.
        Needs no elevation.

    .PARAMETER TaskName
        Name of the scheduled task. Default: Update-Everything.

    .PARAMETER TaskPath
        Task Scheduler folder. Default: \ (the root).

    .EXAMPLE
        Get-UpdateEverythingTask

    .EXAMPLE
        if (-not (Get-UpdateEverythingTask)) { 'not scheduled' }

    .OUTPUTS
        An object describing the task: its state, the account it runs as, the
        command line, and when it last and next runs.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [ValidateNotNullOrEmpty()]
        [string] $TaskName = 'Update-Everything',

        [ValidateNotNullOrEmpty()]
        [string] $TaskPath = '\'
    )

    $task = Get-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -ErrorAction SilentlyContinue
    if (-not $task) { return }

    $info = Get-ScheduledTaskInfo -InputObject $task

    [pscustomobject]@{
        PSTypeName  = 'UpdateEverything.Task'
        TaskName    = $task.TaskName
        TaskPath    = $task.TaskPath
        State       = [string] $task.State
        RunsAs      = $task.Principal.UserId
        RunLevel    = [string] $task.Principal.RunLevel
        LogonType   = [string] $task.Principal.LogonType
        Command     = ($task.Actions[0].Execute + ' ' + $task.Actions[0].Arguments).Trim()
        LastRun     = Format-LastRunResult -LastRunTime $info.LastRunTime -LastTaskResult $info.LastTaskResult
        NextRun     = $info.NextRunTime
    }
}
