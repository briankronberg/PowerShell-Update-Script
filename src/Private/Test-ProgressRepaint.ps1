function Test-ProgressRepaint {
    <#
        .SYNOPSIS
        Whether a captured line is a leftover frame from a redrawing progress
        bar rather than something worth reading.

        .DESCRIPTION
        winget draws progress by repainting a bar with carriage returns.
        PowerShell splits captured native output on those, so every repaint
        arrives as its own line and one download becomes a column of spinner
        characters and percentages.

        Nothing suppresses it upstream: --disable-interactivity governs prompts,
        not rendering, and the bar does not go through the PowerShell progress
        stream where $ProgressPreference would reach it.

        The patterns are narrow -- a bar, a bare percentage, a spinner tick --
        because this runs over every line of every step, and dropping real
        output to tidy a log would be the worse bug.

        .PARAMETER Line
        One line of captured step output.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string] $Line
    )

    if ([string]::IsNullOrWhiteSpace($Line)) { return $false }

    # A spinner tick, alone on its line. Compared as a string rather than with
    # a character class, because "[-\\|/]" needs the backslash doubled to mean a
    # backslash and one written as "[-\|/]" silently becomes an escaped pipe --
    # which matches every tick except the one that looks like an escape.
    $trimmed = $Line.Trim()
    if ($trimmed.Length -eq 1 -and '-\|/'.Contains($trimmed)) { return $true }

    # A bare percentage, which is what the bar's label becomes once the bar
    # itself has been drawn with box characters this console cannot show.
    if ($Line -match '^\s*\d{1,3}\s*%\s*$') { return $true }

    # A bar: the box-drawing and block characters winget draws it with,
    # optionally labelled with a percentage. Stripping those leaves nothing a
    # person would want to read.
    #
    # '#' and '=' are deliberately not in this set. Plenty of real output rules
    # a line off with them, and a table underline of '-' has to survive too --
    # which it does, because the spinner pattern above matches a single
    # character, not a run of them.
    $stripped = $Line -replace '[\u2500-\u259F\u25A0-\u25FF\s]', ''
    if (-not $stripped) { return $true }
    if ($stripped -match '^\d{1,3}%$') { return $true }

    $false
}
