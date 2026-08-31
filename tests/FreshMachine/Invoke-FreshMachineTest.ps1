#Requires -Version 5.1

<#
    .SYNOPSIS
    Installs UpdateEverything on an empty Windows and runs it without
    administrator rights, in a throwaway Windows Sandbox.

    .DESCRIPTION
    The only test that exercises the module the way a new user meets it. Three
    defects shipped in one day that nothing else could have caught, because each
    is invisible on a machine where the module already works:

      - the elevated relaunch command did not parse, so the child exited 1
        before running a line. Self-elevation only happens when the session is
        not already an administrator, and development sessions were
      - the documented install required pwsh, which does not exist until this
        module installs it
      - the documented install worked exactly once, because the second run found
        the version folder already there

    A hosted CI runner cannot replace this. The windows-latest image runs as an
    administrator, so the self-elevation path is never reached, and it ships
    PowerShell 7, so the missing-pwsh case cannot arise. Both of the bugs this
    is for are unreachable there.

    Windows Sandbox is the right shape instead: genuinely empty, Windows
    PowerShell only, discarded afterwards. Nothing this test does touches the
    host, including the UAC change, which happens inside the sandbox.

    .PARAMETER OutputPath
    Where results are collected. Defaults to a timestamped folder under the
    user's temp directory. Mapped into the sandbox read-write.

    .PARAMETER TimeoutMinutes
    How long to wait for the sandbox to report. Default 45.

    .PARAMETER KeepSandboxOpen
    Leave the sandbox running after the test finishes, to look around. Without
    it the sandbox closes itself, which discards everything inside.

    .EXAMPLE
    .\Invoke-FreshMachineTest.ps1

    .EXAMPLE
    .\Invoke-FreshMachineTest.ps1 -KeepSandboxOpen -TimeoutMinutes 60

    .OUTPUTS
    An object with Passed, the individual checks, and where the logs were left.
#>
[CmdletBinding()]
[OutputType([pscustomobject])]
param(
    [ValidateNotNullOrEmpty()]
    [string] $OutputPath = (Join-Path ([System.IO.Path]::GetTempPath()) ('UE-FreshMachine-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))),

    [ValidateRange(5, 240)]
    [int] $TimeoutMinutes = 45,

    [switch] $KeepSandboxOpen
)

$ErrorActionPreference = 'Stop'

$repoRoot   = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$sandboxSrc = Join-Path $PSScriptRoot 'Sandbox'

Write-Host ''
Write-Host 'Fresh-machine smoke test' -ForegroundColor Cyan
Write-Host "  repository : $repoRoot"
Write-Host "  results    : $OutputPath"

# --------------------------------------------------------------------------
# Prerequisites, checked before anything is created. Each failure says what to
# do about it, because "sandbox unavailable" on its own sends people hunting.
# --------------------------------------------------------------------------
$problems = [System.Collections.Generic.List[string]]::new()

$edition = (Get-CimInstance Win32_OperatingSystem).Caption
if ($edition -notmatch 'Pro|Enterprise|Education') {
    $problems.Add("Windows Sandbox needs Pro, Enterprise or Education. This is '$edition'.")
}

if (-not (Get-CimInstance Win32_ComputerSystem).HypervisorPresent) {
    $problems.Add('No hypervisor is present. Virtualization has to be enabled in firmware.')
}

$feature = Get-WindowsOptionalFeature -Online -FeatureName 'Containers-DisposableClientVM' -ErrorAction SilentlyContinue
if (-not $feature -or $feature.State -ne 'Enabled') {
    $problems.Add(
        'Windows Sandbox is not enabled. From an elevated session: ' +
        'Enable-WindowsOptionalFeature -Online -FeatureName Containers-DisposableClientVM -All')
}

$sandboxExe = Join-Path $env:WINDIR 'System32\WindowsSandbox.exe'
if (-not (Test-Path -LiteralPath $sandboxExe)) {
    $problems.Add("WindowsSandbox.exe was not found at $sandboxExe.")
}

if ($problems.Count -gt 0) {
    Write-Host ''
    Write-Warning 'Cannot run the fresh-machine test here:'
    foreach ($problem in $problems) { Write-Warning "  $problem" }
    return [pscustomobject]@{
        PSTypeName = 'UpdateEverything.SmokeResult'
        Passed     = $false
        Ran        = $false
        Reason     = ($problems -join ' ')
        Checks     = @()
        OutputPath = $null
    }
}

$null = New-Item -ItemType Directory -Path $OutputPath -Force

# --------------------------------------------------------------------------
# The sandbox configuration. Written per run, because the mapped paths depend
# on where the repository was cloned.
# --------------------------------------------------------------------------
$logon = '"C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass ' +
    '-File "C:\smoke\Start-Harness.ps1" -RepoPath "C:\repo" -OutputPath "C:\out"'

# Escaped, not interpolated raw. '&' is legal in a Windows path and fatal in
# XML: a clone under C:\dev\R&D produces a .wsb the sandbox rejects, and it
# reports that as a malformed file rather than as the ampersand it is.
$escapedRepo    = [System.Security.SecurityElement]::Escape($repoRoot)
$escapedSandbox = [System.Security.SecurityElement]::Escape($sandboxSrc)
$escapedOutput  = [System.Security.SecurityElement]::Escape($OutputPath)
$escapedLogon   = [System.Security.SecurityElement]::Escape($logon)

$wsb = @"
<Configuration>
  <MappedFolders>
    <MappedFolder>
      <HostFolder>$escapedRepo</HostFolder>
      <SandboxFolder>C:\repo</SandboxFolder>
      <ReadOnly>true</ReadOnly>
    </MappedFolder>
    <MappedFolder>
      <HostFolder>$escapedSandbox</HostFolder>
      <SandboxFolder>C:\smoke</SandboxFolder>
      <ReadOnly>true</ReadOnly>
    </MappedFolder>
    <MappedFolder>
      <HostFolder>$escapedOutput</HostFolder>
      <SandboxFolder>C:\out</SandboxFolder>
      <ReadOnly>false</ReadOnly>
    </MappedFolder>
  </MappedFolders>
  <LogonCommand>
    <Command>$escapedLogon</Command>
  </LogonCommand>
  <Networking>Enable</Networking>
  <MemoryInMB>8192</MemoryInMB>
</Configuration>
"@

$wsbPath = Join-Path $OutputPath 'FreshMachine.wsb'
[System.IO.File]::WriteAllText($wsbPath, $wsb, [System.Text.UTF8Encoding]::new($false))

# The XML is generated from paths that may contain anything, so prove it parses
# before handing it to the sandbox, which reports a malformed file unhelpfully.
try {
    $null = [xml] $wsb
} catch {
    throw "The generated sandbox configuration is not valid XML: $($_.Exception.Message)"
}

Write-Host ''
Write-Host 'Starting Windows Sandbox. It installs from GitHub, so it needs a network.' -ForegroundColor Yellow
Write-Host 'Leave it alone; it drives itself and closes when it is done.'

Start-Process -FilePath $sandboxExe -ArgumentList "`"$wsbPath`""

$resultFile = Join-Path $OutputPath 'result.json'
$deadline = (Get-Date).AddMinutes($TimeoutMinutes)
$spin = 0

while (-not (Test-Path -LiteralPath $resultFile) -and (Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 10
    $spin += 10
    if ($spin % 60 -eq 0) {
        Write-Host "  still running, $([int]((Get-Date) - $deadline).TotalMinutes * -1) minute(s) left"
    }
}

if (-not (Test-Path -LiteralPath $resultFile)) {
    Write-Warning "No result after $TimeoutMinutes minutes. Anything the sandbox wrote is in $OutputPath."
    return [pscustomobject]@{
        PSTypeName = 'UpdateEverything.SmokeResult'
        Passed     = $false
        Ran        = $true
        Reason     = "Timed out after $TimeoutMinutes minutes."
        Checks     = @()
        OutputPath = $OutputPath
    }
}

$result = Get-Content -LiteralPath $resultFile -Raw | ConvertFrom-Json

Write-Host ''
foreach ($check in $result.Checks) {
    # Three states, not two. A check the machine could not run is not a failure
    # and must not be coloured like one.
    $colour = switch ($check.Status) {
        'PASS'  { 'Green' }
        'FAIL'  { 'Red' }
        default { 'DarkYellow' }
    }
    Write-Host ("  [{0}] {1}" -f $check.Status.PadRight(4), $check.Name) -ForegroundColor $colour
    if ($check.Detail) { Write-Host "         $($check.Detail)" -ForegroundColor DarkGray }
}

Write-Host ''
if (-not $result.Passed) {
    Write-Host 'Fresh-machine test FAILED.' -ForegroundColor Red
} elseif ($result.NotCovered -gt 0) {
    # Said plainly rather than buried. A green run that skipped the elevation
    # checks proves less than a green run that made them, and the difference
    # matters most to whoever is deciding whether it is safe to release.
    Write-Host 'Fresh-machine test passed.' -ForegroundColor Green
    Write-Host "$($result.NotCovered) check(s) could not run on this machine; see N/A above for why." -ForegroundColor DarkYellow
} else {
    Write-Host 'Fresh-machine test passed, with everything covered.' -ForegroundColor Green
}
Write-Host "Logs and transcripts: $OutputPath"

if (-not $KeepSandboxOpen) {
    Write-Host 'The sandbox closes itself; everything inside it is discarded.' -ForegroundColor DarkGray
}

[pscustomobject]@{
    PSTypeName = 'UpdateEverything.SmokeResult'
    Passed     = [bool] $result.Passed
    Ran        = $true
    Reason     = ''
    Checks     = $result.Checks
    OutputPath = $OutputPath
}
