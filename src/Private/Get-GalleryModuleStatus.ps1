function Get-GalleryModuleStatus {
    <#
        .SYNOPSIS
        Compares the newest installed version of a module against the newest on
        the PowerShell Gallery.

        .DESCRIPTION
        Returns Name, Installed, Available, Receipted, ReceiptedBy, Updatable,
        Mover, MoverScope and NeedsUpdate. ReceiptedBy names the client whose
        receipts exist -- PSResourceGet or PowerShellGet -- whether or not one
        of them covers the newest copy, so advice can name the reinstall
        command that lineage answers to. MoverScope is the installation scope of the
        covering receipt -- CurrentUser or AllUsers -- because Update-PSResource
        must be told when the copy to move is the machine-wide one.

        Installed is $null when the module is absent. Absent means any install
        is a new install and needs consent; present but old means an update,
        which does not.

        Available is $null when the gallery could not be reached or does not
        carry the name, and NeedsUpdate is then $false, so neither presents as
        a reason to reinstall. An update is never reported for a module that is
        not installed.

        Updatable reports whether an installed gallery client can move this
        copy forward, and Mover names the command that can -- Update-PSResource
        or Update-Module -- or is $null. Both clients refuse anything they did
        not install, which covers every module that shipped with the host, and
        any copy whose receipt names an older version than the newest one
        installed, since each client moves only its receipted lineage. Windows
        PowerShell ships PowerShellGet 1.0.0.1 under Program Files rather than
        $PSHOME, so the path is not the test; whether a client recorded the
        install is. Moving a shipped copy forward is a side-by-side install,
        and so an install decision.

        Receipts come from both clients. PSResourceGet ships in the box with
        PowerShell 7.4 and its receipts are invisible to Get-InstalledModule,
        so a machine can hold a gallery-installed module that PowerShellGet
        has never heard of.

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

    # Ask the gallery clients what they installed, rather than inferring it
    # from the path. Each reader reports only what its client installed, which
    # is exactly the set its Update-* command will act on -- and a receipt has
    # to cover the newest installed copy, the one Installed names. A machine
    # can carry a receipted older version beside a GitHub-installed newer one,
    # and each client moves only its receipted lineage -- so a caller
    # distinguishes "no gallery lineage" (not Receipted) from "gallery
    # lineage, but behind the copy running" (Receipted, not Updatable).
    #
    # PSResourceGet is asked first: it reads PowerShellGet's receipts as well
    # as its own, so its answer exists more often, and Update-PSResource is
    # then the client that moves the copy.
    $receipted = $false
    $receiptedBy = $null
    $updatable = $false
    $mover = $null
    $moverScope = $null
    if ($present.Count) {
        foreach ($client in @(
                @{ Reader = 'Get-InstalledPSResource'; Mover = 'Update-PSResource'; Client = 'PSResourceGet' }
                @{ Reader = 'Get-InstalledModule';     Mover = 'Update-Module';     Client = 'PowerShellGet' }
            )) {
            if (-not (Get-Command $client.Reader -ErrorAction SilentlyContinue)) { continue }

            # PSResourceGet lists every installed version, not just the newest
            # -- and its bare call reads only the per-user paths, so the
            # machine scope is asked separately or an AllUsers install reports
            # no receipt at all. Get-InstalledModule takes no -Scope and reads
            # every path in one call.
            $receipts = @(& $client.Reader -Name $Name -ErrorAction SilentlyContinue)
            if ($client.Reader -eq 'Get-InstalledPSResource') {
                $receipts += @(& $client.Reader -Name $Name -Scope AllUsers -ErrorAction SilentlyContinue)
            }
            if (-not $receipts.Count) { continue }
            $receipted = $true
            if (-not $receiptedBy) { $receiptedBy = $client.Client }

            foreach ($receipt in $receipts) {
                $raw = "$($receipt.Version)" -replace '-.*$', ''
                $parsed = $null
                if (-not ($raw -and [version]::TryParse($raw, [ref] $parsed) -and $parsed -eq $installed)) { continue }

                $updatable = $true
                $mover = $client.Mover

                # The covering receipt says which scope the update must target.
                # A per-user receipt wins when both scopes cover: that copy
                # shadows the machine one in PSModulePath order, and moving it
                # needs no elevation.
                $scope = if ("$($receipt.InstalledLocation)" -like (Join-Path $env:ProgramFiles '*')) { 'AllUsers' } else { 'CurrentUser' }
                if (-not $moverScope -or $scope -eq 'CurrentUser') { $moverScope = $scope }
                if ($moverScope -eq 'CurrentUser') { break }
            }
            if ($mover) { break }
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
        $parsedAvailable = $null
        if ($raw -and [version]::TryParse($raw, [ref] $parsedAvailable)) { $available = $parsedAvailable }
    } else {
        Write-Verbose "The gallery had no answer for ${Name}; it may be absent or unreachable."
    }

    [pscustomobject]@{
        Name        = $Name
        Installed   = $installed
        Available   = $available
        Receipted   = $receipted
        ReceiptedBy = $receiptedBy
        Updatable   = $updatable
        Mover       = $mover
        MoverScope  = $moverScope
        NeedsUpdate = [bool] ($installed -and $available -and $available -gt $installed)
    }
}
