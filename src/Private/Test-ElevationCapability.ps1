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

    [pscustomobject]@{
        IsElevated = $false
        CanElevate = $true
        Reason     = 'Elevation can be requested.'
    }
}
