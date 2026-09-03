function Start-StepWatchdog {
    <#
        .SYNOPSIS
        Arms a timer that stops a step's child processes when the step runs long.

        .DESCRIPTION
        Steps run in this process and close over the run's variables and this
        module's private functions, so a step cannot be moved somewhere it could
        be stopped from outside. What can run elsewhere is a watchdog: a second
        runspace on its own thread that sleeps for the budget and, if it wakes
        before Stop-StepWatchdog is called, kills every process descended from
        this one. The hung native command -- winget, msiexec, npm -- then returns,
        and the step fails with the reason instead of the run being stopped at
        the task's execution time limit with no summary.

        A step that hangs inside a cmdlet in this process, such as a Windows
        Update scan that never returns, has no child to kill and is not helped.

        Returns an object with State (Fired, Killed), or nothing when a runspace
        could not be created, in which case the step runs unguarded.

        .PARAMETER TimeoutSeconds
        How long the step may run before its children are stopped.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Arms a timer in this process. What it may stop later is the step the caller is already running, and the step reports it.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateRange(1, 86400)]
        [int] $TimeoutSeconds
    )

    # Synchronized, because the watchdog thread writes and the step thread reads.
    $state = [hashtable]::Synchronized(@{
        Fired  = $false
        Killed = [System.Collections.ArrayList]::Synchronized([System.Collections.ArrayList]::new())
        Error  = $null
    })

    # Process ids from CIM are UInt32 and the parent's is Int32; compared as
    # they arrive, nothing matches and nothing is stopped.
    $script = {
        param($ParentPid, $TimeoutSeconds, $State)
        try {
            Start-Sleep -Seconds $TimeoutSeconds
            $State.Fired = $true
            $all = @(Get-CimInstance Win32_Process -Property ProcessId, ParentProcessId, Name -ErrorAction Stop)
            $seen = @{}
            $frontier = @([int] $ParentPid)
            $targets = @()
            while ($frontier.Count) {
                $next = @($all | Where-Object { [int] $_.ParentProcessId -in $frontier -and -not $seen.ContainsKey([int] $_.ProcessId) })
                foreach ($p in $next) { $seen[[int] $p.ProcessId] = $true }
                $targets += $next
                $frontier = @($next | ForEach-Object { [int] $_.ProcessId })
            }
            foreach ($t in $targets) {
                try {
                    Stop-Process -Id $t.ProcessId -Force -ErrorAction Stop
                    $null = $State.Killed.Add("$($t.Name) ($($t.ProcessId))")
                } catch {
                    $null = $State.Killed.Add("$($t.Name) ($($t.ProcessId)) would not stop: $($_.Exception.Message)")
                }
            }
        } catch {
            $State.Error = $_.Exception.Message
        }
    }

    try {
        $runspace = [runspacefactory]::CreateRunspace()
        $runspace.Open()
        $powershell = [powershell]::Create()
        $powershell.Runspace = $runspace
        $null = $powershell.AddScript($script.ToString()).AddArgument($PID).AddArgument($TimeoutSeconds).AddArgument($state)
        $handle = $powershell.BeginInvoke()
    } catch {
        Write-Verbose "Could not start the step watchdog: $($_.Exception.Message)"
        return
    }

    [pscustomobject]@{
        State      = $state
        PowerShell = $powershell
        Runspace   = $runspace
        Handle     = $handle
        Seconds    = $TimeoutSeconds
    }
}
