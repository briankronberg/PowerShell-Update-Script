function Resolve-WindowStyle {
    # A run that asks a question has to be visible to ask it. Hidden or
    # minimized would leave the prompt somewhere nobody looks, and the run would
    # then sit on its timeout before starting anyway -- all of the delay, none of
    # the choice. Prompting wins; the caller is told.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][ValidateSet('Normal', 'Minimized', 'Hidden')]
        [string] $Requested,

        [switch] $PromptBeforeRun
    )

    if ($PromptBeforeRun -and $Requested -ne 'Normal') {
        Write-Warning "-PromptBeforeRun needs a visible window, so -WindowStyle $Requested is being ignored and the task will run Normal."
        return 'Normal'
    }

    $Requested
}
