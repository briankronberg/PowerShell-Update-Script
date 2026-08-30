function New-UpdateEverythingResult {
    <#
        .SYNOPSIS
        Builds the object Update-Everything hands back.

        .DESCRIPTION
        The script this module grew from ended with "exit $failedSteps.Count". A
        module function cannot do that: it would kill the session that called it.
        So the outcome comes back as an object, and a scheduled task turns
        FailedCount into an exit code itself.

        Counts are derived from Steps rather than passed in, so they cannot
        disagree with the records they describe.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Builds an object and changes nothing, so there is no operation for -WhatIf to describe.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        # $false when nothing was attempted.
        [Parameter(Mandatory)]
        [bool] $Ran,

        # Why nothing was attempted, when Ran is $false.
        [string] $Reason,

        [switch] $Elevated,

        # One record per step, as collected by Invoke-Step.
        [object[]] $Steps = @(),

        [bool] $RebootPending,

        [string[]] $RebootReason = @(),

        [string] $LogDirectory,

        [string] $MainLog,

        # Only for a run handed off to an elevated child, where this process has
        # no step records of its own but does know the child's exit code.
        [int] $FailedCount = -1
    )

    $failed = if ($FailedCount -ge 0) {
        $FailedCount
    } else {
        @($Steps | Where-Object { $_.Status -eq 'Failed' }).Count
    }

    [pscustomobject]@{
        PSTypeName    = 'UpdateEverything.Result'
        Ran           = $Ran
        Reason        = $Reason
        Elevated      = [bool] $Elevated
        Steps         = $Steps
        OkCount       = @($Steps | Where-Object { $_.Status -eq 'OK' }).Count
        WarningCount  = @($Steps | Where-Object { $_.Status -eq 'Warning' }).Count
        SkippedCount  = @($Steps | Where-Object { $_.Status -eq 'Skipped' }).Count
        FailedCount   = $failed
        RebootPending = $RebootPending
        RebootReason  = $RebootReason
        LogDirectory  = $LogDirectory
        MainLog       = $MainLog
    }
}
