function Approve-Install {
    # Decides whether a first-time install may proceed. Approval comes from
    # -AllowInstall, or from asking; the answer is remembered for the rest of the
    # run so a component is never asked about twice.
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string] $Component,
        [Parameter(Mandatory)][string] $Description,

        # The caller's -AllowInstall list.
        [string[]] $Approved = @()
    )

    if ($Approved -contains 'All' -or $Approved -contains $Component) {
        return $true
    }

    if ($null -eq $script:InstallDecision) { $script:InstallDecision = @{} }
    if ($script:InstallDecision.ContainsKey($Component)) {
        return $script:InstallDecision[$Component]
    }

    if (-not (Test-CanPrompt)) {
        # A scheduled run has nobody to ask, and silently installing software on
        # a machine nobody is watching is exactly what this gate exists to stop.
        # "needs installing", not "is not installed": a component can also reach
        # here when it is present in a form that cannot be updated in place, and
        # replacing that is still an install.
        Write-Warning "$Component needs installing, and this run cannot prompt for consent. Re-run with -AllowInstall $Component (or -AllowInstall All) to permit it."
        $script:InstallDecision[$Component] = $false
        return $false
    }

    $granted = Request-InstallConsent -Component $Component -Description $Description
    $script:InstallDecision[$Component] = $granted

    if (-not $granted) {
        Write-Warning "Declined to install $Component. The step that needs it will be skipped."
    }

    return $granted
}
