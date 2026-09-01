#Requires -Version 5.1

<#
    .SYNOPSIS
    Runs Update-Everything unelevated and records what the handoff did.

    .DESCRIPTION
    Records facts and judges nothing. Invoke-ElevationTest.ps1 reads the JSON and
    decides what passed, so that the two halves can be read separately and this
    one can be run by hand when something needs looking at.

    The one thing it must be is unelevated. Update-Everything only reaches
    Invoke-SelfElevation when the session is not already an administrator, which
    is why every test of that path on a development machine has been vacuous.

    Transcripts are identified by taking the directory listing before and after
    rather than by predicting names. The elevated child computes its own run
    stamp in its own process, and the environment does not reliably cross a
    ShellExecute elevation boundary, so anything this process assumes about the
    child's paths would be a guess.

    .PARAMETER ResultPath
    Where to write the JSON.

    .EXAMPLE
    Invoke-ElevatedHandoff.ps1 -ResultPath C:\out\handoff.json
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $ResultPath
)

$ErrorActionPreference = 'Stop'

$record = [ordered]@{
    Started            = (Get-Date).ToString('o')
    User               = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    Elevated           = $null
    Host               = $PSVersionTable.PSVersion.ToString()
    LogDirectory       = $null
    TranscriptsBefore  = @()
    TranscriptsAfter   = @()
    Ran                = $null
    ResultElevated     = $null
    Reason             = $null
    FailedCount        = $null
    Error              = $null
    Finished           = $null
}

try {
    $record.Elevated = ([Security.Principal.WindowsPrincipal] `
        [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
            [Security.Principal.WindowsBuiltInRole]::Administrator)

    Import-Module UpdateEverything -Force -ErrorAction Stop

    # The same directory the module will choose, worked out the same way it does.
    $logDir = Join-Path $env:USERPROFILE 'UpdateLogs'
    $record.LogDirectory = $logDir

    if (Test-Path -LiteralPath $logDir) {
        $record.TranscriptsBefore = @(Get-ChildItem -LiteralPath $logDir -Filter 'Update-Everything-*.log' -File |
            ForEach-Object { $_.Name })
    }

    # -Tag Inventory keeps the elevated child's work to seconds. Elevation is
    # decided before any step runs, so the selection does not change whether the
    # handoff happens -- only how long the child takes once it has.
    #
    # -LogRetentionDays 0 so the pruning cannot remove a transcript this test is
    # about to count.
    $result = Update-Everything -Tag Inventory -LogRetentionDays 0

    $record.Ran            = $result.Ran
    $record.ResultElevated = $result.Elevated
    $record.Reason         = $result.Reason
    $record.FailedCount    = $result.FailedCount

    if (Test-Path -LiteralPath $logDir) {
        $record.TranscriptsAfter = @(Get-ChildItem -LiteralPath $logDir -Filter 'Update-Everything-*.log' -File |
            ForEach-Object { $_.Name })
    }
} catch {
    $record.Error = $_.Exception.Message
} finally {
    $record.Finished = (Get-Date).ToString('o')

    $parent = Split-Path $ResultPath -Parent
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        $null = New-Item -ItemType Directory -Path $parent -Force
    }

    [System.IO.File]::WriteAllText(
        $ResultPath,
        ([pscustomobject] $record | ConvertTo-Json -Depth 5),
        [System.Text.UTF8Encoding]::new($false))
}
