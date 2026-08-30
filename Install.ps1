#Requires -Version 5.1

<#
.SYNOPSIS
    Installs the UpdateEverything module, either from a clone or straight from
    GitHub.

.DESCRIPTION
    Downloads the repository and installs the module when run on its own, and
    installs from the clone it sits in when there is one. So both of these work:

        # from a clone
        pwsh -NoProfile -ExecutionPolicy Bypass -File .\Install.ps1

        # from nothing but the URL
        $installer = Join-Path $env:TEMP 'Install-UpdateEverything.ps1'
        Invoke-WebRequest https://raw.githubusercontent.com/briankronberg/PowerShell-Update-Script/main/Install.ps1 -OutFile $installer -UseBasicParsing
        Unblock-File $installer
        pwsh -NoProfile -ExecutionPolicy Bypass -File $installer

    Downloaded, then run, rather than piped through Invoke-Expression. The
    "irm ... | iex" idiom reads shorter but Defender blocks process creation on
    a command line containing it, whatever the command actually does, so it
    fails outright on a machine with attack surface reduction turned on.
    Unblock-File clears the mark of the web, which an execution policy of
    RemoteSigned would otherwise refuse.

    Installs for the current user by default, which needs no elevation, and for
    both PowerShell editions, because they read different module folders.

.PARAMETER FromGitHub
    Download the module from GitHub even when a local src folder is present.
    Use this to test what someone else installing it would get.

.PARAMETER Repository
    The owner/name to download from. Default:
    briankronberg/PowerShell-Update-Script.

.PARAMETER Ref
    Branch or tag to download. Default: main.

.PARAMETER Scope
    CurrentUser (default) installs into your own module path and needs no admin
    rights. AllUsers installs machine-wide and does.

.PARAMETER CurrentEditionOnly
    Install only for the edition running this script. By default it installs for
    both Windows PowerShell and PowerShell 7. Installing from pwsh alone would
    leave the module invisible to the edition the manifest promises to support.

.PARAMETER Force
    Overwrite an existing install of the same version.

.PARAMETER PassThru
    Return the installed module rather than only printing a summary.

.EXAMPLE
    pwsh -NoProfile -ExecutionPolicy Bypass -File .\Install.ps1 -FromGitHub

.EXAMPLE
    pwsh -NoProfile -ExecutionPolicy Bypass -File .\Install.ps1 -Scope AllUsers

.NOTES
    Uninstall by deleting the folder this reports.
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [switch] $FromGitHub,

    [ValidatePattern('^[\w.-]+/[\w.-]+$')]
    [string] $Repository = 'briankronberg/PowerShell-Update-Script',

    [ValidateNotNullOrEmpty()]
    [string] $Ref = 'main',

    [ValidateSet('CurrentUser', 'AllUsers')]
    [string] $Scope = 'CurrentUser',

    [switch] $CurrentEditionOnly,

    [switch] $Force,

    [switch] $PassThru
)

$ErrorActionPreference = 'Stop'

function Get-ModuleSourceFromGitHub {
    <#
        Downloads the repository as a zip and returns the path to its src folder.
        The caller is responsible for removing $WorkingDirectory afterwards.
    #>
    param(
        [Parameter(Mandatory)][string] $Repository,
        [Parameter(Mandatory)][string] $Ref,
        [Parameter(Mandatory)][string] $WorkingDirectory
    )

    $url = "https://github.com/$Repository/archive/refs/heads/$Ref.zip"
    $zip = Join-Path $WorkingDirectory 'repo.zip'

    Write-Host "Downloading $Repository ($Ref)..."
    try {
        # -UseBasicParsing because Windows PowerShell otherwise wants Internet
        # Explorer's engine, which is absent on a server core install and slow
        # everywhere else.
        Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing
    } catch {
        throw "Could not download $url. A private repository returns 404 to an anonymous request, so check the repository is public and the branch name is right. $($_.Exception.Message)"
    }

    Expand-Archive -Path $zip -DestinationPath $WorkingDirectory -Force

    # GitHub names the extracted folder <repo>-<ref>, so find it rather than
    # guessing at the ref's spelling.
    $candidates = @(Get-ChildItem -Path $WorkingDirectory -Directory |
        ForEach-Object { Join-Path $_.FullName 'src' } |
        Where-Object { Test-Path -LiteralPath (Join-Path $_ 'UpdateEverything.psd1') })

    if (-not $candidates.Count) {
        throw "The download from $Repository ($Ref) contains no src\UpdateEverything.psd1."
    }

    $candidates[0]
}

$workingDirectory = $null

# $PSScriptRoot is empty when this is piped into Invoke-Expression rather than
# run from a file, which is how the one-line install works. Join-Path would
# throw on the empty path, so there is nothing local to look at in that case.
$source = if ($PSScriptRoot) { Join-Path $PSScriptRoot 'src' } else { $null }

# Run on its own, with no clone around it, this fetches the module rather than
# failing. That is what makes the one-line install work.
if ($FromGitHub -or -not $source -or -not (Test-Path -LiteralPath (Join-Path $source 'UpdateEverything.psd1'))) {
    $workingDirectory = Join-Path ([System.IO.Path]::GetTempPath()) ('UpdateEverything-' + [guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $workingDirectory
    $source = Get-ModuleSourceFromGitHub -Repository $Repository -Ref $Ref -WorkingDirectory $workingDirectory
}

try {
    $manifestPath = Join-Path $source 'UpdateEverything.psd1'
    $version = (Import-PowerShellDataFile -Path $manifestPath).ModuleVersion

    # Ask Windows for Documents rather than assuming %USERPROFILE%\Documents.
    # OneDrive redirects it on plenty of machines, and a module written to the
    # wrong folder is simply never found.
    $documents = [Environment]::GetFolderPath('MyDocuments')

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

        # Staged, then swapped. Deleting the destination first leaves a window
        # where the module simply is not there, and anything importing it during
        # that window fails with "no valid module file was found". A scheduled
        # task starting seconds after an install hit exactly that.
        $staging = "$destination.installing"
        if (Test-Path -LiteralPath $staging) { Remove-Item -LiteralPath $staging -Recurse -Force }

        $null = New-Item -ItemType Directory -Path $staging -Force
        Copy-Item -Path (Join-Path $source '*') -Destination $staging -Recurse -Force

        # Prove the copy is loadable before it replaces a working install.
        $null = Import-PowerShellDataFile -Path (Join-Path $staging 'UpdateEverything.psd1')

        if (Test-Path -LiteralPath $destination) { Remove-Item -LiteralPath $destination -Recurse -Force }
        Move-Item -LiteralPath $staging -Destination $destination
    }

    # Import by path so this reports on the copy just written, not on some other
    # version that happens to sit earlier in the module path.
    $installed = Import-Module (Join-Path $destinations[0] 'UpdateEverything.psd1') -Force -PassThru

    Write-Host ''
    Write-Host "Installed UpdateEverything $version" -ForegroundColor Green
    if ($workingDirectory) { Write-Host "  Source   : $Repository ($Ref)" }
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
} finally {
    if ($workingDirectory -and (Test-Path -LiteralPath $workingDirectory)) {
        Remove-Item -LiteralPath $workingDirectory -Recurse -Force -ErrorAction SilentlyContinue
    }
}
