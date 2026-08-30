function Write-StepLog {
    <#
        .SYNOPSIS
        Appends a line to a step log, in one explicit encoding.

        .DESCRIPTION
        The encoding is explicit because it has to be. Add-Content defaults to
        ANSI in Windows PowerShell, and Tee-Object -FilePath writes UTF-16LE
        there with no -Encoding parameter to override it. A step log written by
        both came out half readable text and half interleaved nulls:

            2026-08-29 21:15:14 | STARTING Trust PSGallery
            P S G a l l e r y   ( P o w e r S h e l l G e t   v 2 )   s e t ...

        Logging must never be the thing that kills a run, so failures here
        degrade to a warning rather than propagating.
    #>
    [CmdletBinding(DefaultParameterSetName = 'Stamped')]
    param(
        [Parameter(Mandatory)]
        [string] $Path,

        # A status line. Timestamped, because these are the lines someone greps.
        [Parameter(Mandatory, ParameterSetName = 'Stamped')]
        [string] $Message,

        # Captured step output, already rendered to text. Written verbatim: a
        # timestamp per line would wreck the layout of anything drawing a table.
        [Parameter(Mandatory, ParameterSetName = 'Raw')]
        [AllowEmptyString()]
        [string] $Raw
    )

    $text = if ($PSCmdlet.ParameterSetName -eq 'Raw') {
        $Raw
    } else {
        '{0:yyyy-MM-dd HH:mm:ss} | {1}' -f (Get-Date), $Message
    }

    try {
        # AppendAllText rather than Add-Content: it takes the encoding as an
        # argument on both editions, where Add-Content -Encoding utf8 means
        # "with BOM" on 5.1 and "without" on 7.
        [System.IO.File]::AppendAllText(
            $Path,
            $text + [Environment]::NewLine,
            [System.Text.UTF8Encoding]::new($false))
    } catch {
        Write-Warning "Could not write to step log '$Path': $($_.Exception.Message)"
    }
}
