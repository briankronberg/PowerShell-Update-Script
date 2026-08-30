function Add-SkippedStep {
    param(
        [Parameter(Mandatory)][string] $Name,
        [string]                       $Reason = 'disabled by parameter'
    )
    Write-Host "`nSKIP  $Name ($Reason)" -ForegroundColor DarkGray
    $script:Results.Add([pscustomobject]@{ Step = $Name; Status = 'Skipped'; Seconds = 0; Log = '' })
}
