function Get-ElevationPolicyNote {
    <#
        .SYNOPSIS
        Explains, from policy, why an elevation attempt was refused.

        .DESCRIPTION
        Reporting rather than deciding, and deliberately so. Refusing a run over
        these values would lock out the people most likely to be affected by
        them: Test-AdministratorGroupMember already returns $null when a
        filtered token hides the Administrators SID, and treating an unknown
        answer plus a restrictive policy as "cannot elevate" would turn a real
        administrator away. Nothing here changes what is attempted. It only
        names what is set, once the attempt has already failed.

        "Elevation was declined or failed" is true and useless on a managed
        machine. Naming the value that did it turns the same failure into
        something someone can take to whoever manages the policy.

        The values that explain a failure:

          ConsentPromptBehaviorUser = 0     a standard user's request is denied
                                            outright; no prompt is ever shown
          ValidateAdminCodeSignatures = 1   only executables with a validated
                                            signature may elevate
          EnableLUA = 0                     there is no consent prompt to answer

        Returns nothing when none of them is set restrictively, so a caller can
        append the result and say nothing extra on an ordinary machine.

        .EXAMPLE
        $note = Get-ElevationPolicyNote
        if ($note) { Write-Warning $note }
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $policy = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'

    # One read, then look for the values on the object. Asking for a named value
    # that is absent throws, and Start-Transcript records the throw even when it
    # is caught -- which reads as a fault in a log where nothing went wrong.
    $values = Get-ItemProperty -LiteralPath $policy -ErrorAction SilentlyContinue
    if (-not $values) { return }

    $names = $values.PSObject.Properties.Name
    $notes = [System.Collections.Generic.List[string]]::new()

    if ($names -contains 'EnableLUA' -and $values.EnableLUA -eq 0) {
        $notes.Add('UAC is switched off (EnableLUA is 0), so there is no consent prompt to answer.')
    }

    if ($names -contains 'ConsentPromptBehaviorUser' -and $values.ConsentPromptBehaviorUser -eq 0) {
        $notes.Add('Policy denies elevation requests from standard users outright (ConsentPromptBehaviorUser is 0), so a standard user is never prompted.')
    }

    if ($names -contains 'ValidateAdminCodeSignatures' -and $values.ValidateAdminCodeSignatures -eq 1) {
        $notes.Add('Policy allows only executables with a validated signature to elevate (ValidateAdminCodeSignatures is 1).')
    }

    if ($notes.Count -eq 0) { return }

    'Policy on this machine may be the cause: ' + ($notes -join ' ')
}
