function Get-UpdateEverythingTask {
    <#
    .SYNOPSIS
        Reports the registered Update-Everything scheduled task.

    .DESCRIPTION
        With no -TaskName, returns every task on this machine that runs this
        module, however it was named. One machine can carry several: a daily run
        that skips a toolchain and a monthly one that updates only that
        toolchain, which is what -Tag and -ExcludeTag are for.

        They are found by what they run rather than by what they are called. A
        task renamed by hand is still this module's task, and a task called
        Update-Everything that runs something else is not.

        Returns nothing when there are none, so it can be tested with an if.
        Needs no elevation.

    .PARAMETER TaskName
        One task, by exact name. Without it, every task that runs this module.

    .PARAMETER TaskPath
        Task Scheduler folder. Default: \ (the root).

    .EXAMPLE
        Get-UpdateEverythingTask

    .EXAMPLE
        Get-UpdateEverythingTask -TaskName 'Update-Everything-Python'

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
        [string] $TaskName,

        [ValidateNotNullOrEmpty()]
        [string] $TaskPath = '\'
    )

    $tasks = if ($TaskName) {
        @(Get-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -ErrorAction SilentlyContinue)
    } else {
        # Found by what they run, not by what they are called. Every task this
        # module registers imports the module by manifest path and calls the
        # function, so the arguments carry both.
        @(Get-ScheduledTask -ErrorAction SilentlyContinue |
            Where-Object {
                $_.Actions | Where-Object {
                    $_.Arguments -and $_.Arguments -match 'UpdateEverything\.psd1' -and
                    $_.Arguments -match 'Update-Everything'
                }
            })
    }

    foreach ($task in $tasks) {
        if (-not $task) { continue }

        # By name rather than -InputObject. -InputObject takes a CimInstance, so
        # the task object has to survive a type conversion that a test cannot
        # produce; the name and path identify it just as well.
        $info = Get-ScheduledTaskInfo -TaskName $task.TaskName -TaskPath $task.TaskPath -ErrorAction SilentlyContinue

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
}
