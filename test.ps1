#Requires -Version 5.1

<#
.SYNOPSIS
    Runs the test suite. Used unchanged locally and in CI.

.DESCRIPTION
    Keeping one runner means the pipeline executes exactly what you executed on
    your machine. The only behavioural difference is -CI, which turns on the
    non-zero exit code and the NUnit result file a build needs.

.PARAMETER Tag
    Run only tests carrying these tags. The suite uses 'Static', 'Docs' and
    'Lint'.

.PARAMETER ExcludeTag
    Skip tests carrying these tags, e.g. -ExcludeTag Lint to skip the analyzer
    pass when PSScriptAnalyzer is not installed.

.PARAMETER CI
    Exit with a non-zero code when tests fail, and write testResults.xml.
    Without this the script reports failures but still exits 0, which would let
    a pipeline go green over a red suite.

.EXAMPLE
    .\test.ps1

.EXAMPLE
    .\test.ps1 -Tag Static

.EXAMPLE
    .\test.ps1 -CI
#>

[CmdletBinding()]
param(
    [string[]] $Tag,
    [string[]] $ExcludeTag,
    [switch]   $CI
)

$ErrorActionPreference = 'Stop'

Import-Module Pester -MinimumVersion 6.0 -ErrorAction Stop

$config = New-PesterConfiguration
$config.Run.Path         = Join-Path $PSScriptRoot 'tests'
$config.Output.Verbosity = 'Detailed'

# Report every failed assertion in a test, not just the first. A lint failure
# listing all findings at once beats fixing them one run at a time.
$config.Should.ErrorAction = 'Continue'

if ($Tag)        { $config.Filter.Tag = $Tag }
if ($ExcludeTag) { $config.Filter.ExcludeTag = $ExcludeTag }

if ($CI) {
    # Invoke-Pester reports failures but returns normally by default, so without
    # this a pipeline reports success over a suite full of red.
    $config.Run.Exit            = $true
    $config.TestResult.Enabled  = $true
    $config.TestResult.OutputPath = Join-Path $PSScriptRoot 'testResults.xml'
}

# No CodeCoverage: measuring it means executing the code under test, and the
# code under test elevates, installs software and can reboot the machine.

Invoke-Pester -Configuration $config
