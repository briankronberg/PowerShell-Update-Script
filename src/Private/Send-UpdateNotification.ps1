function Send-UpdateNotification {
    # Posts one toast. Silent no-op when notifications are unavailable, and it
    # swallows its own failures for the same reason as above.
    [CmdletBinding()]
    param(
        # Up to three lines: BurntToast renders the first as the title.
        [Parameter(Mandatory)]
        [string[]] $Text,

        # Marks the toast an "Important Notification", which breaks through
        # Focus Assist / Do Not Disturb. Reserved for the restart notice: a
        # machine left un-rebooted has not finished applying its updates.
        [switch] $Urgent,

        # Toasts sharing an identifier replace one another rather than stacking,
        # so a weekly task does not leave a column of stale summaries.
        [string] $UniqueIdentifier = 'Update-Everything'
    )

    # Set once, up front, by the main body. Defaulted to $false there rather than
    # left unset, so a missed initialisation cannot be mistaken for "available".
    if (-not $script:NotificationsAvailable) { return }

    try {
        $toast = @{
            Text             = $Text
            UniqueIdentifier = $UniqueIdentifier
        }

        # -Urgent arrived in BurntToast 1.0. Older versions would fail the whole
        # call on an unknown parameter, so ask before using it.
        if ($Urgent) {
            if (Test-BurntToastSupportsUrgent) {
                $toast['Urgent'] = $true
            } else {
                Write-Warning 'This version of BurntToast has no -Urgent switch; sending an ordinary notification instead.'
            }
        }

        New-BurntToastNotification @toast -ErrorAction Stop
    } catch {
        Write-Warning "Could not show notification: $($_.Exception.Message)"
    }
}
