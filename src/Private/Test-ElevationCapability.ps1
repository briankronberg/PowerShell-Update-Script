function Test-ElevationCapability {
    <#
        .SYNOPSIS
        Decides, before anything is attempted, whether this run can become
        Administrator.

        .DESCRIPTION
        Returns IsElevated, CanElevate, Reason, and Caution.

        Only two conditions refuse outright, and both are certain rather than
        probable: UAC switched off, and a packaged PowerShell with no MSI build
        beside it. In each case Windows will not grant elevation to anybody, so
        raising a prompt would waste a person's time and then report the failure
        as though they had declined it.

        Not being in the local Administrators group is a Caution, not a refusal.
        Machines running a privilege-management broker -- BeyondTrust, CyberArk
        EPM, Admin By Request and others -- keep the account out of that group
        and elevate it anyway, often per application, so membership does not
        settle whether elevation is available. A prompt that then fails costs
        one refusal, which Invoke-SelfElevation reports and
        Get-ElevationPolicyNote explains.

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
    # zero-byte reparse point rather than a program. The result does not depend
    # on who is asking. The MSI build, if it is installed alongside, can
    # elevate, and Invoke-SelfElevation relaunches through it.
    if ((Test-PackagedProcess) -and -not (Test-Path -LiteralPath (Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe'))) {
        return [pscustomobject]@{
            IsElevated = $false
            CanElevate = $false
            Reason     = 'This session is the MSIX build of PowerShell (the Store and winget default), and Windows does not run packaged apps elevated. Install the MSI build with "winget install --id Microsoft.PowerShell --exact --source winget --installer-type wix", start an elevated session yourself, or use -SkipElevation.'
            Caution    = $null
        }
    }

    # $false is a definite "not in the group" and is worth saying. $null means
    # the answer could not be determined -- a filtered token hides the SID --
    # and neither is grounds for refusing.
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
