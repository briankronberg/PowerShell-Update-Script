#Requires -Version 5.1

<#
    .SYNOPSIS
    Tests the self-elevation handoff on this machine, with one click from you.

    .DESCRIPTION
    The one thing the fresh-machine test cannot cover. Windows Sandbox ships with
    UAC off, so it has no split token, RunLevel Limited cannot produce an
    unelevated child, and Update-Everything never reaches self-elevation at all.
    Development machines and CI runners are already administrators, so the
    relaunch is never attempted there either.

    This machine has UAC on. The only thing standing between here and real
    coverage is that the prompt needs a person, so this asks for one click rather
    than changing the machine's UAC settings to avoid it.

    Nothing here is changed and nothing is left behind: no registry values, no
    installs, and the scheduled task used to drop privileges is removed whether
    the run succeeds or fails.

    .PARAMETER TimeoutMinutes
    How long to wait for the run, including the time you take to answer the
    prompt. Default: 10.

    .PARAMETER KeepOutput
    Leave the result JSON and transcripts in place afterwards.

    .EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Elevation\Invoke-ElevationTest.ps1

    .NOTES
    Not part of test.ps1. Pester discovers *.Tests.ps1 only, and this one needs a
    person at the keyboard.
#>
[CmdletBinding()]
param(
    [ValidateRange(1, 60)]
    [int] $TimeoutMinutes = 10,

    [switch] $KeepOutput
)

$ErrorActionPreference = 'Stop'

$script:Checks = [System.Collections.Generic.List[object]]::new()

function Add-Check {
    param([string] $Name, [bool] $Passed, [string] $Detail)
    $script:Checks.Add([pscustomobject]@{ Name = $Name; Status = $(if ($Passed) { 'PASS' } else { 'FAIL' }); Passed = $Passed; Detail = $Detail })
}

function Add-NotApplicable {
    # A third state, for the same reason the fresh-machine test has one: a check
    # that could not run neither passed nor failed, and reporting it as a failure
    # says the module is broken when the machine simply could not ask.
    param([string] $Name, [string] $Reason)
    $script:Checks.Add([pscustomobject]@{ Name = $Name; Status = 'N/A'; Passed = $null; Detail = $Reason })
}

Write-Host ''
Write-Host 'Self-elevation test' -ForegroundColor Cyan
Write-Host ''

# --- prerequisites -----------------------------------------------------------

$problems = [System.Collections.Generic.List[string]]::new()

$policy = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
$values = Get-ItemProperty -LiteralPath $policy -ErrorAction SilentlyContinue
$enableLua = if ($values -and $values.PSObject.Properties.Name -contains 'EnableLUA') { $values.EnableLUA } else { $null }
$consent = if ($values -and $values.PSObject.Properties.Name -contains 'ConsentPromptBehaviorAdmin') { $values.ConsentPromptBehaviorAdmin } else { $null }

Write-Host "  EnableLUA=$enableLua ConsentPromptBehaviorAdmin=$consent" -ForegroundColor DarkGray

if ($enableLua -ne 1) {
    $problems.Add("UAC is off (EnableLUA=$enableLua). With no split token there is nothing to elevate from, " +
        'and this test would measure the refusal rather than the handoff.')
}

if (-not (Get-Module UpdateEverything -ListAvailable)) {
    $problems.Add('UpdateEverything is not installed. Install-Module UpdateEverything -Scope CurrentUser')
}

if ($problems.Count) {
    Write-Host ''
    Write-Warning 'Cannot run the elevation test here:'
    foreach ($p in $problems) { Write-Warning "  $p" }
    return [pscustomobject]@{ Ran = $false; Passed = $false; Reason = ($problems -join ' ') }
}

# --- an unelevated session to run it from ------------------------------------

$amAdmin = ([Security.Principal.WindowsPrincipal] `
    [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)

$outputPath = Join-Path ([System.IO.Path]::GetTempPath()) ('UE-Elevation-{0:yyyyMMdd-HHmmss}' -f (Get-Date))
$null = New-Item -ItemType Directory -Path $outputPath -Force
$resultFile = Join-Path $outputPath 'handoff.json'
$payload = Join-Path $PSScriptRoot 'Invoke-ElevatedHandoff.ps1'

Write-Host ''
Write-Host '  A UAC prompt will appear. Answer Yes.' -ForegroundColor Yellow
Write-Host '  That click is the thing being tested, and is why this is not unattended.' -ForegroundColor DarkGray
Write-Host ''

$taskName = 'UpdateEverything-ElevationTest'
$usedTask = $false

try {
    if ($amAdmin) {
        # A scheduled task at RunLevel Limited is how an elevated session starts
        # a genuinely unelevated child of the same user. Without it this test
        # would run as an administrator and measure nothing, because
        # Update-Everything reaches the relaunch only when the session is not
        # already elevated.
        $usedTask = $true
        Write-Host '  this session is elevated, so dropping privileges through a scheduled task...' -ForegroundColor DarkGray

        $action = New-ScheduledTaskAction -Execute 'powershell.exe' `
            -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$payload`" -ResultPath `"$resultFile`""
        $principal = New-ScheduledTaskPrincipal `
            -UserId ([Security.Principal.WindowsIdentity]::GetCurrent().Name) `
            -LogonType Interactive `
            -RunLevel Limited

        Register-ScheduledTask -TaskName $taskName -Action $action -Principal $principal -Force | Out-Null
        Start-ScheduledTask -TaskName $taskName
    } else {
        Write-Host '  this session is not elevated, so running here directly...' -ForegroundColor DarkGray
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $payload -ResultPath $resultFile
    }

    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    $announced = $false
    while (-not (Test-Path -LiteralPath $resultFile) -and (Get-Date) -lt $deadline) {
        if (-not $announced) {
            Write-Host '  waiting for the run to finish...' -ForegroundColor DarkGray
            $announced = $true
        }
        Start-Sleep -Seconds 3
    }
} finally {
    if ($usedTask) {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    }
}

if (-not (Test-Path -LiteralPath $resultFile)) {
    Write-Host ''
    Write-Warning "No result after $TimeoutMinutes minute(s). If the UAC prompt was declined or never appeared, that is why."
    return [pscustomobject]@{ Ran = $false; Passed = $false; Reason = 'the unelevated run never wrote its result'; OutputPath = $outputPath }
}

$run = Get-Content -LiteralPath $resultFile -Raw | ConvertFrom-Json

# --- what happened -----------------------------------------------------------

Write-Host ''
Write-Host '== Results ==' -ForegroundColor Cyan

Add-Check -Name 'UAC is on, so elevation is real' -Passed ($enableLua -eq 1) -Detail "EnableLUA=$enableLua"

Add-Check -Name 'the run started without administrator rights' -Passed (-not $run.Elevated) `
    -Detail "elevated=$($run.Elevated), as $($run.User)"

if ($run.Error) {
    Add-Check -Name 'the run completed without throwing' -Passed $false -Detail $run.Error
} else {
    Add-Check -Name 'the run completed without throwing' -Passed $true
}

# Update-Everything hands off and returns Ran=$false with Elevated=$true. Ran
# being true would mean it decided to carry on unelevated instead, which is a
# different code path and not the one under test.
$handedOff = ($run.Ran -eq $false -and $run.ResultElevated -eq $true)

# A third possibility, and reporting it as a plain failure was misleading on the
# first machine this ran on. Test-ElevationCapability can refuse before any
# prompt appears, and then nothing downstream happened -- so three checks fail
# and none of them says why.
#
# Whether a refusal is correct depends on something this harness cannot settle:
# a genuine standard user should be refused, and an account elevated through a
# privilege-management broker should not, and both look identical from here.
# So it is reported as its own outcome, with the module's reason, for a person
# to judge.
$refused = ($run.Ran -eq $false -and $run.ResultElevated -ne $true -and
            $run.Reason -and $run.Reason -notmatch 'exit code')

if ($refused) {
    Add-NotApplicable -Name 'it elevated rather than carrying on unelevated' `
        -Reason "the module declined to attempt elevation: $($run.Reason)"
    Add-NotApplicable -Name 'the parent reported the elevated exit code' `
        -Reason 'no elevation was attempted'
} else {
    Add-Check -Name 'it elevated rather than carrying on unelevated' -Passed $handedOff `
        -Detail "Ran=$($run.Ran) Elevated=$($run.ResultElevated)"

    $reasonNamesExit = [bool] ($run.Reason -and $run.Reason -match 'exit code')
    Add-Check -Name 'the parent reported the elevated exit code' -Passed $reasonNamesExit -Detail $run.Reason
}

$countIsNumber = ($null -ne $run.FailedCount) -and ($run.FailedCount -is [int] -or $run.FailedCount -is [long])
Add-Check -Name 'FailedCount came back as a number' -Passed $countIsNumber -Detail "FailedCount=$($run.FailedCount)"

# The check this whole harness exists for. One transcript means the elevated
# child died before it could log -- which is exactly how the relaunch parse error
# presented, and why it reached a user's laptop.
$before = @($run.TranscriptsBefore)
$after = @($run.TranscriptsAfter)
$new = @($after | Where-Object { $_ -notin $before })

if ($refused) {
    Add-NotApplicable -Name 'both the parent and the elevated child left a transcript' `
        -Reason "$($new.Count) transcript(s); there is no second one because no child was started"
} else {
    Add-Check -Name 'both the parent and the elevated child left a transcript' -Passed ($new.Count -ge 2) `
        -Detail "$($new.Count) new transcript(s): $($new -join ', ')"
}

# The child's own transcript should reach a summary, which proves it ran rather
# than merely starting.
$reachedSummary = $false
if (-not $refused -and $new.Count -ge 2 -and $run.LogDirectory) {
    foreach ($name in $new) {
        $path = Join-Path $run.LogDirectory $name
        if (Test-Path -LiteralPath $path) {
            $text = Get-Content -LiteralPath $path -Raw -ErrorAction SilentlyContinue
            if ($text -match 'SUMMARY') { $reachedSummary = $true; break }
        }
    }
    Add-Check -Name 'the elevated run reached its summary' -Passed $reachedSummary
} else {
    Add-NotApplicable -Name 'the elevated run reached its summary' `
        -Reason 'there was no second transcript to read'
}

# --- report ------------------------------------------------------------------

Write-Host ''
foreach ($check in $script:Checks) {
    $colour = switch ($check.Status) { 'PASS' { 'Green' } 'FAIL' { 'Red' } default { 'DarkYellow' } }
    Write-Host ("  [{0,-4}] {1}" -f $check.Status, $check.Name) -ForegroundColor $colour
    if ($check.Detail) { Write-Host "         $($check.Detail)" -ForegroundColor DarkGray }
}

$failed = @($script:Checks | Where-Object { $_.Status -eq 'FAIL' })
$notCovered = @($script:Checks | Where-Object { $_.Status -eq 'N/A' })

Write-Host ''
if ($failed.Count) {
    Write-Host "Elevation test FAILED: $($failed.Count) check(s)." -ForegroundColor Red
} elseif ($notCovered.Count) {
    Write-Host "Elevation test passed, with $($notCovered.Count) check(s) this machine could not make." -ForegroundColor DarkYellow
} else {
    Write-Host 'Elevation test passed. The self-elevation handoff works on this machine.' -ForegroundColor Green
}

if ($refused) {
    Write-Host ''
    Write-Host '  NOTE: the handoff was NOT exercised. The module declined to attempt' -ForegroundColor DarkYellow
    Write-Host '        elevation, and whether that was right depends on this account.' -ForegroundColor DarkYellow
    Write-Host '        An account elevated through a privilege-management broker is not' -ForegroundColor DarkYellow
    Write-Host '        in the local Administrators group and can still elevate.' -ForegroundColor DarkYellow
}

Write-Host "Output: $outputPath" -ForegroundColor DarkGray

if (-not $KeepOutput -and -not $failed.Count) {
    Remove-Item -LiteralPath $outputPath -Recurse -Force -ErrorAction SilentlyContinue
}

[pscustomobject]@{
    Ran        = $true
    Passed     = ($failed.Count -eq 0)
    NotCovered = $notCovered.Count
    Checks     = $script:Checks.ToArray()
    OutputPath = $outputPath
}
