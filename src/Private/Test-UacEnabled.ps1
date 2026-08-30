function Test-UacEnabled {
    # Whether Windows will offer a consent prompt at all. With UAC switched off,
    # a non-elevated session cannot ask for elevation -- no prompt appears and
    # Start-Process -Verb RunAs fails rather than escalating.
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    try {
        $value = (Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' `
            -Name EnableLUA -ErrorAction Stop).EnableLUA
        return [bool] $value
    } catch {
        # Absent or unreadable: assume UAC is on, which is the Windows default.
        # Guessing "off" here would refuse to run on a perfectly normal machine.
        return $true
    }
}
