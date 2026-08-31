function Invoke-TaskSetup {
    <#
        .SYNOPSIS
        The scheduled-task option of the setup menu.

        .DESCRIPTION
        Lists what is already registered and offers to add another, replace one,
        or remove one.

        Another *task*, not another trigger. Every trigger on a task runs the
        same action, so two triggers cannot express "everything but Python
        daily, only Python monthly" -- which is the reason for wanting a second
        run at all. Something pinned to a version another application depends on
        wants its own schedule, not the one that keeps everything else current.

        Split out from Invoke-SetupChoice so the submenu can be tested on its
        own.

        .EXAMPLE
        Invoke-TaskSetup
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Write-Host is the user interface of a console maintenance tool. This runs from an interactive menu, not inside a step.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Reached only from the setup menu, and every branch states what it will do and asks before doing it. Register and Unregister carry their own ShouldProcess.')]
    [CmdletBinding()]
    [OutputType([void])]
    param()

    $existing = @(Get-UpdateEverythingTask)

    Write-Host ''
    if (-not $existing.Count) {
        Write-Host 'No scheduled task is registered yet.' -ForegroundColor Cyan
        Write-Host 'Registering a weekly run, as you, elevated, with notifications.' -ForegroundColor Cyan
        Write-Host 'This needs administrator rights.' -ForegroundColor DarkGray
        Write-Host ''

        try {
            Register-UpdateEverythingTask -Cadence Weekly -Notify $true -ErrorAction Stop
        } catch {
            Write-Warning "Could not register the task: $($_.Exception.Message)"
        }
        return
    }

    Write-Host "$($existing.Count) task(s) already registered:" -ForegroundColor Cyan
    for ($i = 0; $i -lt $existing.Count; $i++) {
        $task = $existing[$i]
        Write-Host ("  {0,2}. {1,-32} {2,-10} next {3}" -f ($i + 1), $task.TaskName, $task.State, $task.NextRun)
    }

    Write-Host ''
    Write-Host '  1. Add another task, with its own schedule and its own steps'
    Write-Host '  2. Replace one'
    Write-Host '  3. Remove one'
    Write-Host '  4. Back'
    Write-Host ''

    switch ((Read-Host 'Choose [1-4]').Trim()) {

        '1' { New-TaskFromPrompt }

        '2' {
            $chosen = Select-TaskFromList -Task $existing -Prompt 'Replace which'
            if (-not $chosen) { return }

            Write-Host "Replacing '$($chosen.TaskName)'. Its current schedule and steps are discarded." -ForegroundColor Yellow
            New-TaskFromPrompt -DefaultName $chosen.TaskName -Replace
        }

        '3' {
            $chosen = Select-TaskFromList -Task $existing -Prompt 'Remove which'
            if (-not $chosen) { return }

            $answer = (Read-Host "Remove '$($chosen.TaskName)'? [y/N]").Trim()
            if ($answer -notmatch '^(y|yes)$') {
                Write-Host '  Left alone.' -ForegroundColor DarkGray
                return
            }

            try {
                Unregister-UpdateEverythingTask -TaskName $chosen.TaskName -TaskPath $chosen.TaskPath -Confirm:$false -ErrorAction Stop
            } catch {
                Write-Warning "Could not remove the task: $($_.Exception.Message)"
            }
        }

        default { return }
    }
}
