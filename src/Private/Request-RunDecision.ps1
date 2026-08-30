function Request-RunDecision {
    # Offers the operator a way out before a scheduled run starts working.
    # Returns 'Run', 'Skip' or 'Delay'.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [int] $TimeoutSeconds = 60,
        [int] $DelayMinutes = 60
    )

    $choices = @(
        'Run now'
        'Skip this run (the next scheduled run is unaffected)'
        "Wait ${DelayMinutes} minutes, then run"
    )

    $index = Read-TimedChoice -Caption 'A maintenance run is about to start.' `
        -Choice $choices -TimeoutSeconds $TimeoutSeconds -DefaultIndex 0

    switch ($index) {
        1       { 'Skip' }
        2       { 'Delay' }
        default { 'Run' }
    }
}
