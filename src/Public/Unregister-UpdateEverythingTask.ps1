function Unregister-UpdateEverythingTask {
    <#
    .SYNOPSIS
        Removes the Update-Everything scheduled task.

    .DESCRIPTION
        Does nothing, quietly, when no such task exists. Removing a schedule does
        not need elevation, unlike registering one.

    .PARAMETER TaskName
        Name of the scheduled task. Default: Update-Everything.

    .PARAMETER TaskPath
        Task Scheduler folder. Default: \ (the root).

    .EXAMPLE
        Unregister-UpdateEverythingTask
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param(
        [ValidateNotNullOrEmpty()]
        [string] $TaskName = 'Update-Everything',

        [ValidateNotNullOrEmpty()]
        [string] $TaskPath = '\'
    )

    $fullTaskName = ($TaskPath.TrimEnd('\') + '\' + $TaskName)

    $existing = Get-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -ErrorAction SilentlyContinue
    if (-not $existing) {
        Write-Verbose "No scheduled task named '$fullTaskName'; nothing to remove."
        return
    }

    if ($PSCmdlet.ShouldProcess($fullTaskName, 'Unregister scheduled task')) {
        Unregister-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -Confirm:$false
        Write-Host "Removed scheduled task '$fullTaskName'." -ForegroundColor Green
    }
}
