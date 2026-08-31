function New-TaskFromPrompt {
    <#
        .SYNOPSIS
        Asks for a task's name, cadence and steps, then registers it.

        .DESCRIPTION
        The steps are the point. A second task exists because it runs with
        different parameters: "everything but Python, daily" alongside "only
        Python, weekly", for a toolchain something else depends on being held
        steady. That is why this asks for tags rather than only a schedule.

        Blank answers take the defaults, so a person who only wants a second
        weekly run presses Enter four times.

        .PARAMETER DefaultName
        Offered as the default name. Replacing a task passes its current name.

        .PARAMETER Replace
        Overwrite a task of the same name rather than refusing.

        .EXAMPLE
        New-TaskFromPrompt
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Write-Host is the user interface of a console maintenance tool. This runs from an interactive menu, not inside a step.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Every value is asked for and echoed back before Register-UpdateEverythingTask is called, and that carries its own ShouldProcess.')]
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [string] $DefaultName,
        [switch] $Replace
    )

    $tags = @('Windows', 'Microsoft', 'PowerShell', 'PackageManager', 'Python',
              'Node', 'DotNet', 'Rust', 'Git', 'Self', 'Inventory')

    if (-not $DefaultName) {
        # Update-Everything, then Update-Everything-2 and up. Named after what
        # it is rather than after what it does, because what it does can change.
        $taken = @(Get-UpdateEverythingTask).TaskName
        $DefaultName = 'Update-Everything'
        $n = 2
        while ($taken -contains $DefaultName) {
            $DefaultName = "Update-Everything-$n"
            $n++
        }
    }

    Write-Host ''
    $name = (Read-Host "Task name [$DefaultName]").Trim()
    if (-not $name) { $name = $DefaultName }

    # PatchTuesday is deliberately not offered. It is a documented cadence and it
    # cannot register: the monthly trigger is built as a client-only CIM instance
    # that Register-ScheduledTask refuses. See issue #36. Offering a choice that
    # fails would be worse than offering fewer.
    $cadences = @('Daily', 'Weekly')

    $cadence = (Read-Host 'Cadence: Daily or Weekly [Weekly]').Trim()
    if (-not $cadence) { $cadence = 'Weekly' }
    if ($cadence -notin $cadences) {
        Write-Warning "'$cadence' is not one of: $($cadences -join ', '). Nothing was registered."
        return
    }

    Write-Host ''
    Write-Host "Steps are chosen by tag: $($tags -join ', ')" -ForegroundColor DarkGray
    Write-Host 'Blank means every step.' -ForegroundColor DarkGray

    $include = @((Read-Host 'Only these tags, comma separated [all]') -split ',' |
        ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $exclude = @((Read-Host 'Except these tags, comma separated [none]') -split ',' |
        ForEach-Object { $_.Trim() } | Where-Object { $_ })

    $unknown = @($include + $exclude | Where-Object { $_ -notin $tags })
    if ($unknown.Count) {
        Write-Warning "Not a tag: $($unknown -join ', '). Nothing was registered."
        return
    }

    $describe = @("$cadence")
    if ($include) { $describe += "only $($include -join ', ')" }
    if ($exclude) { $describe += "excluding $($exclude -join ', ')" }

    Write-Host ''
    Write-Host "Registering '$name': $($describe -join ', ')." -ForegroundColor Cyan
    Write-Host 'This needs administrator rights.' -ForegroundColor DarkGray

    $arguments = @{
        TaskName    = $name
        Cadence     = $cadence
        Notify      = $true
        ErrorAction = 'Stop'
    }
    if ($include) { $arguments.Tag = $include }
    if ($exclude) { $arguments.ExcludeTag = $exclude }
    if ($Replace) { $arguments.Force = $true }

    try {
        Register-UpdateEverythingTask @arguments
    } catch {
        Write-Warning "Could not register the task: $($_.Exception.Message)"
    }
}
