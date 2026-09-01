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
    Leave the sandbox running after the test finishes, to look around.
    Otherwise it is closed, which discards everything inside it.

    A sandbox does not stop when its logon command finishes, and Windows runs
    only one at a time -- so leaving one open means the next run starts nothing,
    waits out its whole timeout, and reports a failure belonging to the run
    before it. Close it before running again.

    .PARAMETER CloseExistingSandbox
    Close a sandbox that is already open, rather than refusing to start. Off by
    default, because it may be one somebody is using for something else and
    Windows gives no way to tell.

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

    [switch] $KeepSandboxOpen,

    # Close a sandbox that is already open rather than refusing to start.
    # Off by default: it may be one somebody is using for something else, and
    # Windows gives no way to tell whose it is.
    [switch] $CloseExistingSandbox
)

$ErrorActionPreference = 'Stop'

function Close-Sandbox {
    # The sandbox does not stop when its logon command finishes, and Windows
    # runs only one at a time -- so leaving it open guarantees the next run
    # starts nothing, waits out its whole timeout, and reports a failure that
    # belongs to this run. That is exactly what happened once.
    param([switch] $Keep)

    if ($Keep) {
        Write-Host 'Leaving the sandbox open, as asked. Close it before the next run.' -ForegroundColor DarkYellow
        return
    }

    $running = @(Get-Process -Name $script:SandboxProcessNames -ErrorAction SilentlyContinue)
    if ($running.Count -eq 0) { return }

    Stop-SandboxProcess -Process $running
    Write-Host 'Sandbox closed.' -ForegroundColor DarkGray
}

function Stop-SandboxProcess {
    <#
        Waits for the sandbox to finish shutting itself down, and forces it
        only if it does not.

        The harness shuts the guest down when it has written its results, which
        is the only clean way to close a sandbox: the host's session processes
        have no main window, so there is nothing to ask politely from out here.

        Forcing skips the shutdown, and vmmemWindowsSandbox then holds the
        virtual machine's memory for as long as it likes -- measured at 26
        minutes and 807MB on this machine, with no session process left to
        explain it. The next run either waits for that or starts into it and
        hangs, which is how this harness spent an evening failing for reasons
        that had nothing to do with the module.
    #>
    param([Parameter(Mandatory)][object[]] $Process)

    # No CloseMainWindow: these processes have no main window, so it does nothing
    # and reports nothing. The sandbox shuts itself down instead, from inside, at
    # the end of Start-Harness.ps1 -- which is the only clean way to close one and
    # the only way its memory is released promptly. This waits for that to finish.
    #
    # A guest shutdown takes longer than it looks: the session processes on the
    # host outlive it by a while. 60s was not enough and reported forcing on runs
    # that had shut down cleanly.
    $deadline = (Get-Date).AddSeconds(150)
    while ((Get-Date) -lt $deadline) {
        if (-not @(Get-Process -Name $script:SandboxProcessNames -ErrorAction SilentlyContinue).Count) { return }
        Start-Sleep -Seconds 2
    }

    Write-Host '  the sandbox has not finished shutting down; forcing it.' -ForegroundColor DarkYellow
    Write-Host '  the next run may have to wait for its memory to be released.' -ForegroundColor DarkYellow
    Get-Process -Name $script:SandboxProcessNames -ErrorAction SilentlyContinue |
        Stop-Process -Force -ErrorAction SilentlyContinue
}

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

# Windows only runs one sandbox at a time, and starting a second does nothing
# at all -- no window, no error, no clue. A run that hits this waits out its
# whole timeout and reports a failure that belongs to the previous run.
# The session processes, and deliberately not vmmemWindowsSandbox. That one is
# the virtual machine's memory, reclaimed by the hypervisor on its own schedule
# after the session is gone -- it cannot usefully be stopped, and it lingers for
# minutes. Counting it meant "close the open sandbox" reported failure against a
# sandbox that had already closed.
$script:SandboxProcessNames = @(
    'WindowsSandbox', 'WindowsSandboxClient', 'WindowsSandboxServer',
    'WindowsSandboxRemoteSession'
)
$alreadyRunning = @(Get-Process -Name $script:SandboxProcessNames -ErrorAction SilentlyContinue)
if ($alreadyRunning.Count -gt 0) {
    if ($CloseExistingSandbox) {
        Write-Host '  closing the sandbox that is already open...' -ForegroundColor DarkGray
        Stop-SandboxProcess -Process $alreadyRunning
        $stillThere = @(Get-Process -Name $script:SandboxProcessNames -ErrorAction SilentlyContinue)
        if ($stillThere.Count -gt 0) {
            $problems.Add('A Windows Sandbox is still running after being asked to close.')
        }
    } else {
        $problems.Add(
            'A Windows Sandbox is already running, and Windows allows only one. ' +
            'Close it and try again, or pass -CloseExistingSandbox.')
    }
}

# Then wait for the previous sandbox's memory to be released.
#
# The session processes going away is not the end of a sandbox.
# vmmemWindowsSandbox holds the virtual machine's memory and the hypervisor
# reclaims it on its own schedule, over a minute or more. Start a new sandbox
# while that is still happening and it starts -- processes appear, no error --
# and then never runs its logon command, so the run waits out its whole timeout
# and reports a failure that belongs to the timing rather than to the module.
#
# Measured: two runs on one machine, 2m31s apart. The first passed. The second
# left WindowsSandboxServer and WindowsSandboxRemoteSession alive for 25 minutes
# with no logon breadcrumb written.
#
# vmmemWindowsSandbox by name, and never a bare vmmem: that one belongs to WSL
# on any machine that has it, and waiting for it would wait forever.
if (-not $problems.Count) {
    $settleDeadline = (Get-Date).AddSeconds(180)
    $announced = $false

    while (@(Get-Process -Name 'vmmemWindowsSandbox' -ErrorAction SilentlyContinue).Count -gt 0) {
        if ((Get-Date) -ge $settleDeadline) {
            $problems.Add(
                'A previous Windows Sandbox is still releasing its memory (vmmemWindowsSandbox) ' +
                'after 3 minutes. Starting now would produce a sandbox that never runs its logon ' +
                'command. Wait for it to finish, or reboot.')
            break
        }

        if (-not $announced) {
            Write-Host '  waiting for the previous sandbox to release its memory...' -ForegroundColor DarkGray
            $announced = $true
        }
        Start-Sleep -Seconds 5
    }
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
# The logon command waits for its own script to appear before running it.
#
# Windows Sandbox starts the logon command without guaranteeing the mapped
# folders are mounted, and -File against a path that is not there yet fails
# instantly and silently: the sandbox sits at an empty desktop, nothing is
# written, and the only evidence is a run that times out having produced
# nothing at all. It is a race, so it looks intermittent -- the first run of
# this harness worked, and two later ones did not.
#
# It also drops a breadcrumb the moment the folders appear, so a future failure
# can be told apart from this one: no breadcrumb means the mapping never
# arrived, a breadcrumb with no transcript means the harness itself died.
# No ampersand anywhere in here, and that is not a style choice.
#
# Windows Sandbox mishandles "&" in a logon command even when it is correct XML.
# SecurityElement::Escape turns it into "&amp;", which round-trips through
# .NET's XML reader perfectly and still does not survive whatever the sandbox
# does with it: the command never runs, the desktop sits empty, and nothing is
# written anywhere. Measured -- the identical command with the call operator
# removed runs, and with it restored does not.
#
# So the script is called by path rather than with "&". None of these paths
# contains a space, so it needs no quoting either.
#
# The wait is for the mapped folders. The sandbox starts the logon command
# without guaranteeing they are mounted, and a run that begins too early fails
# silently. logon.txt is dropped the moment they appear, so a later failure can
# be told apart from this one: no logon.txt means the mapping never arrived, a
# logon.txt with no transcript means the harness itself died.
$logon = '"C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -Command ' +
    '"$d = (Get-Date).AddMinutes(5); ' +
    'while (-not (Test-Path C:\smoke\Start-Harness.ps1) -and (Get-Date) -lt $d) { Start-Sleep -Seconds 2 }; ' +
    '''reached the mapped folders at '' + (Get-Date -Format o) | Set-Content C:\out\logon.txt; ' +
    'C:\smoke\Start-Harness.ps1 -RepoPath C:\repo -OutputPath C:\out"'

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
Write-Host 'Leave it alone; it drives itself. This closes it afterwards.'

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
    Close-Sandbox -Keep:$KeepSandboxOpen

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

Close-Sandbox -Keep:$KeepSandboxOpen

[pscustomobject]@{
    PSTypeName = 'UpdateEverything.SmokeResult'
    Passed     = [bool] $result.Passed
    Ran        = $true
    Reason     = ''
    Checks     = $result.Checks
    OutputPath = $OutputPath
}
