function Write-StepLog {
    # Logging must never be the thing that kills a run, so failures here degrade
    # to a warning rather than propagating.
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][string] $Message
    )
    try {
        Add-Content -LiteralPath $Path -Value ('{0:yyyy-MM-dd HH:mm:ss} | {1}' -f (Get-Date), $Message) -ErrorAction Stop
    } catch {
        Write-Warning "Could not write to step log '$Path': $($_.Exception.Message)"
    }
}
