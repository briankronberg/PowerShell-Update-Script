function Add-SkippedStep {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Write-Host is the user interface of a console maintenance tool. Its output is progress a person watches, not data a caller consumes, and the summary uses colour to separate failures from noise.')]
    param(
        [Parameter(Mandatory)][string] $Name,
        [string]                       $Reason = 'disabled by parameter'
    )
    Write-Host "`nSKIP  $Name ($Reason)" -ForegroundColor DarkGray
    $script:Results.Add([pscustomobject]@{ Step = $Name; Status = 'Skipped'; Seconds = 0; Log = '' })
}
