#Requires -Version 5.1

<#
.SYNOPSIS
    Installs the UpdateEverything module from this clone onto the current
    machine.

.DESCRIPTION
    Copies src\ into your PowerShell module path so that Import-Module
    UpdateEverything works from any session, then reports what it exported.

    This is for installing from a clone. Once the module is on the PowerShell
    Gallery, Install-Module UpdateEverything is the shorter route and handles
    updates for you.

    Installs for the current user by default, which needs no elevation.

.PARAMETER Scope
    CurrentUser (default) installs into your own module path and needs no
    admin rights. AllUsers installs machine-wide and does.

.PARAMETER CurrentEditionOnly
    Install only for the edition running this script. By default it installs for
    both Windows PowerShell and PowerShell 7, because the module supports 5.1
    and the two editions read different module folders. Installing from pwsh
    alone would leave the module invisible to Windows PowerShell, which is a
    confusing way to find out they are separate.

.PARAMETER Force
    Overwrite an existing install of the same version.

.PARAMETER PassThru
    Return the installed module rather than only printing a summary.

.EXAMPLE
    pwsh -NoProfile -ExecutionPolicy Bypass -File .\Install.ps1

.EXAMPLE
    pwsh -NoProfile -ExecutionPolicy Bypass -File .\Install.ps1 -Scope AllUsers

.NOTES
    Uninstall by deleting the folder this reports, or with
    Uninstall-Module UpdateEverything if it came from the gallery.
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidateSet('CurrentUser', 'AllUsers')]
    [string] $Scope = 'CurrentUser',

    [switch] $CurrentEditionOnly,

    [switch] $Force,

    [switch] $PassThru
)

$ErrorActionPreference = 'Stop'

$source = Join-Path $PSScriptRoot 'src'
$manifestPath = Join-Path $source 'UpdateEverything.psd1'

if (-not (Test-Path -LiteralPath $manifestPath)) {
    throw "Cannot find the module source at $source. Run this from a clone of the repository."
}

$manifest = Import-PowerShellDataFile -Path $manifestPath
$version = $manifest.ModuleVersion

# Ask Windows for Documents rather than assuming %USERPROFILE%\Documents.
# OneDrive redirects it on plenty of machines, and a module written to the
# wrong folder is simply never found.
$documents = [Environment]::GetFolderPath('MyDocuments')

# The two editions read different folders, so a module that supports both is
# installed to both unless told otherwise.
$editions = if ($CurrentEditionOnly) {
    if ($PSVersionTable.PSEdition -eq 'Core') { 'PowerShell' } else { 'WindowsPowerShell' }
} else {
    'PowerShell', 'WindowsPowerShell'
}

$roots = foreach ($edition in $editions) {
    if ($Scope -eq 'AllUsers') {
        Join-Path $env:ProgramFiles "$edition\Modules"
    } else {
        Join-Path $documents "$edition\Modules"
    }
}

if ($Scope -eq 'AllUsers') {
    $isAdmin = ([Security.Principal.WindowsPrincipal] `
        [Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

    if (-not $isAdmin) {
        throw 'Installing for AllUsers needs an elevated session. Start PowerShell as Administrator, or install for CurrentUser instead.'
    }
}

$destinations = foreach ($root in $roots) {
    Join-Path (Join-Path $root 'UpdateEverything') $version
}

$existing = @($destinations | Where-Object { Test-Path -LiteralPath $_ })
if ($existing -and -not $Force) {
    throw "UpdateEverything $version is already installed at $($existing -join ', '). Use -Force to overwrite it."
}

foreach ($destination in $destinations) {
    if (-not $PSCmdlet.ShouldProcess($destination, "Install UpdateEverything $version")) { continue }

    if (Test-Path -LiteralPath $destination) {
        Remove-Item -LiteralPath $destination -Recurse -Force
    }

    $null = New-Item -ItemType Directory -Path $destination -Force
    Copy-Item -Path (Join-Path $source '*') -Destination $destination -Recurse -Force
}

# Import by path so this reports on the copy just written, not on some other
# version that happens to sit earlier in the module path.
$installed = Import-Module (Join-Path $destinations[0] 'UpdateEverything.psd1') -Force -PassThru

Write-Host ''
Write-Host "Installed UpdateEverything $version" -ForegroundColor Green
foreach ($destination in $destinations) {
    Write-Host "  Location : $destination"
}
Write-Host "  Scope    : $Scope"
Write-Host "  Commands : $((Get-Command -Module UpdateEverything -CommandType Function).Name -join ', ')"
Write-Host ''
Write-Host '  Try it without changing anything:'
Write-Host '    Get-Help Update-Everything -Full'
Write-Host ''
Write-Host '  A cautious first run:'
Write-Host '    Update-Everything -IncludeWindowsUpdate $false -IncludePowerShell7 $false -SetPwshTerminalDefault $false'

if ($PassThru) { $installed }
