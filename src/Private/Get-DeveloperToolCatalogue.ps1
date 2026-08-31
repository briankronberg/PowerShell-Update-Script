function Get-DeveloperToolCatalogue {
    <#
        .SYNOPSIS
        The developer tools the setup menu can install, with their winget IDs.

        .DESCRIPTION
        This module updates; it does not install. The catalogue is the one
        deliberate exception, and it is reachable only from the setup menu, where
        a person picks from a list. It is not an -AllowInstall component, so no
        unattended run can reach it and -AllowInstall All does not widen a
        maintenance job into a provisioning one.

        Every Id here was checked against "winget show --id <id> --exact" rather
        than written from memory. A wrong Id fails at install time on somebody
        else's machine.

        Command is what the tool puts on PATH, so the menu can say what is
        already present instead of offering to install it again.

        .EXAMPLE
        Get-DeveloperToolCatalogue | Format-Table Name, Id
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()

    # PowerShell 7 carries an installer type for the same reason the update step
    # does: winget has defaulted Microsoft.PowerShell to MSIX since 7.6, and
    # Windows will not run an MSIX process elevated.
    $catalogue = @(
        @{ Name = 'Git';              Id = 'Git.Git';                    Command = 'git';     Description = 'Version control' }
        @{ Name = 'Python';           Id = 'Python.PythonInstallManager'; Command = 'py';     Description = 'Python, through the Install Manager this module updates' }
        @{ Name = 'Node.js LTS';      Id = 'OpenJS.NodeJS.LTS';          Command = 'node';    Description = 'JavaScript runtime, with npm' }
        @{ Name = 'VS Code';          Id = 'Microsoft.VisualStudioCode'; Command = 'code';    Description = 'Editor' }
        @{ Name = 'Windows Terminal'; Id = 'Microsoft.WindowsTerminal';  Command = 'wt';      Description = 'Terminal this module can set a default profile on' }
        @{ Name = 'PowerShell 7';     Id = 'Microsoft.PowerShell';       Command = 'pwsh';    Description = 'PowerShell 7, MSI build so it can elevate'; InstallerType = 'wix' }
        @{ Name = 'GitHub CLI';       Id = 'GitHub.cli';                 Command = 'gh';      Description = 'gh, for repositories and pull requests' }
        @{ Name = 'uv';               Id = 'astral-sh.uv';               Command = 'uv';      Description = 'Python package and project manager' }
        @{ Name = 'Rust';             Id = 'Rustlang.Rustup';            Command = 'rustup';  Description = 'Rust toolchain installer' }
        @{ Name = '.NET SDK';         Id = 'Microsoft.DotNet.SDK.9';     Command = 'dotnet';  Description = 'dotnet build, test and global tools' }
        @{ Name = '7-Zip';            Id = '7zip.7zip';                  Command = '7z';      Description = 'Archives' }
        @{ Name = 'Docker Desktop';   Id = 'Docker.DockerDesktop';       Command = 'docker';  Description = 'Containers' }
    )

    foreach ($entry in $catalogue) {
        [pscustomobject]@{
            Name          = $entry.Name
            Id            = $entry.Id
            Command       = $entry.Command
            Description   = $entry.Description
            InstallerType = $entry.InstallerType
            Present       = [bool] (Get-Command $entry.Command -CommandType Application -ErrorAction SilentlyContinue)
        }
    }
}
