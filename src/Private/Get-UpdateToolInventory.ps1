function Get-UpdateToolInventory {
    <#
        .SYNOPSIS
        Reports what this machine has of the tools Update-Everything drives.

        .DESCRIPTION
        One record per tool, with Name, Command, Present, Version, Owner and
        Copies.

        Every step already resolves its own tool and skips when it is absent, so
        this changes no behaviour. What it adds is a picture: on a first run the
        summary is a long column of skips, and nothing says whether that is a
        machine with little installed or a run that went wrong.

        Owner comes from Get-ToolInstallSource and answers who is responsible for
        updating a tool. Copies counts the distinct directories an executable of
        that name resolves from; more than one is worth knowing, because the
        version reported here is the one that runs and the others are updated by
        nobody.

        Directories rather than files, because PATHEXT resolves npm.cmd and npm
        from the same folder as two commands. That is one install, and reporting
        it as two would train people to ignore the warning.

        A tool that fails or hangs on its version argument reports Present with a
        null Version rather than failing the inventory. Knowing something is there
        is most of the value.

        .PARAMETER Catalogue
        The tools to look for. Defaults to the ones this module drives; a test
        passes its own.

        .EXAMPLE
        Get-UpdateToolInventory | Where-Object Present
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [object[]] $Catalogue
    )

    if (-not $Catalogue) {
        # Name is what a person calls it; Command is what resolves on PATH.
        $Catalogue = @(
            @{ Name = 'winget';          Command = 'winget';  VersionArgument = '--version' }
            @{ Name = 'Chocolatey';      Command = 'choco';   VersionArgument = '--version' }
            @{ Name = 'Scoop';           Command = 'scoop';   VersionArgument = $null }
            @{ Name = 'PowerShell 7';    Command = 'pwsh';    VersionArgument = '--version' }
            @{ Name = 'Node.js';         Command = 'node';    VersionArgument = '--version' }
            @{ Name = 'npm';             Command = 'npm';     VersionArgument = '--version' }
            @{ Name = 'Deno';            Command = 'deno';    VersionArgument = '--version' }
            @{ Name = 'Bun';             Command = 'bun';     VersionArgument = '--version' }
            @{ Name = 'pnpm';            Command = 'pnpm';    VersionArgument = '--version' }
            @{ Name = 'Python launcher'; Command = 'py';      VersionArgument = '--version' }
            @{ Name = 'Python manager';  Command = 'pymanager'; VersionArgument = '--version' }
            @{ Name = 'uv';              Command = 'uv';      VersionArgument = '--version' }
            @{ Name = 'pip';             Command = 'pip';     VersionArgument = '--version' }
            @{ Name = 'pipx';            Command = 'pipx';    VersionArgument = '--version' }
            @{ Name = 'conda';           Command = 'conda';   VersionArgument = '--version' }
            @{ Name = '.NET SDK';        Command = 'dotnet';  VersionArgument = '--version' }
            @{ Name = 'rustup';          Command = 'rustup';  VersionArgument = '--version' }
            @{ Name = 'cargo-update';    Command = 'cargo-install-update'; VersionArgument = '--version' }
            @{ Name = 'Go';              Command = 'go';      VersionArgument = 'version' }
            @{ Name = 'gup';             Command = 'gup';     VersionArgument = 'version' }
            @{ Name = 'GitHub CLI';      Command = 'gh';      VersionArgument = '--version' }
            @{ Name = 'Azure CLI';       Command = 'az';      VersionArgument = $null }
            @{ Name = 'Google Cloud CLI'; Command = 'gcloud'; VersionArgument = $null }
            @{ Name = 'VS Code';         Command = 'code';    VersionArgument = $null }
            @{ Name = 'MiKTeX';          Command = 'miktex';  VersionArgument = '--version' }
            @{ Name = 'WSL';             Command = 'wsl';     VersionArgument = $null }
        )
    }

    foreach ($tool in $Catalogue) {
        $resolved = @(Get-Command $tool.Command -CommandType Application -ErrorAction SilentlyContinue)
        # First-occurrence order is PATH-resolution order, so the first entry is
        # the copy that actually runs. Dedupe case-insensitively: a Windows PATH
        # routinely carries the same directory in different casing across its
        # machine and user segments, and Select-Object -Unique is case-sensitive.
        $seen = [System.Collections.Generic.HashSet[string]]::new(
            [System.StringComparer]::OrdinalIgnoreCase)
        $places = @($resolved |
            ForEach-Object { Split-Path $_.Source -Parent } |
            Where-Object { $_ -and $seen.Add($_) })

        if (-not $resolved.Count) {
            [pscustomobject]@{
                Name    = $tool.Name
                Command = $tool.Command
                Present = $false
                Version = $null
                Owner   = $null
                Copies  = 0
                Places  = @()
            }
            continue
        }

        # The null version arguments are on purpose. scoop is a PowerShell shim
        # whose --version runs a git describe against its own repository; wsl
        # --version writes UTF-16 that arrives as spaced-out characters; az,
        # gcloud and code each take seconds to answer. Presence is most of the
        # value, and none of these are worth the wait or the mess.
        $version = $null
        if ($tool.VersionArgument) {
            try {
                $raw = & $tool.Command $tool.VersionArgument 2>&1
                $global:LASTEXITCODE = 0
                $version = @($raw | Out-String -Stream |
                    Where-Object { $_ -and $_.Trim() } |
                    ForEach-Object { $_.Trim() })[0]
            } catch {
                Write-Verbose "$($tool.Command) $($tool.VersionArgument) failed: $($_.Exception.Message)"
                $global:LASTEXITCODE = 0
            }
        }

        [pscustomobject]@{
            Name    = $tool.Name
            Command = $tool.Command
            Present = $true
            Version = $version
            Owner   = Get-ToolInstallSource -Name $tool.Command
            Copies  = $places.Count
            Places  = $places
        }
    }
}
