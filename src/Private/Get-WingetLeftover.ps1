function Get-WingetLeftover {
    <#
        .SYNOPSIS
        Works out which packages an upgrade pass left behind, and why.

        .DESCRIPTION
        "winget upgrade --all" returns one exit code for the whole pass, so a
        partial failure says only that something did not upgrade. This says
        which, and separates two outcomes needing different answers:

          Attempted   winget tried and the install failed. Worth retrying, and
                      often fixable -- a package whose executable is running
                      cannot be replaced until it is closed.

          Skipped     winget listed it and never tried. Usually "a newer package
                      version is available in a configured source, but it does
                      not apply to your system or requirements", which is
                      permanent until the vendor ships something that applies.
                      Reporting it as a failure every run teaches people to skim
                      past it.

        Attempted is decided by winget's own "Found <name> [<id>]" line. The rest
        of the output is localised prose.

        .PARAMETER Before
        The upgrade table from before the pass.

        .PARAMETER After
        The upgrade table from after it.

        .PARAMETER Output
        What the pass printed, for deciding attempted from skipped.

        .EXAMPLE
        Get-WingetLeftover -Before $before -After $after -Output $captured
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [object[]] $Before = @(),
        [object[]] $After = @(),
        [string] $Output
    )

    $stillListed = @($After | Where-Object { $_.Id })
    if (-not $stillListed.Count) { return }

    foreach ($package in $stillListed) {
        # Compared against the same listing style it came from, so a truncated
        # Id matches a truncated Id.
        $wasListed = [bool] @($Before | Where-Object { $_.Id -eq $package.Id }).Count

        # Only count it as attempted when winget named it. A substring search of
        # the whole output would match the upgrade table itself, which lists
        # every package including the ones never tried.
        $attempted = $false
        $reason = $null

        if ($Output -and $package.Id) {
            $marker = [regex]::Escape($package.Id)
            if ($Output -match "\[$marker\]") {
                $attempted = $true

                # winget says "Access is denied" when it cannot replace a file,
                # which on Windows almost always means the executable is running.
                # That is the one failure a person can act on immediately, so it
                # is worth naming rather than leaving in the step log.
                if ($Output -match '(?i)access is denied') {
                    $reason = 'the install failed; a file was in use, so close the program and run again'
                } else {
                    $reason = 'the install failed'
                }
            }
        }

        if (-not $attempted) {
            $reason = if ($wasListed) {
                'winget listed it and did not attempt it, usually because the newer package does not apply to this system'
            } else {
                'it appeared during this run'
            }
        }

        [pscustomobject]@{
            Name      = $package.Name
            Id        = $package.Id
            Version   = $package.Version
            Available = $package.Available
            Attempted = $attempted
            Reason    = $reason
        }
    }
}
