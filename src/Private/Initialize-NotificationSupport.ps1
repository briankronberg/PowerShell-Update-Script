function Initialize-NotificationSupport {
    # Prepares toast notifications, and reports whether they are usable and why
    # not. Toasts are a convenience: every failure path here reports rather than
    # throwing, because a missing notification module must never be the reason a
    # maintenance run does not happen.
    #
    # The reason is returned, not just logged, so the end-of-run summary can
    # repeat it. A warning printed at the moment of discovery has scrolled well
    # out of sight by the time a long run finishes.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Write-Host is the user interface of a console maintenance tool. Its output is progress a person watches, not data a caller consumes, and the summary uses colour to separate failures from noise.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        # The caller's -AllowInstall list, consulted before BurntToast is pulled
        # from the PowerShell Gallery.
        [string[]] $Approved = @()
    )

    # A toast is drawn by the shell in an interactive desktop session. From a
    # service or a SYSTEM-run scheduled task there is no session to draw into,
    # and the call either fails or posts a notification nobody can see.
    if (-not (Test-InteractiveSession)) {
        $reason = 'this is not an interactive session, so a toast has no desktop to appear on. Schedule the task to run as your own user while logged on.'
        Write-Warning "Notifications requested, but $reason"
        return [pscustomobject]@{ Available = $false; Reason = $reason }
    }

    if (-not (Get-Module BurntToast -ListAvailable)) {
        if (-not (Approve-Install -Component 'BurntToast' -Approved $Approved `
                -Description 'Notifications were requested with -Notify, but the BurntToast module is not installed. This would install it from the PowerShell Gallery for the current user only.')) {
            $reason = 'the BurntToast module is not installed, and installing it was not approved. Install it with "Install-Module BurntToast -Scope CurrentUser", or re-run with -AllowInstall BurntToast.'
            return [pscustomobject]@{ Available = $false; Reason = $reason }
        }
        try {
            Write-Host 'Installing BurntToast (CurrentUser) for notifications...'
            Install-Module -Name BurntToast -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop
        } catch {
            $reason = "BurntToast could not be installed: $($_.Exception.Message)"
            Write-Warning "$reason. Continuing without notifications."
            return [pscustomobject]@{ Available = $false; Reason = $reason }
        }
    }

    try {
        Import-Module BurntToast -ErrorAction Stop
        return [pscustomobject]@{ Available = $true; Reason = 'BurntToast loaded.' }
    } catch {
        $reason = "BurntToast is installed but would not load: $($_.Exception.Message)"
        Write-Warning "$reason. Continuing without notifications."
        return [pscustomobject]@{ Available = $false; Reason = $reason }
    }
}
