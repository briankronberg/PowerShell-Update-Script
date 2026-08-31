#Requires -Version 5.1

<#
    .SYNOPSIS
    Drives the fresh-machine smoke test from inside Windows Sandbox.

    .DESCRIPTION
    Started by the sandbox logon command, which runs elevated. Everything that
    needs administrator rights happens here; the part under test is handed to an
    unelevated child.

    The install command is read out of README.md rather than copied into this
    file. A smoke test with its own copy of the command tests the copy, and the
    three defects this exists to catch were all in the documented command or on
    the path it leads to.

    UAC is left enabled and only the consent behaviour is changed. Turning UAC
    off would be the obvious way to get an unattended elevation, and it would
    test the wrong thing: Test-ElevationCapability reads EnableLUA and refuses
    the run outright when it is 0, so the harness would be measuring the refusal
    rather than the handoff.

    .PARAMETER RepoPath
    The repository, mapped into the sandbox read-only. README.md is read from
    here.

    .PARAMETER OutputPath
    A folder mapped read-write, where results are left for the host.

    .EXAMPLE
    Start-Harness.ps1 -RepoPath C:\repo -OutputPath C:\smoke-out
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $RepoPath,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $OutputPath
)

$ErrorActionPreference = 'Stop'

$transcript = Join-Path $OutputPath 'harness.log'
Start-Transcript -Path $transcript -Force | Out-Null

$checks = [System.Collections.Generic.List[object]]::new()
function Add-Check {
    param(
        [Parameter(Mandatory)][string] $Name,
        [Parameter(Mandatory)][bool]   $Passed,
        [string] $Detail
    )
    $checks.Add([pscustomobject]@{ Name = $Name; Passed = $Passed; Detail = $Detail })
    $mark = if ($Passed) { 'PASS' } else { 'FAIL' }
    Write-Output ("  [{0}] {1}{2}" -f $mark, $Name, $(if ($Detail) { " -- $Detail" } else { '' }))
}

try {
    Write-Output '== Environment =='
    $os = Get-CimInstance Win32_OperatingSystem
    Write-Output "  $($os.Caption) build $($os.BuildNumber)"
    Write-Output "  PowerShell $($PSVersionTable.PSVersion) ($($PSVersionTable.PSEdition))"

    # The premise of the whole exercise. If pwsh is already here, this is not a
    # fresh machine and the missing-pwsh case cannot be observed.
    $pwshPresent = [bool] (Get-Command pwsh -CommandType Application -ErrorAction SilentlyContinue)
    Add-Check -Name 'machine has no PowerShell 7 to start with' -Passed (-not $pwshPresent) `
        -Detail $(if ($pwshPresent) { 'pwsh resolved; this is not a fresh machine' } else { 'pwsh absent, as expected' })

    Write-Output ''
    Write-Output '== UAC =='
    # EnableLUA stays 1 so Test-ElevationCapability still allows the run.
    # ConsentPromptBehaviorAdmin 0 means "elevate without prompting", which is
    # what lets the child start with nobody at the keyboard.
    $policy = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
    Set-ItemProperty -Path $policy -Name 'ConsentPromptBehaviorAdmin' -Value 0 -Type DWord
    $enableLua = (Get-ItemProperty -Path $policy -Name 'EnableLUA').EnableLUA
    $consent   = (Get-ItemProperty -Path $policy -Name 'ConsentPromptBehaviorAdmin').ConsentPromptBehaviorAdmin
    Write-Output "  EnableLUA=$enableLua ConsentPromptBehaviorAdmin=$consent"
    Add-Check -Name 'UAC still enabled' -Passed ($enableLua -eq 1) -Detail "EnableLUA=$enableLua"

    Write-Output ''
    Write-Output '== Install command, taken from README =='
    $readme = Get-Content (Join-Path $RepoPath 'README.md') -Raw

    # The first fenced powershell block in the Install section is the command a
    # new user pastes.
    $section = [regex]::Match($readme, '(?s)\n## Install\r?\n(.*?)\r?\n## ').Groups[1].Value
    $command = [regex]::Match($section, '(?s)```powershell\r?\n(.*?)```').Groups[1].Value.Trim()

    $found = -not [string]::IsNullOrWhiteSpace($command)
    Add-Check -Name 'install command found in README' -Passed $found
    if (-not $found) { throw 'Could not extract the install command from README.md.' }
    Write-Output "  $command"

    # Twice. The second run is what -Force exists for: the module installs into
    # a folder named for its version, and the version does not move per commit.
    foreach ($attempt in 1, 2) {
        Write-Output ''
        Write-Output "-- install attempt $attempt --"
        $installLog = Join-Path $OutputPath "install-$attempt.log"

        & powershell.exe -NoProfile -ExecutionPolicy Bypass -Command $command *> $installLog
        $code = $LASTEXITCODE

        $text = Get-Content $installLog -Raw
        $ok = ($code -eq 0) -and ($text -match 'Installed UpdateEverything')
        Add-Check -Name "install succeeds (attempt $attempt)" -Passed $ok -Detail "exit $code"
        Write-Output ($text -split "`r?`n" | Select-Object -Last 12 | ForEach-Object { "    $_" })
    }

    Write-Output ''
    Write-Output '== Unelevated run =='
    $logDir = Join-Path $env:USERPROFILE 'UpdateLogs'
    $before = @()
    if (Test-Path $logDir) {
        $before = @((Get-ChildItem $logDir -Filter 'Update-Everything-*.log').Name)
    }

    # A scheduled task at RunLevel Limited is how an elevated session starts a
    # genuinely unelevated child of the same user.
    $runResult = Join-Path $OutputPath 'unelevated.json'
    $payload   = Join-Path $PSScriptRoot 'Invoke-UnelevatedRun.ps1'

    $taskName = 'UpdateEverything-SmokeTest'
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' `
        -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$payload`" -ResultPath `"$runResult`""
    $taskPrincipal = New-ScheduledTaskPrincipal `
        -UserId ([Security.Principal.WindowsIdentity]::GetCurrent().Name) `
        -LogonType Interactive `
        -RunLevel Limited

    $register = @{
        TaskName  = $taskName
        Action    = $action
        Principal = $taskPrincipal
        Force     = $true
    }
    Register-ScheduledTask @register | Out-Null
    Start-ScheduledTask -TaskName $taskName

    Write-Output '  waiting for the unelevated run to finish...'
    $deadline = (Get-Date).AddMinutes(30)
    while (-not (Test-Path $runResult) -and (Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 5
    }
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue

    $produced = Test-Path $runResult
    Add-Check -Name 'unelevated run produced a result' -Passed $produced `
        -Detail $(if ($produced) { '' } else { 'timed out after 30 minutes' })
    if (-not $produced) { throw 'The unelevated run never wrote its result.' }

    $run = Get-Content $runResult -Raw | ConvertFrom-Json
    Write-Output "  ran as $($run.User), elevated=$($run.Elevated)"

    Add-Check -Name 'payload ran without administrator rights' -Passed (-not $run.Elevated) `
        -Detail "elevated=$($run.Elevated)"
    Add-Check -Name 'module imported after install' -Passed ([bool] $run.Imported)
    Add-Check -Name 'run reported no error' -Passed ([string]::IsNullOrEmpty($run.Error)) -Detail $run.Error

    Write-Output ''
    Write-Output '== Transcripts =='
    $after = @((Get-ChildItem $logDir -Filter 'Update-Everything-*.log' -ErrorAction SilentlyContinue).Name)
    $new = @($after | Where-Object { $_ -notin $before })
    Write-Output "  new transcripts: $($new.Count)"
    $new | ForEach-Object { Write-Output "    $_" }

    # Two: the parent's, which records the handoff, and the elevated child's own.
    # One means the child died before it could log -- which is exactly how the
    # relaunch parse error presented, and why counting them is the assertion.
    Add-Check -Name 'both parent and elevated child left a transcript' -Passed ($new.Count -ge 2) `
        -Detail "$($new.Count) found"

    $childReachedSummary = $false
    foreach ($name in $new) {
        $body = Get-Content (Join-Path $logDir $name) -Raw
        if ($body -match 'Maintenance run started' -and $body -match '=+ SUMMARY =+') {
            $childReachedSummary = $true
        }
        Copy-Item (Join-Path $logDir $name) (Join-Path $OutputPath $name) -Force
    }
    Add-Check -Name 'a transcript reached the summary' -Passed $childReachedSummary

    Add-Check -Name 'FailedCount came back as a number' -Passed ($null -ne $run.FailedCount) `
        -Detail "FailedCount=$($run.FailedCount)"
} catch {
    Add-Check -Name 'harness completed' -Passed $false -Detail $_.Exception.Message
    Write-Output "HARNESS ERROR: $($_.Exception.Message)"
}

$summary = [pscustomobject]@{
    Finished = (Get-Date).ToString('o')
    Passed   = @($checks | Where-Object { -not $_.Passed }).Count -eq 0
    Checks   = $checks.ToArray()
}

Write-Output ''
Write-Output "== $(if ($summary.Passed) { 'ALL CHECKS PASSED' } else { 'FAILURES PRESENT' }) =="

[System.IO.File]::WriteAllText(
    (Join-Path $OutputPath 'result.json'),
    ($summary | ConvertTo-Json -Depth 5),
    [System.Text.UTF8Encoding]::new($false))

Stop-Transcript | Out-Null
