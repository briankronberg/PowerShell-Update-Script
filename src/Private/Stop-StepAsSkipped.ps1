function Stop-StepAsSkipped {
    # Ends the current step as 'Skipped' rather than 'Failed'. Declining an
    # install is a decision, not a fault, and the summary should not colour it
    # like one. Invoke-Step recognises this sentinel prefix.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $Reason)

    throw "STEP-SKIPPED: $Reason"
}
