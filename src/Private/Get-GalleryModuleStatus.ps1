function Get-GalleryModuleStatus {
    <#
        .SYNOPSIS
        Compares the newest installed version of a module against the newest on
        the PowerShell Gallery.

        .DESCRIPTION
        Returns Name, Installed, Available, Updatable and NeedsUpdate.

        Installed is $null when the module is absent. Absent means any install
        is a new install and needs consent; present but old means an update,
        which does not.

        Available is $null when the gallery could not be reached or does not
        carry the name, and NeedsUpdate is then $false, so neither presents as
        a reason to reinstall. An update is never reported for a module that is
        not installed.

        Updatable reports whether Update-Module can move this copy forward. It
        refuses anything it did not install, answering "Module 'X' was not
        installed by using Install-Module, so it cannot be updated" -- which
        covers every module that shipped with the host, and any copy whose
        receipt names an older version than the newest one installed, since
        Update-Module moves only the receipted lineage. Windows PowerShell
        ships PowerShellGet 1.0.0.1
        under Program Files rather than $PSHOME, so the path is not the test;
        whether PowerShellGet recorded the install is. Moving a shipped copy
        forward is a side-by-side install, and so an install decision.

        .PARAMETER Name
        The module to look up, on this machine and on the gallery.

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
    # which is exactly the set Update-Module will act on -- and the receipt has
    # to cover the newest installed copy, the one Installed names. A machine can
    # carry a receipted older version beside a GitHub-installed newer one, and
    # Update-Module moves only the receipted lineage.
    $updatable = $false
    if ($present.Count -and (Get-Command Get-InstalledModule -ErrorAction SilentlyContinue)) {
        $receipt = Get-InstalledModule -Name $Name -ErrorAction SilentlyContinue
        if ($receipt) {
            $raw = "$($receipt.Version)" -replace '-.*$', ''
            $updatable = [bool] ($raw -and ([version] $raw -eq $installed))
        }
    }

    # SilentlyContinue and a check, not Stop and a catch. A module the gallery
    # does not have, and a gallery that cannot be reached, are both ordinary
    # answers here rather than faults -- and Start-Transcript records a
    # terminating error whether or not it is caught, so throwing for either would
    # put "TerminatingError(Find-Module)" in a run log where nothing went wrong.
    # Since the self-version check calls this on every run, that would be every
    # run on a machine with no network.
    $available = $null
    $found = $null
    try {
        # The catch is a backstop, not the mechanism. SilentlyContinue keeps the
        # ordinary answers -- no such module, gallery unreachable -- from
        # throwing at all, which is what keeps them out of the transcript. A
        # genuinely terminating failure still exists and still has to not take
        # the step with it.
        $found = Find-Module -Name $Name -Repository PSGallery -ErrorAction SilentlyContinue
    } catch {
        Write-Verbose "Asking the gallery about ${Name} failed outright: $($_.Exception.Message)"
    }

    if ($found) {
        # Find-Module returns the version as a string on some PowerShellGet
        # versions and a [version] on others, and a prerelease carries a suffix
        # that [version] cannot parse. Trim the suffix and let the cast decide.
        $raw = "$($found.Version)" -replace '-.*$', ''
        if ($raw) { $available = [version] $raw }
    } else {
        Write-Verbose "The gallery had no answer for ${Name}; it may be absent or unreachable."
    }

    [pscustomobject]@{
        Name        = $Name
        Installed   = $installed
        Available   = $available
        Updatable   = $updatable
        NeedsUpdate = [bool] ($installed -and $available -and $available -gt $installed)
    }
}
