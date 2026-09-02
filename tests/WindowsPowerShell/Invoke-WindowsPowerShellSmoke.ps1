#Requires -Version 5.1

<#
    .SYNOPSIS
    Imports the module under Windows PowerShell 5.1 and runs the read-only
    inventory pass end to end.

    .DESCRIPTION
    The Pester suite runs under PowerShell 7, because Pester 6 requires it. Two
    of its tests shell out to powershell.exe -- one imports the module, one
    writes a step log -- which catches parse errors and the encoding split, but
    nothing executes the run path under 5.1: the step runner, the transcript,
    the inventory formatting, and PowerShellGet 1.0.0.1 answering the
    self-version lookup.

    This does. It runs the one tag that changes nothing on the machine, then
    checks the result object. CI runs it as its own job under shell:
    powershell; locally:

        powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\WindowsPowerShell\Invoke-WindowsPowerShellSmoke.ps1

    .OUTPUTS
    Progress lines. Exits 1 on the first failed check, so a pipeline fails.
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

try {
    # Running this under 7 would pass while proving nothing about 5.1.
    if ($PSVersionTable.PSEdition -ne 'Desktop') {
        throw ("This smoke test exists to exercise Windows PowerShell and is running under " +
            "$($PSVersionTable.PSVersion) ($($PSVersionTable.PSEdition)). Run it with powershell.exe.")
    }

    $repoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    $manifest = Join-Path $repoRoot 'src\UpdateEverything.psd1'

    Import-Module $manifest -Force -ErrorAction Stop
    Write-Output "Imported under Windows PowerShell $($PSVersionTable.PSVersion)."

    $missing = @(
        (Import-PowerShellDataFile $manifest).FunctionsToExport |
            Where-Object { -not (Get-Command $_ -Module UpdateEverything -ErrorAction SilentlyContinue) })
    if ($missing.Count) {
        throw "Exported commands that do not resolve under 5.1: $($missing -join ', ')"
    }
    Write-Output 'Every command the manifest exports resolves.'

    $result = Update-Everything -Tag Inventory -SkipElevation -LogRetentionDays 0 6>$null

    $problems = @(
        if (-not $result) { 'no result object came back' }
        elseif (-not $result.Ran) { "the run did not start: $($result.Reason)" }
        else {
            if ($result.FailedCount -ne 0) { "FailedCount=$($result.FailedCount)" }
            if (@($result.Steps).Count -lt 25) { "only $(@($result.Steps).Count) step records came back" }
            if (@($result.Steps | Where-Object { $_.Step -eq 'Inventory' -and $_.Status -eq 'OK' }).Count -ne 1) {
                'the Inventory step did not report OK'
            }
        })
    if ($problems.Count) {
        throw ('The inventory pass failed under 5.1: ' + ($problems -join '; '))
    }

    Write-Output "Inventory pass OK under 5.1: $(@($result.Steps).Count) steps, 0 failed."
} catch {
    # An explicit exit code, because what an uncaught throw returns under -File
    # has differed between hosts.
    Write-Error -ErrorAction Continue -Message "$_"
    exit 1
}
