function Test-AdministratorGroupMember {
    # Whether this account could become an administrator, as opposed to already
    # being one. Returns $true, $false, or $null when it cannot be determined.
    #
    # Checking the current token's groups for S-1-5-32-544 does not work, and
    # fails in the dangerous direction: on a filtered (split) token Windows drops
    # that SID entirely, so a genuine administrator reports as a standard user
    # and the caller would refuse to elevate an account that could have elevated.
    #
    # The group is queried instead, by SID rather than by name, because
    # 'Administrators' is localised. Anything unresolvable returns $null, and the
    # caller treats unknown as "attempt it" rather than "refuse".
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseOutputTypeCorrectly', '', Justification = 'Deliberately tri-state: true, false, or null when membership cannot be determined. No single OutputType describes that honestly.')]
    [CmdletBinding()]
    param()

    try {
        $members = @(Get-LocalGroupMember -SID 'S-1-5-32-544' -ErrorAction Stop)
    } catch {
        # No LocalAccounts module, a domain controller, or an access denial.
        return $null
    }

    $me = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    foreach ($member in $members) {
        if ($member.SID.Value -eq $me) { return $true }
    }

    # A nested group could still grant membership, and resolving that needs a
    # domain round trip. Unknown beats a wrong "no".
    if ($members | Where-Object { $_.ObjectClass -eq 'Group' }) { return $null }

    return $false
}
