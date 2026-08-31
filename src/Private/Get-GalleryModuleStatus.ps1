function Get-GalleryModuleStatus {
    <#
        .SYNOPSIS
        Compares the newest installed version of a module against the newest on
        the PowerShell Gallery.

        .DESCRIPTION
        Returns Installed, Available and NeedsUpdate.

        Installed is $null when the module is not on the machine at all, which is
        a different answer from "installed but old" and the caller acts on it
        differently: one is an install and needs consent, the other is an update
        and does not.

        Available is $null when the gallery could not be reached. NeedsUpdate is
        then $false, so a network failure presents as "cannot tell" rather than
        as a reason to reinstall. It never reports an update as available for a
        module that is not installed.

        Updatable reports whether Update-Module can move this copy forward at
        all. It refuses anything it did not install -- "Module 'X' was not
        installed by using Install-Module, so it cannot be updated" -- which
        covers every module that shipped with the host, wherever it sits.
        Windows PowerShell ships PowerShellGet 1.0.0.1 under Program Files
        rather than $PSHOME, so the path is not the test; whether PowerShellGet
        recorded the install is.

        A shipped copy is not stuck, but moving it forward is a side-by-side
        install rather than an update, and so it is an install decision.

        .EXAMPLE
        Get-GalleryModuleStatus -Name PowerShellGet
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Name
    )

    # Indexed rather than "| Select-Object -First 1": that halts the upstream
    # pipeline, and inside a step action the transcript records the stop as a
    # TerminatingError.
    $present = @(Get-Module -Name $Name -ListAvailable -ErrorAction SilentlyContinue |
        Sort-Object Version -Descending)
    $installed = if ($present.Count) { [version] $present[0].Version } else { $null }

    # Ask PowerShellGet what it installed, rather than inferring it from the
    # path. Get-InstalledModule reports only what came through Install-Module,
    # which is exactly the set Update-Module will act on.
    $updatable = $false
    if ($present.Count -and (Get-Command Get-InstalledModule -ErrorAction SilentlyContinue)) {
        $updatable = [bool] (Get-InstalledModule -Name $Name -ErrorAction SilentlyContinue)
    }

    $available = $null
    try {
        $found = Find-Module -Name $Name -Repository PSGallery -ErrorAction Stop

        # Find-Module returns the version as a string on some PowerShellGet
        # versions and a [version] on others, and a prerelease carries a suffix
        # that [version] cannot parse. Trim the suffix and let the cast decide.
        $raw = "$($found.Version)" -replace '-.*$', ''
        if ($raw) { $available = [version] $raw }
    } catch {
        Write-Verbose "Could not ask the gallery about ${Name}: $($_.Exception.Message)"
    }

    [pscustomobject]@{
        Name        = $Name
        Installed   = $installed
        Available   = $available
        Updatable   = $updatable
        NeedsUpdate = [bool] ($installed -and $available -and $available -gt $installed)
    }
}
