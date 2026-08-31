function Install-DeveloperTool {
    <#
        .SYNOPSIS
        Installs tools chosen from the developer-tools catalogue, through winget.

        .DESCRIPTION
        -Name is what the person picked from the menu, and that selection is also
        the approval: it is passed to Approve-Install as the approved list, so a
        tool the person chose does not ask a second time and a tool they did not
        choose cannot be installed.

        The run's -AllowInstall is deliberately not consulted. -AllowInstall All
        means "approve the components this update run needs", six named things
        that are each a prerequisite for updating something else. Letting it also
        mean "install a dozen developer tools" would turn an unattended scheduled
        task from a maintenance job into a provisioning one, through a flag people
        already have in their task definitions.

        A tool already on PATH is reported and skipped. The update run covers it
        from then on.

        .PARAMETER Name
        Catalogue names to install. Anything not in the catalogue is refused
        rather than passed to winget, so a typo cannot install something else.

        .EXAMPLE
        Install-DeveloperTool -Name Git, 'Node.js LTS'
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Called only from the setup menu, where the caller has already picked from a list and confirmed. Approve-Install gates each install in turn.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Write-Host is the user interface of a console maintenance tool. This runs from an interactive menu, not inside a step, so it is not captured by Invoke-Step.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string[]] $Name
    )

    if (-not (Get-Command winget -CommandType Application -ErrorAction SilentlyContinue)) {
        Write-Warning 'winget is not available, so nothing can be installed. It ships with App Installer from the Microsoft Store.'
        return
    }

    $catalogue = @(Get-DeveloperToolCatalogue)
    $installed = 0
    $skipped = 0
    $failed = 0

    foreach ($wanted in $Name) {
        $tool = $catalogue | Where-Object { $_.Name -eq $wanted } | Select-Object -First 1

        if (-not $tool) {
            Write-Warning "'$wanted' is not in the catalogue; nothing was installed for it."
            $skipped++
            continue
        }

        if ($tool.Present) {
            Write-Host "  $($tool.Name) is already installed; the update run covers it from here." -ForegroundColor DarkGray
            $skipped++
            continue
        }

        # The selection is the approval. $Name, not the run's -AllowInstall, so
        # 'All' in a scheduled task cannot reach this.
        if (-not (Approve-Install -Component $tool.Name -Approved $Name `
                    -Description "$($tool.Description). This would install $($tool.Id) through winget.")) {
            $skipped++
            continue
        }

        Write-Host "  Installing $($tool.Name) ($($tool.Id))..." -ForegroundColor Cyan

        $arguments = @('install', '--id', $tool.Id, '--exact', '--source', 'winget',
                       '--accept-source-agreements', '--accept-package-agreements',
                       '--disable-interactivity')
        if ($tool.InstallerType) { $arguments += @('--installer-type', $tool.InstallerType) }

        winget @arguments
        $code = $LASTEXITCODE
        $global:LASTEXITCODE = 0

        if ($code -eq 0) {
            Write-Host "  Installed $($tool.Name)." -ForegroundColor Green
            $installed++
        } else {
            Write-Warning ("winget returned {0} (0x{0:X8}) for $($tool.Name); it was not installed." -f $code)
            $failed++
        }
    }

    [pscustomobject]@{
        Installed = $installed
        Skipped   = $skipped
        Failed    = $failed
    }
}
