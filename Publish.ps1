#Requires -Version 5.1

<#
.SYNOPSIS
    Validates the module and publishes it to the PowerShell Gallery.

.DESCRIPTION
    Publish-Module requires the module folder to be named after the module, and
    this repository keeps its source in src, following BurntToast's layout. So
    the module is staged into a correctly named folder first, validated there,
    and published from the staging copy.

    Every check runs before anything is sent. -WhatIf runs the checks and stops,
    which is the way to see what would happen without an account.

    Publishing is close to permanent. The gallery has no delete, only unlist,
    which hides a version from search while leaving it installable by anyone who
    names it. Get the version right before running this without -WhatIf.

.PARAMETER ApiKey
    Your PowerShell Gallery API key, from
    https://www.powershellgallery.com/account/apikeys

    Prompted for if omitted, so it need not appear in shell history.

.PARAMETER Repository
    Registered repository to publish to. Default: PSGallery.

.EXAMPLE
    pwsh -NoProfile -ExecutionPolicy Bypass -File .\Publish.ps1 -WhatIf

    Runs every check and reports what would be published, sending nothing.

.EXAMPLE
    pwsh -NoProfile -ExecutionPolicy Bypass -File .\Publish.ps1

    Prompts for the API key, then publishes.
#>

[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [string] $ApiKey,

    [ValidateNotNullOrEmpty()]
    [string] $Repository = 'PSGallery'
)

$ErrorActionPreference = 'Stop'

$source = Join-Path $PSScriptRoot 'src'
$manifestPath = Join-Path $source 'UpdateEverything.psd1'

if (-not (Test-Path -LiteralPath $manifestPath)) {
    throw "Cannot find the module source at $source. Run this from a clone of the repository."
}

$manifest = Test-ModuleManifest -Path $manifestPath
$version = $manifest.Version

Write-Host "UpdateEverything $version" -ForegroundColor Cyan
Write-Host ''

# --- checks, all of them before anything is sent -----------------------------

$problems = [System.Collections.Generic.List[string]]::new()

foreach ($field in 'Author', 'Description', 'Guid') {
    if (-not $manifest.$field) { $problems.Add("The manifest has no $field.") }
}

$psdata = (Import-PowerShellDataFile -Path $manifestPath).PrivateData.PSData
foreach ($field in 'Tags', 'ProjectUri', 'LicenseUri', 'ReleaseNotes') {
    if (-not $psdata.$field) { $problems.Add("PrivateData.PSData has no $field. The gallery shows it, and its absence looks like neglect.") }
}

if (-not $manifest.ExportedFunctions.Count) {
    $problems.Add('The module exports no functions, so installing it would achieve nothing.')
}

# The gallery runs PSScriptAnalyzer and shows what it finds on the package page.
# Its default rules, not this repository's tuned ones.
if (Get-Module PSScriptAnalyzer -ListAvailable) {
    $findings = foreach ($file in Get-ChildItem $source -Recurse -Include *.ps1, *.psm1) {
        Invoke-ScriptAnalyzer -Path $file.FullName
    }
    if ($findings) {
        $problems.Add("PSScriptAnalyzer reports $(@($findings).Count) finding(s) under its default rules, which the gallery will display:")
        foreach ($f in $findings) {
            $problems.Add("    $(Split-Path $f.ScriptPath -Leaf):$($f.Line) $($f.RuleName)")
        }
    }
} else {
    Write-Warning 'PSScriptAnalyzer is not installed, so the checks the gallery runs were skipped.'
}

# A version already on the gallery cannot be replaced, only added to.
try {
    $published = Find-Module -Name $manifest.Name -Repository $Repository -ErrorAction Stop
    Write-Host "Already on $Repository at version $($published.Version)."
    if ([version] $published.Version -ge $version) {
        $problems.Add("Version $version is not newer than the published $($published.Version). Raise ModuleVersion in the manifest.")
    }
} catch {
    Write-Host "Not yet on $Repository, so this would be the first release."
}

if ($problems.Count) {
    Write-Host ''
    Write-Host 'Not ready to publish:' -ForegroundColor Yellow
    foreach ($p in $problems) { Write-Host "  $p" -ForegroundColor Yellow }
    throw "$($problems.Count) problem(s) to fix first."
}

Write-Host 'All checks passed.' -ForegroundColor Green

# --- stage into a folder named after the module ------------------------------

$staging = Join-Path ([System.IO.Path]::GetTempPath()) ('UpdateEverything-publish-' + [guid]::NewGuid().ToString('N'))
$moduleFolder = Join-Path $staging $manifest.Name
# -WhatIf:$false on the staging, because staging into a temp folder is how the
# checks below get something real to validate. Only the publish itself is gated.
# Without this, -WhatIf skipped the copy and then validated a folder that was
# never created.
$null = New-Item -ItemType Directory -Path $moduleFolder -Force -WhatIf:$false
Copy-Item -Path (Join-Path $source '*') -Destination $moduleFolder -Recurse -Force -WhatIf:$false

try {
    # Prove the staged copy is what will be published, not just what was copied.
    $staged = Test-ModuleManifest -Path (Join-Path $moduleFolder 'UpdateEverything.psd1')
    Write-Host ''
    Write-Host "Staged $($staged.Name) $($staged.Version)" -ForegroundColor Cyan
    Write-Host "  Location : $moduleFolder"
    Write-Host "  Files    : $(@(Get-ChildItem $moduleFolder -Recurse -File).Count)"
    Write-Host "  Exports  : $(($staged.ExportedFunctions.Keys) -join ', ')"

    if (-not $PSCmdlet.ShouldProcess("$($staged.Name) $($staged.Version)", "Publish to $Repository")) {
        Write-Host ''
        Write-Host 'Checks only. Nothing was published.' -ForegroundColor Green
        return
    }

    if (-not $ApiKey) {
        # Read-Host rather than a parameter default, so the key stays out of
        # shell history and out of any transcript of this session.
        $secure = Read-Host -Prompt 'PowerShell Gallery API key' -AsSecureString
        $ApiKey = [System.Net.NetworkCredential]::new('', $secure).Password
    }

    Publish-Module -Path $moduleFolder -NuGetApiKey $ApiKey -Repository $Repository -ErrorAction Stop

    Write-Host ''
    Write-Host "Published UpdateEverything $version to $Repository." -ForegroundColor Green
    Write-Host '  It can take a few minutes to appear in Find-Module.'
} finally {
    # -WhatIf:$false to match the staging above. A temp folder left behind on a
    # dry run would be litter, not caution.
    Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue -WhatIf:$false
}
