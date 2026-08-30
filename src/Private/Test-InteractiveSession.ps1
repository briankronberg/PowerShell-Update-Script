function Test-InteractiveSession {
    # Wrapped rather than called inline so the notification path can be tested
    # without a desktop session to run in.
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    [Environment]::UserInteractive
}
