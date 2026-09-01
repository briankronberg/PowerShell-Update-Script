function Get-WingetUpgradeTable {
    <#
        .SYNOPSIS
        Parses the table winget prints for available upgrades.

        .DESCRIPTION
        Returns one object per row, with whatever the columns held. The columns
        are found from the header's word positions rather than by name, because
        winget localises its headers -- "Name" and "Id" are English, and the
        table is not.

        The row of dashes under the header is the anchor. It is the one line in
        winget's output that is the same in every language.

        Ids arrive truncated when the console is narrower than the table, and
        that is left alone rather than repaired. This exists to compare one
        listing against another, and two listings truncated the same way compare
        correctly. An Id that reads "Microsoft.VisualStudio..." is also still
        recognisable to the person reading it, which is the other half of the
        job.

        Returns nothing when the text holds no table, which is the ordinary case
        when everything is up to date.

        .PARAMETER Text
        winget's output, as captured.

        .EXAMPLE
        Get-WingetUpgradeTable -Text (winget upgrade --include-unknown | Out-String)
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string] $Text
    )

    if (-not $Text) { return }

    $lines = $Text -split '\r?\n'

    # The separator is a run of dashes on its own. Anything shorter than a few
    # characters is not it -- some locales underline other things.
    $separator = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^-{8,}\s*$') { $separator = $i; break }
    }
    if ($separator -lt 1) { return }

    $header = $lines[$separator - 1]

    # Column starts: every position where a non-space follows a space, plus the
    # first character. Fixed-width, so a row is sliced at the same offsets.
    $starts = [System.Collections.Generic.List[int]]::new()
    for ($i = 0; $i -lt $header.Length; $i++) {
        if ($header[$i] -ne ' ' -and ($i -eq 0 -or $header[$i - 1] -eq ' ')) {
            $starts.Add($i)
        }
    }
    if ($starts.Count -lt 2) { return }

    foreach ($line in $lines[($separator + 1)..($lines.Count - 1)]) {
        # The table ends at the first blank line. What follows is winget's own
        # summary, which is localised and is not a row.
        if (-not $line -or -not $line.Trim()) { break }

        # A row shorter than the second column start is not a row.
        if ($line.Length -le $starts[1]) { continue }

        $fields = for ($c = 0; $c -lt $starts.Count; $c++) {
            $from = $starts[$c]
            if ($from -ge $line.Length) { '' ; continue }

            $to = if ($c + 1 -lt $starts.Count) { [Math]::Min($starts[$c + 1], $line.Length) } else { $line.Length }
            $line.Substring($from, $to - $from).Trim()
        }

        $fields = @($fields)

        [pscustomobject]@{
            Name      = $fields[0]
            Id        = if ($fields.Count -gt 1) { $fields[1] } else { '' }
            Version   = if ($fields.Count -gt 2) { $fields[2] } else { '' }
            Available = if ($fields.Count -gt 3) { $fields[3] } else { '' }
        }
    }
}
