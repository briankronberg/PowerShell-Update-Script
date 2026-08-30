function Get-ToolInstallSource {
    <#
        .SYNOPSIS
        Reports which package manager, if any, owns an installed command.

        .DESCRIPTION
        A tool's own self-update is only the right mechanism when nothing else
        is managing it. Calling "uv self update" on a uv that scoop installed
        fights scoop, and the next scoop update undoes it.

        The answer comes from where the executable lives, which is the only
        signal available without interrogating every package manager on the
        machine. Returns:

          Scoop       under a scoop shims or apps directory
          WinGet      under WinGet's Links or Packages directory
          Python      under a Python Scripts directory, so pip or pipx put it there
          Chocolatey  under the chocolatey bin
          Standalone  under ~\.local\bin or ~\bin, where vendor install scripts put things
          Unknown     anywhere else, including Program Files

        Unknown is deliberately distinct from Standalone. A caller that only
        self-updates what it can positively identify as standalone will leave
        Unknown alone, which is the safe direction.

        .EXAMPLE
        Get-ToolInstallSource -Name uv
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string] $Name
    )

    $command = Get-Command $Name -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1

    if (-not $command) { return 'Absent' }

    $path = $command.Source

    if ($path -match '[\\/]scoop[\\/]')                       { return 'Scoop' }
    if ($path -match '[\\/]WinGet[\\/]')                      { return 'WinGet' }
    if ($path -match '[\\/]chocolatey[\\/]')                  { return 'Chocolatey' }
    if ($path -match '[\\/](Scripts|site-packages)[\\/]')     { return 'Python' }
    if ($path -match '[\\/]\.local[\\/]bin[\\/]')             { return 'Standalone' }
    if ($path -match [regex]::Escape("$env:USERPROFILE\bin\")) { return 'Standalone' }

    'Unknown'
}
