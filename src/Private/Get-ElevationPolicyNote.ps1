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

        The registry values that explain a failure:

          ConsentPromptBehaviorUser = 0     a standard user's request is denied
                                            outright; no prompt is ever shown
          ValidateAdminCodeSignatures = 1   only executables with a validated
                                            signature may elevate
          EnableLUA = 0                     there is no consent prompt to answer

        A privilege-management broker is also named when one is running.
        Nothing it does appears in the registry at all: it can deny an elevation,
        or allow one application and refuse another, without leaving a value
        behind. Without this, a refusal on such a machine produced no note --
        which reads as "no policy is interfering" when one just did.

        Recognising brokers by service name means keeping a list of vendors, and
        that would be the wrong trade for a decision -- the next vendor would be
        missed and a capable machine turned away. It is the right trade for an
        explanation: a missing entry costs a sentence, and nothing is decided
        either way.

        Returns nothing when nothing restrictive is found, so a caller can append
        the result and say nothing extra on an ordinary machine.

        .EXAMPLE
        $note = Get-ElevationPolicyNote
        if ($note) { Write-Warning $note }
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $notes = [System.Collections.Generic.List[string]]::new()

    $policy = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'

    # One read, then look for the values on the object. Asking for a named value
    # that is absent throws, and Start-Transcript records the throw even when it
    # is caught -- which reads as a fault in a log where nothing went wrong.
    $values = Get-ItemProperty -LiteralPath $policy -ErrorAction SilentlyContinue

    if ($values) {
        $names = $values.PSObject.Properties.Name

        if ($names -contains 'EnableLUA' -and $values.EnableLUA -eq 0) {
            $notes.Add('UAC is switched off (EnableLUA is 0), so there is no consent prompt to answer.')
        }

        if ($names -contains 'ConsentPromptBehaviorUser' -and $values.ConsentPromptBehaviorUser -eq 0) {
            $notes.Add('Policy denies elevation requests from standard users outright (ConsentPromptBehaviorUser is 0), so a standard user is never prompted.')
        }

        if ($names -contains 'ValidateAdminCodeSignatures' -and $values.ValidateAdminCodeSignatures -eq 1) {
            $notes.Add('Policy allows only executables with a validated signature to elevate (ValidateAdminCodeSignatures is 1).')
        }
    }

    # Vendor-identifying names rather than a bare "privilege", which matches
    # unrelated services and would send someone to their IT department over
    # nothing.
    $brokerPatterns = @(
        '*defendpoint*', '*avecto*', '*beyondtrust*', '*privilege management*',
        '*adminbyrequest*', '*admin by request*', '*cyberark*',
        '*arellia*', '*thycotic*', '*delinea*'
    )

    $broker = $null
    try {
        $running = @(Get-Service -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Running' })
        foreach ($service in $running) {
            foreach ($pattern in $brokerPatterns) {
                if ($service.Name -like $pattern -or $service.DisplayName -like $pattern) {
                    $broker = $service.DisplayName
                    break
                }
            }
            if ($broker) { break }
        }
    } catch {
        Write-Verbose "Could not enumerate services to look for a privilege broker: $($_.Exception.Message)"
    }

    if ($broker) {
        $notes.Add("A privilege-management broker is running on this machine ($broker). Those grant or deny elevation per application and leave nothing in the registry, so it may have refused this one even though the policy values above look permissive.")
    }

    if ($notes.Count -eq 0) { return }

    'Policy on this machine may be the cause: ' + ($notes -join ' ')
}
