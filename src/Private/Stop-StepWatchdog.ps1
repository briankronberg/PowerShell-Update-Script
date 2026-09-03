function Stop-StepWatchdog {
    # Disarms the watchdog a step finished ahead of, and releases its runspace.
    # Stop interrupts the sleep at once, so a run pays nothing for a watchdog
    # that never fired.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Releases a timer this module armed in this process. Nothing on the machine changes.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Watchdog
    )

    try { $Watchdog.PowerShell.Stop() }    catch { Write-Verbose "Step watchdog stop: $($_.Exception.Message)" }
    try { $Watchdog.PowerShell.Dispose() } catch { Write-Verbose "Step watchdog dispose: $($_.Exception.Message)" }
    try { $Watchdog.Runspace.Dispose() }   catch { Write-Verbose "Step watchdog runspace: $($_.Exception.Message)" }
}
