function Test-CanPrompt {
    # Whether this session can actually ask a question and get an answer.
    #
    # UserInteractive alone is not enough, and believing it causes a hang:
    # a run whose stdin is a pipe or a file reports UserInteractive $true, but
    # PromptForChoice then blocks forever waiting on input that never arrives.
    # Piping the script through tee, or running it from a build agent, is enough
    # to hit this. Both conditions have to hold.
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    [Environment]::UserInteractive -and -not [Console]::IsInputRedirected
}
