function Convert-PowerShell7ToMsi {
    <#
        .SYNOPSIS
        Moves this machine's PowerShell 7 from the Store (MSIX) package to the
        MSI install, by running the migration script the module ships.

        .DESCRIPTION
        The work lives in Convert-PowerShell7ToMsi.ps1 beside the module
        manifest: a standalone script designed to run under Windows PowerShell
        5.1, because a packaged pwsh can neither elevate nor remove the package
        hosting it. This function is only the launcher -- it starts the script
        under powershell.exe from whichever session called it and passes the
        switches through. The script prints its plan, asks once before changing
        anything, and elevates itself when the run needs it.

        .PARAMETER ReportOnly
        Discover and report, change nothing.

        .PARAMETER Force
        Skip the script's confirmation question. The plan still prints.

        .PARAMETER SkipTerminalDefault
        Leave Windows Terminal's settings.json untouched whatever the default
        profile points at.

        .EXAMPLE
        Convert-PowerShell7ToMsi -ReportOnly

        .EXAMPLE
        Convert-PowerShell7ToMsi
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [switch] $ReportOnly,
        [switch] $Force,
        [switch] $SkipTerminalDefault
    )

    $mover = Join-Path $script:ModuleRoot 'Convert-PowerShell7ToMsi.ps1'
    if (-not (Test-Path -LiteralPath $mover)) {
        throw "The migration script is not at $mover. Reinstall the module, or fetch the script from the repository README."
    }

    $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $mover)
    if ($ReportOnly)          { $arguments += '-ReportOnly' }
    if ($Force)               { $arguments += '-Force' }
    if ($SkipTerminalDefault) { $arguments += '-SkipTerminalDefault' }

    & powershell.exe @arguments
    if ($LASTEXITCODE -ne 0) {
        Write-Error "The migration script exited with code $LASTEXITCODE."
        $global:LASTEXITCODE = 0
    }
}
