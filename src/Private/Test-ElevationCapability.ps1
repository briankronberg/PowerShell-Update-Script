function Test-ElevationCapability {
    <#
        .SYNOPSIS
        Decides, before anything is attempted, whether this run can become
        Administrator.

        .DESCRIPTION
        Returns IsElevated, CanElevate, Reason, and Caution.

        Only two things refuse outright, and both are certain rather than
        probable: UAC switched off, and a packaged PowerShell with no MSI build
        beside it. In each case Windows will not grant elevation to anybody, so
        raising a prompt would waste a person's time and then report the failure
        as though they had declined it.

        Not being in the local Administrators group is a Caution, not a refusal.
        It used to be a refusal, and that was wrong on any machine running a
        privilege-management broker -- BeyondTrust, CyberArk EPM, Admin By
        Request and others -- where the account is deliberately not in the group
        and elevates anyway, often per application. Measured on one such laptop:
        not a member, Avecto Defendpoint running, elevated sessions working all
        day, and this function refusing to try.

        The harm is lopsided. Refusing wrongly makes the module unusable and says
        something untrue about the machine. Attempting wrongly costs one prompt
        that fails, which Invoke-SelfElevation already reports well and
        Get-ElevationPolicyNote already explains.

        .EXAMPLE
        $elevation = Test-ElevationCapability
        if (-not $elevation.CanElevate) { Write-Warning $elevation.Reason }
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()

    if (Test-IsAdministrator) {
        return [pscustomobject]@{
            IsElevated = $true
            CanElevate = $true
            Reason     = 'Already running as Administrator.'
            Caution    = $null
        }
    }

    if (-not (Test-UacEnabled)) {
        return [pscustomobject]@{
            IsElevated = $false
            CanElevate = $false
            Reason     = 'UAC (EnableLUA) is disabled, so this session cannot request elevation. Sign in with an elevated session, or use -SkipElevation.'
            Caution    = $null
        }
    }

    # An MSIX PowerShell cannot be elevated at all: Windows does not run packaged
    # apps elevated, and the app execution alias that also reaches it is a
    # zero-byte reparse point rather than a program. This one is a genuine
    # certainty -- it does not depend on who is asking -- so it still refuses.
    # The MSI build, if it is installed alongside, can elevate, and
    # Invoke-SelfElevation relaunches through it.
    if ((Test-PackagedProcess) -and -not (Test-Path -LiteralPath (Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe'))) {
        return [pscustomobject]@{
            IsElevated = $false
            CanElevate = $false
            Reason     = 'This session is the MSIX build of PowerShell (the Store and winget default), and Windows does not run packaged apps elevated. Install the MSI build with "winget install --id Microsoft.PowerShell --exact --source winget --installer-type wix", start an elevated session yourself, or use -SkipElevation.'
            Caution    = $null
        }
    }

    # A definite "not in the group" is worth saying and not worth refusing over.
    # $null means it could not be determined at all, which was never grounds for
    # anything.
    $caution = $null
    if ((Test-AdministratorGroupMember) -eq $false) {
        $caution = 'This account is not in the local Administrators group, so the prompt may be refused. Machines using a privilege-management broker elevate without that membership, so it is worth attempting. If it fails, -SkipElevation runs the steps that do not need admin.'
    }

    [pscustomobject]@{
        IsElevated = $false
        CanElevate = $true
        Reason     = 'Elevation can be requested.'
        Caution    = $caution
    }
}
