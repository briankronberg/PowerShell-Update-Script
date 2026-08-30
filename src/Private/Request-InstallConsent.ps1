function Request-InstallConsent {
    # Asks the operator, once, whether a component may be installed. Split out so
    # the decision logic around it can be tested without a console to type into.
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string] $Component,
        [Parameter(Mandatory)][string] $Description
    )

    $choices = [System.Management.Automation.Host.ChoiceDescription[]] @(
        [System.Management.Automation.Host.ChoiceDescription]::new('&Yes', "Install $Component now.")
        [System.Management.Automation.Host.ChoiceDescription]::new('&No', "Skip the step that needs $Component.")
    )

    try {
        # Default is No. Someone hitting Enter to get through a prompt they did
        # not expect should not thereby install software.
        $answer = $Host.UI.PromptForChoice(
            # Braces required: "$Component?" parses the ? as part of the
            # variable name, so the caption would read "Install " with no name.
            "Install ${Component}?",
            "$Description`n`nThis is a first-time install, not an update.",
            $choices,
            1)
        return ($answer -eq 0)
    } catch {
        # A host with no interactive UI (-NonInteractive, a service) throws here
        # rather than returning a default.
        Write-Warning "Could not prompt for consent to install $Component ($($_.Exception.Message)); treating it as declined."
        return $false
    }
}
