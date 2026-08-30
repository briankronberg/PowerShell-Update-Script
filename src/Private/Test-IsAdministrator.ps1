function Test-IsAdministrator {
    # Split out so callers read as intent rather than as a WindowsPrincipal cast.
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    ([Security.Principal.WindowsPrincipal] `
        [Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
