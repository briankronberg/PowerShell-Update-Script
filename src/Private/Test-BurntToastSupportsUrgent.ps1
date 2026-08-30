function Test-BurntToastSupportsUrgent {
    # -Urgent arrived in BurntToast 1.0. On an older module the parameter does
    # not exist and passing it would fail the whole call, losing the notification
    # rather than merely its urgency.
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    try {
        return (Get-Command New-BurntToastNotification -ErrorAction Stop).Parameters.ContainsKey('Urgent')
    } catch {
        return $false
    }
}
