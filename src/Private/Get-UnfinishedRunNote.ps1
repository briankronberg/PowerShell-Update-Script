function Get-UnfinishedRunNote {
    <#
        .SYNOPSIS
        Says whether the previous run's transcript stops without finishing.

        .DESCRIPTION
        A run stopped by the task's execution time limit, or by a window closed
        early, dies mid-step: its transcript has a start line and no summary, and
        nothing else records that it happened. This reads the newest transcript
        other than the current run's and returns a sentence when that transcript
        started a run and never reached any of the lines a run ends on.

        A parent that handed off to an elevated child ends on the hand-off line
        and is not unfinished: its work went to the child's transcript. A run
        that declined at the pre-run prompt, or could not elevate, ended on
        purpose and says so.

        .PARAMETER LogDirectory
        Where the transcripts are.

        .PARAMETER CurrentLog
        This run's transcript, which is excluded.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [string] $LogDirectory,
        [Parameter(Mandatory)] [string] $CurrentLog
    )

    # The stamp in the name sorts chronologically; LastWriteTime does not, once a
    # transcript has been appended to by a re-opened parent.
    $previous = Get-ChildItem -LiteralPath $LogDirectory -Filter 'Update-Everything-*.log' -File -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -ne $CurrentLog } |
        Sort-Object Name -Descending |
        Select-Object -First 1
    if (-not $previous) { return }

    $text = Get-Content -LiteralPath $previous.FullName -Raw -ErrorAction SilentlyContinue
    if (-not $text) { return }

    $started = [regex]::Match($text, 'Maintenance run started (?<when>[^|]+?)\s+\|')
    if (-not $started.Success) { return }

    # The lines a run ends on. Any one of them means the run reached its own end.
    $ended = @(
        'Finished \d'
        'Elevated run finished'
        'Handing off to an elevated run'
        'Skipped at your request'
        'Cannot run elevated'
    )
    foreach ($marker in $ended) {
        if ($text -match $marker) { return }
    }

    $steps = [regex]::Matches($text, '=== STARTING: (?<step>.+?) ===')
    $last = if ($steps.Count) { $steps[$steps.Count - 1].Groups['step'].Value } else { $null }

    $note = "The previous run, started $($started.Groups['when'].Value.Trim()), did not finish"
    $note += if ($last) { "; its last step was '$last'." } else { '; no step had started.' }
    $note += " A run stopped at the task's time limit, or by a closed window, ends this way. See $($previous.FullName)"
    $note
}
