#Requires -Version 5.1

<#
    .SYNOPSIS
    Downloads a published UpdateEverything from the PowerShell Gallery and runs
    it, so the artifact people install is the artifact that was checked.

    .DESCRIPTION
    Everything else in this repository tests the working tree or the GitHub
    install; nothing exercises the .nupkg the gallery serves. This does:
    Save-Module, import by path, prove the loaded module is the downloaded copy,
    and run the read-only Inventory pass.

    The identity check is the point of the harness. In a fresh session a bare
    Update-Everything auto-loads whichever copy PSModulePath finds, so a
    validation that skips the check can run a stale installed version end to
    end and report it green.

    Read-only by default. -IncludeSelfUpdate adds a live -UpdateSelf pass,
    which updates the host's installed UpdateEverything when one is present
    and behind -- that is the behaviour under test, so it is opt-in.

    .PARAMETER Version
    The gallery version to validate. Default: the newest published.

    .PARAMETER IncludeSelfUpdate
    Also run Update-Everything -UpdateSelf and assert it runs the self step
    alone. May update the host's installed copy.

    .EXAMPLE
    .\tests\Gallery\Invoke-GalleryValidation.ps1

    .EXAMPLE
    .\tests\Gallery\Invoke-GalleryValidation.ps1 -Version 1.4.0 -IncludeSelfUpdate
#>
[CmdletBinding()]
param(
    [string] $Version,
    [switch] $IncludeSelfUpdate
)

$ErrorActionPreference = 'Stop'

$script:Checks = [System.Collections.Generic.List[object]]::new()

function Add-Check {
    param(
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] [bool]   $Passed,
        [string] $Detail = ''
    )
    $status = if ($Passed) { 'PASS' } else { 'FAIL' }
    $colour = if ($Passed) { 'Green' } else { 'Red' }
    Write-Host ("  [{0}] {1}" -f $status, $Name) -ForegroundColor $colour
    if ($Detail) { Write-Host ("         {0}" -f $Detail) -ForegroundColor DarkGray }
    $script:Checks.Add([pscustomobject]@{ Name = $Name; Passed = $Passed; Detail = $Detail })
}

if (-not $Version) {
    $Version = (Find-Module -Name UpdateEverything -Repository PSGallery).Version.ToString()
}
Write-Host "Validating UpdateEverything $Version from the PowerShell Gallery." -ForegroundColor Cyan

$stage = Join-Path ([System.IO.Path]::GetTempPath()) ('UE-GalleryValidation-{0:yyyyMMdd-HHmmss}' -f (Get-Date))
$null = New-Item -ItemType Directory -Path $stage -Force

try {
    Save-Module -Name UpdateEverything -RequiredVersion $Version -Path $stage -Repository PSGallery

    $manifestPath = Join-Path $stage "UpdateEverything\$Version\UpdateEverything.psd1"
    Add-Check 'the gallery served the requested version' (Test-Path -LiteralPath $manifestPath) $manifestPath

    $manifest = Test-ModuleManifest -Path $manifestPath
    Add-Check 'the manifest validates' ($null -ne $manifest) "version $($manifest.Version)"
    Add-Check 'the manifest carries the six exports' ($manifest.ExportedFunctions.Count -eq 6) `
        "$($manifest.ExportedFunctions.Count) exported"

    Get-Module -Name UpdateEverything | Remove-Module -Force -ErrorAction SilentlyContinue
    Import-Module $manifestPath -Force

    # A bare command in a fresh session auto-loads whichever copy PSModulePath
    # resolves, so every later assertion is meaningless unless the loaded module
    # is provably the downloaded one.
    $loaded = Get-Module -Name UpdateEverything
    Add-Check 'the loaded module is the downloaded copy' ($loaded.ModuleBase -like "$stage*") $loaded.ModuleBase
    Add-Check 'the loaded version is the requested version' ($loaded.Version.ToString() -eq $Version) `
        "loaded $($loaded.Version)"

    # Inventory reads the machine and changes nothing. Merging stream 6 puts the
    # banner lines and the result object in one pipeline; the type separates them.
    $mixed = @(Update-Everything -Tag Inventory -LogRetentionDays 0 6>&1)
    $banner = @($mixed | Where-Object { $_ -is [System.Management.Automation.InformationRecord] } |
        ForEach-Object { "$_" })
    $run = $mixed | Where-Object { $_ -isnot [System.Management.Automation.InformationRecord] } |
        Select-Object -Last 1

    Add-Check 'the run reports the version it is' ([bool]($banner -match [regex]::Escape("UpdateEverything $Version"))) ''
    Add-Check 'the run ran' ($run.Ran -eq $true) "Ran=$($run.Ran)"
    Add-Check 'the Inventory step succeeded' (
        @($run.Steps | Where-Object { $_.Step -eq 'Inventory' -and $_.Status -eq 'OK' }).Count -eq 1) ''
    Add-Check 'every other step reported Skipped' (
        @($run.Steps | Where-Object { $_.Step -ne 'Inventory' -and $_.Status -ne 'Skipped' }).Count -eq 0) ''
    Add-Check 'FailedCount came back as zero' ($run.FailedCount -is [int] -and $run.FailedCount -eq 0) `
        "FailedCount=$($run.FailedCount)"

    if ($IncludeSelfUpdate) {
        $self = Update-Everything -UpdateSelf -LogRetentionDays 0 6>$null
        $ok = @($self.Steps | Where-Object { $_.Status -eq 'OK' })

        Add-Check 'with -UpdateSelf, the self step is the only one that runs' (
            $ok.Count -eq 1 -and $ok[0].Step -eq 'UpdateEverything (self)') `
            (($ok.Step) -join ', ')
        Add-Check 'the -UpdateSelf run failed nothing' ($self.FailedCount -eq 0) "FailedCount=$($self.FailedCount)"
    }
} finally {
    Get-Module -Name UpdateEverything | Remove-Module -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
}

$failed = @($script:Checks | Where-Object { -not $_.Passed })
Write-Host ''
if ($failed.Count) {
    Write-Host "Gallery validation FAILED: $($failed.Count) of $($script:Checks.Count) checks." -ForegroundColor Red
} else {
    Write-Host "Gallery validation passed: $($script:Checks.Count) checks." -ForegroundColor Green
}

[pscustomobject]@{
    Passed  = ($failed.Count -eq 0)
    Version = $Version
    Checks  = $script:Checks
}
