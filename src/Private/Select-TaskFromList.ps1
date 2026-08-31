function Select-TaskFromList {
    <#
        .SYNOPSIS
        Asks which of the listed tasks to act on, and returns it.

        .DESCRIPTION
        Returns nothing when the answer is blank or is not one of the numbers
        shown, so a caller treats "no answer" and "bad answer" the same way:
        do nothing. A menu that acted on a mistyped number would be worse than
        one that asked again.

        .EXAMPLE
        Select-TaskFromList -Task $tasks -Prompt 'Remove which'
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Write-Host is the user interface of a console maintenance tool. This runs from an interactive menu, not inside a step.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]] $Task,

        [Parameter(Mandatory)]
        [string] $Prompt
    )

    if (-not $Task.Count) { return }

    $answer = (Read-Host "$Prompt [1-$($Task.Count)], or blank to go back").Trim()
    if (-not $answer) { return }

    $index = 0
    if (-not [int]::TryParse($answer, [ref] $index) -or $index -lt 1 -or $index -gt $Task.Count) {
        Write-Host "  '$answer' is not one of the numbers listed." -ForegroundColor Yellow
        return
    }

    $Task[$index - 1]
}
