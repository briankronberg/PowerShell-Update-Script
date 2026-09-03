function Wait-AttendedExit {
    # Holds the window after an -Attended run so the summary can be read. Ends on
    # any key, or when the timeout runs out, so a hold nobody is watching cannot
    # last until a task's execution time limit.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'The hold is drawn for a person to read. Sending it down the pipeline would make it the return value instead.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateRange(1, 86400)]
        [int] $TimeoutSeconds
    )

    if (-not (Test-CanPrompt)) {
        Write-Warning '-Attended was requested, but this run cannot prompt (no interactive console, or input is redirected), so the window is not held.'
        return
    }

    $length = if ($TimeoutSeconds -ge 120) { "$([int][Math]::Round($TimeoutSeconds / 60)) minutes" } else { "$TimeoutSeconds seconds" }
    Write-Host ''
    Write-Host "Attended run: press any key to close. The window closes on its own in $length." -ForegroundColor Cyan

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $lastShown = -1
    try {
        while ((Get-Date) -lt $deadline) {
            $remaining = [int][Math]::Ceiling(($deadline - (Get-Date)).TotalSeconds)
            if ($remaining -ne $lastShown) {
                # [Console]::Write, not Write-Host: the countdown redraws in place
                # without a line per second in the transcript. See Read-TimedChoice.
                [Console]::Write(("`rClosing in {0,5}s -- press any key. " -f $remaining))
                $lastShown = $remaining
            }
            if ($Host.UI.RawUI.KeyAvailable) {
                $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
                [Console]::Write("`r" + (' ' * 50) + "`r")
                return
            }
            Start-Sleep -Milliseconds 200
        }
    } catch {
        Write-Host ''
        Write-Warning "Could not read a keypress ($($_.Exception.Message)); closing."
        return
    }
    [Console]::Write("`r" + (' ' * 50) + "`r")
    Write-Host "No key in $length; closing." -ForegroundColor DarkGray
}
