#Requires -Version 5.1

<#
    .SYNOPSIS
    Runs Update-Everything without administrator rights, inside the sandbox.

    .DESCRIPTION
    This is the payload the whole smoke test exists to execute. It must run
    unelevated, because self-elevation is the code under test: when the session
    is already an administrator that path is never reached, which is exactly why
    a parse error in the relaunch command survived development and shipped.

    The harness starts it through a scheduled task at RunLevel Limited, which is
    how an elevated session gets a genuinely unelevated child of the same user.

    Windows Update is turned off. It is the one step that can run for hours, and
    it proves nothing here -- the question is whether the elevated relaunch
    happens at all, not whether Windows has patches.

    .PARAMETER ResultPath
    Where to write what happened, as JSON, for the harness to collect.

    .EXAMPLE
    Invoke-UnelevatedRun.ps1 -ResultPath C:\smoke-out\unelevated.json
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $ResultPath
)

$ErrorActionPreference = 'Stop'

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal] $identity

$result = [ordered]@{
    Started      = (Get-Date).ToString('o')
    User         = $identity.Name
    Elevated     = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    PSVersion    = $PSVersionTable.PSVersion.ToString()
    PSEdition    = $PSVersionTable.PSEdition
    Imported     = $false
    Ran          = $null
    Elevated_Run = $null
    FailedCount  = $null
    Reason       = $null
    Error        = $null
}

try {
    Import-Module UpdateEverything -Force
    $result.Imported = $true

    # Bare, so the elevation handoff happens. The result object comes back from
    # the parent; the child's own transcript is what the harness counts.
    $run = Update-Everything -IncludeWindowsUpdate $false

    $result.Ran          = $run.Ran
    $result.Elevated_Run = $run.Elevated
    $result.FailedCount  = $run.FailedCount
    $result.Reason       = $run.Reason
} catch {
    $result.Error = $_.Exception.Message
}

$result.Finished = (Get-Date).ToString('o')

# Written last and in one go, so the harness never reads a half-finished file.
[System.IO.File]::WriteAllText(
    $ResultPath,
    ([pscustomobject] $result | ConvertTo-Json -Depth 4),
    [System.Text.UTF8Encoding]::new($false))
