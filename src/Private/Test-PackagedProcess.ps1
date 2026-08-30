function Test-PackagedProcess {
    <#
        .SYNOPSIS
        Whether an executable is MSIX-packaged, which Windows will not run
        elevated.

        .DESCRIPTION
        winget has defaulted Microsoft.PowerShell to the MSIX installer since
        7.6, so a machine can have a perfectly current pwsh that cannot
        self-elevate at all. Two paths reach it and neither survives the RunAs
        verb:

          - the package binary under %ProgramFiles%\WindowsApps\Microsoft.PowerShell_<version>_...
          - the app execution alias in %LOCALAPPDATA%\Microsoft\WindowsApps,
            which is a zero-byte reparse point rather than a program

        The package path also carries the version, so it stops existing at the
        next PowerShell update. That makes it the wrong thing to bake into a
        scheduled task as well, which is why Get-PowerShellHostPath asks too.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        # Defaults to the current host. Passed explicitly when testing a
        # candidate that is not this process.
        [AllowNull()]
        [AllowEmptyString()]
        [string] $Path = (Get-Process -Id $PID).Path
    )

    if (-not $Path) { return $false }

    # Compared as path segments, not as a substring: a folder merely named
    # "WindowsApps" somewhere else on disk is not a packaged install.
    foreach ($root in @("$env:ProgramFiles\WindowsApps", "$env:LOCALAPPDATA\Microsoft\WindowsApps")) {
        if (-not $root) { continue }
        if ($Path -like (Join-Path $root '*')) { return $true }
    }

    $false
}
