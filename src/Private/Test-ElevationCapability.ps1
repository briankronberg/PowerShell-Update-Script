function Test-ElevationCapability {
    # Decides, before anything is attempted, whether this run can become
    # Administrator -- so the script can explain itself instead of raising a UAC
    # prompt that cannot succeed, or hanging on one that never appears.
    [CmdletBinding()]
    param()

    if (Test-IsAdministrator) {
        return [pscustomobject]@{
            IsElevated = $true
            CanElevate = $true
            Reason     = 'Already running as Administrator.'
        }
    }

    # Only a definite $false blocks the run. $null means "could not tell", and
    # guessing wrong here would refuse to run for a legitimate administrator.
    if ((Test-AdministratorGroupMember) -eq $false) {
        return [pscustomobject]@{
            IsElevated = $false
            CanElevate = $false
            Reason     = 'This account is not a member of the local Administrators group, so Windows will not grant elevation. An administrator has to run the script, or use -SkipElevation to run the steps that do not need admin.'
        }
    }

    if (-not (Test-UacEnabled)) {
        return [pscustomobject]@{
            IsElevated = $false
            CanElevate = $false
            Reason     = 'UAC (EnableLUA) is disabled, so this session cannot request elevation. Sign in with an elevated session, or use -SkipElevation.'
        }
    }

    # An MSIX PowerShell cannot be elevated at all: Windows does not run packaged
    # apps elevated, and the app execution alias that also reaches it is a
    # zero-byte reparse point rather than a program. Saying so here is this
    # function's whole purpose -- otherwise the run raises a UAC prompt that
    # cannot succeed and reports the failure as though the user had declined it.
    # The MSI build, if it is installed alongside, can elevate, and
    # Invoke-SelfElevation relaunches through it.
    if ((Test-PackagedProcess) -and -not (Test-Path -LiteralPath (Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe'))) {
        return [pscustomobject]@{
            IsElevated = $false
            CanElevate = $false
            Reason     = 'This session is the MSIX build of PowerShell (the Store and winget default), and Windows does not run packaged apps elevated. Install the MSI build with "winget install --id Microsoft.PowerShell --exact --source winget --installer-type wix", start an elevated session yourself, or use -SkipElevation.'
        }
    }

    [pscustomobject]@{
        IsElevated = $false
        CanElevate = $true
        Reason     = 'Elevation can be requested.'
    }
}
