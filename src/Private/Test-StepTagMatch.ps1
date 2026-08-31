function Test-StepTagMatch {
    <#
        .SYNOPSIS
        Decides whether a step runs, given its own tags and the run's filters.

        .DESCRIPTION
        -Tag is "nothing but these". -ExcludeTag is "anything but these". Both
        may be given at once, and exclusion wins, so -Tag Python -ExcludeTag Node
        is not a contradiction and -Tag Python -ExcludeTag Python selects nothing
        rather than erroring.

        A step carrying no tags is selected by an empty -Tag, because an empty
        filter means "everything", but never by a non-empty one: asking for
        Python and receiving a step that claims no subject at all would make the
        filter meaningless.

        .EXAMPLE
        Test-StepTagMatch -StepTag Python, PackageManager -ExcludeTag Node
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        # The tags the step declares.
        [string[]] $StepTag = @(),

        # The run's -Tag, if any.
        [string[]] $Tag = @(),

        # The run's -ExcludeTag, if any.
        [string[]] $ExcludeTag = @()
    )

    # Every list is filtered before it is counted, because @($null) has a Count
    # of 1 in PowerShell. Counting the raw parameter would read an unset filter
    # as "one entry, matching nothing" and skip the entire run.
    $mine    = @($StepTag    | Where-Object { $_ })
    $wanted  = @($Tag        | Where-Object { $_ })
    $refused = @($ExcludeTag | Where-Object { $_ })

    if ($refused.Count -and @($mine | Where-Object { $_ -in $refused }).Count) {
        return $false
    }

    if (-not $wanted.Count) { return $true }

    return [bool] @($mine | Where-Object { $_ -in $wanted }).Count
}
