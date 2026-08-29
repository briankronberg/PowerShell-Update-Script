#Requires -Version 5.1

<#
.SYNOPSIS
    Registers Update-Everything.ps1 as a Windows scheduled task, with settings
    chosen for a laptop rather than a server.

.DESCRIPTION
    Creates a task that runs as *you*, elevated, while you are logged on.

    Running as the logged-on user is not a detail -- it is the whole design.
    A task running as SYSTEM cannot draw a toast notification, because there is
    no interactive desktop session to draw into, so the run would finish silently
    and the restart notice would never appear. Running as the user with
    -RunLevel Highest gets both: administrator rights for Windows Update and
    Defender, and a session that notifications can reach.

    The cost is that the task only runs while you are logged on. -StartWhenAvailable
    covers the common laptop case: a run missed because the machine was asleep or
    shut down happens shortly after you next log on.

.PARAMETER Cadence
    How often to run.

      Weekly        (default) Every week on -DayOfWeek. Recommended for a
                    personal machine: it picks up Patch Tuesday within a few
                    days and keeps the package managers current, without a heavy
                    job every day.

      PatchTuesday  Monthly, on the third Wednesday. That is always 1 to 8 days
                    after Patch Tuesday (Microsoft's second Tuesday), so updates
                    have been public for a few days before they are installed --
                    the usual advice for avoiding a bad patch on day one.

                    The tempting choice, the second Wednesday, is wrong: in 12
                    of the 84 months from 2026 to 2032 it falls *before* Patch
                    Tuesday, so the run would happen before the patches exist.

      Daily         Every day. Thorough but heavy: a full pass across every
                    package manager. Consider it only if you specifically want
                    Defender signatures picked up daily -- though Windows already
                    updates those on its own several times a day.

.PARAMETER DayOfWeek
    Which day the Weekly cadence runs. Default: Wednesday, a day after Patch
    Tuesday.

.PARAMETER At
    Time of day to run. Default: 12:00. Because the task needs you logged on, a
    middle-of-the-night time mostly means the run is deferred to your next logon
    rather than happening overnight.

.PARAMETER TaskName
    Name of the scheduled task. Default: Update-Everything.

.PARAMETER TaskPath
    Task Scheduler folder. Default: \ (the root).

.PARAMETER ScriptPath
    The script to run. Defaults to Update-Everything.ps1 beside this file.

.PARAMETER Notify
    Pass -Notify to the script so it raises toast notifications. Default: $true,
    since an unattended run is exactly the case notifications exist for.

.PARAMETER ExtraArgument
    Additional arguments for Update-Everything.ps1, for example
    -ExtraArgument '-IncludeWindowsUpdate','$false'.

.PARAMETER AllowBattery
    Allow the run to start, and continue, on battery power. Off by default: a
    full update pass is heavy, and Task Scheduler's own default is to wait for
    mains power.

.PARAMETER RandomDelayMinutes
    Spread the start time over this many minutes. Default: 15.

.PARAMETER ExecutionTimeLimitHours
    Stop the task if it runs longer than this. Default: 2. Without a limit, one
    wedged installer leaves the task running until the machine reboots.

.PARAMETER Unregister
    Remove the task instead of creating it.

.PARAMETER Show
    Report the registered task and exit, changing nothing.

.PARAMETER Force
    Replace an existing task of the same name without prompting.

.EXAMPLE
    .\Register-UpdateTask.ps1
    Weekly, Wednesday at noon, with notifications.

.EXAMPLE
    .\Register-UpdateTask.ps1 -Cadence PatchTuesday
    Monthly, on the third Wednesday -- always after Patch Tuesday.

.EXAMPLE
    .\Register-UpdateTask.ps1 -Cadence Weekly -DayOfWeek Saturday -At 09:00

.EXAMPLE
    .\Register-UpdateTask.ps1 -Show

.EXAMPLE
    .\Register-UpdateTask.ps1 -Unregister

.OUTPUTS
    Exit code:
      0   the task was registered, removed, or reported
      1   the task could not be registered
      64  not running elevated, or the script to schedule could not be found

.NOTES
    Registering a task that runs with -RunLevel Highest requires an elevated
    session. Start PowerShell as Administrator and run this from there.
#>

[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
param(
    [ValidateSet('Weekly', 'PatchTuesday', 'Daily')]
    [string] $Cadence = 'Weekly',

    [System.DayOfWeek] $DayOfWeek = [System.DayOfWeek]::Wednesday,

    [datetime] $At = '12:00',

    [ValidateNotNullOrEmpty()]
    [string] $TaskName = 'Update-Everything',

    [ValidateNotNullOrEmpty()]
    [string] $TaskPath = '\',

    [string] $ScriptPath,

    [bool] $Notify = $true,

    [string[]] $ExtraArgument = @(),

    [switch] $AllowBattery,

    [ValidateRange(0, 1440)]
    [int] $RandomDelayMinutes = 15,

    [ValidateRange(1, 24)]
    [int] $ExecutionTimeLimitHours = 2,

    [switch] $Unregister,

    [switch] $Show,

    [switch] $Force
)

# ---------------------------------------------------------------------------
# Functions
#
# Definitions above, work below the dot-source guard, so the test suite can load
# this file and exercise the functions without registering anything.
# ---------------------------------------------------------------------------

function Test-IsAdministrator {
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    ([Security.Principal.WindowsPrincipal] `
        [Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-PowerShellHostPath {
    # Prefer PowerShell 7 when it is installed: the script runs on either, but
    # pwsh is the host the rest of the toolchain assumes.
    [CmdletBinding()]
    [OutputType([string])]
    param()

    foreach ($candidate in 'pwsh', 'powershell') {
        $resolved = Get-Command $candidate -CommandType Application -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($resolved) { return $resolved.Source }
    }

    # Last resort: the host running this script.
    return (Get-Process -Id $PID).Path
}

function Get-NthDayOfWeek {
    # The Nth given weekday of a month, e.g. the third Wednesday of March 2027.
    [CmdletBinding()]
    [OutputType([datetime])]
    param(
        [Parameter(Mandatory)][int] $Year,
        [Parameter(Mandatory)][ValidateRange(1, 12)][int] $Month,
        [Parameter(Mandatory)][System.DayOfWeek] $DayOfWeek,
        [Parameter(Mandatory)][ValidateRange(1, 5)][int] $Occurrence
    )

    $date  = Get-Date -Year $Year -Month $Month -Day 1 -Hour 0 -Minute 0 -Second 0
    $found = 0
    while ($date.Month -eq $Month) {
        if ($date.DayOfWeek -eq $DayOfWeek) {
            $found++
            if ($found -eq $Occurrence) { return $date }
        }
        $date = $date.AddDays(1)
    }

    throw "There is no occurrence $Occurrence of $DayOfWeek in $Year-$Month."
}

function New-UpdateTaskTrigger {
    # Builds the trigger for a cadence.
    #
    # New-ScheduledTaskTrigger has no monthly parameter set at all -- it offers
    # Once, Daily, Weekly, Startup and Logon and nothing else -- so the monthly
    # case is built directly from the Task Scheduler CIM class instead.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('Weekly', 'PatchTuesday', 'Daily')]
        [string] $Cadence,

        [Parameter(Mandatory)][System.DayOfWeek] $DayOfWeek,

        [Parameter(Mandatory)][datetime] $At,

        # Spread of the start time. This belongs to the trigger, not the task
        # settings: New-ScheduledTaskSettingsSet has no -RandomDelay at all, and
        # passing one there fails at run time.
        [ValidateRange(0, 1440)]
        [int] $RandomDelayMinutes = 0
    )

    # RandomDelay is a *string* CIM property holding an ISO 8601 duration, so
    # assigning a [TimeSpan] to it after the fact writes "00:15:00" and
    # Register-ScheduledTask then rejects the task XML with "contains a value
    # which is incorrectly formatted or out of range". The cmdlet's own
    # -RandomDelay parameter converts a TimeSpan properly, to "PT15M".
    $extra = @{}
    if ($RandomDelayMinutes -gt 0) {
        $extra['RandomDelay'] = New-TimeSpan -Minutes $RandomDelayMinutes
    }

    switch ($Cadence) {
        'Daily' {
            return New-ScheduledTaskTrigger -Daily -At $At @extra
        }
        'Weekly' {
            return New-ScheduledTaskTrigger -Weekly -DaysOfWeek $DayOfWeek -At $At @extra
        }
        'PatchTuesday' {
            # Third Wednesday of every month. Bitmasks, not names:
            #   DaysOfWeek   Sunday=1, Monday=2, Tuesday=4, Wednesday=8, ...
            #   WeeksOfMonth first=1, second=2, third=4, fourth=8
            #   MonthsOfYear 4095 = all twelve
            $start = Get-NthDayOfWeek -Year $At.Year -Month $At.Month `
                -DayOfWeek ([System.DayOfWeek]::Wednesday) -Occurrence 3
            $start = $start.Date.Add($At.TimeOfDay)

            $property = @{
                DaysOfWeek    = 8
                WeeksOfMonth  = 4
                MonthsOfYear  = 4095
                StartBoundary = $start.ToString('s')
                Enabled       = $true
            }
            if ($RandomDelayMinutes -gt 0) {
                # The CIM class wants an ISO 8601 duration.
                $property['RandomDelay'] = 'PT{0}M' -f $RandomDelayMinutes
            }

            return New-CimInstance -ClassName MSFT_TaskMonthlyDOWTrigger `
                -Namespace 'Root/Microsoft/Windows/TaskScheduler' -ClientOnly -Property $property
        }
    }
}

function New-UpdateTaskSettingsSet {
    # Task settings tuned for a laptop that is asleep, on battery, or off the
    # network as often as not.
    [CmdletBinding()]
    param(
        [switch] $AllowBattery,
        [int]    $ExecutionTimeLimitHours = 2
    )

    $settings = @{
        # A missed run happens at the next opportunity instead of waiting a whole
        # cycle. This is the setting that makes a schedule work on a laptop.
        StartWhenAvailable = $true

        # Nothing to update without a network, and retrying beats failing.
        RunOnlyIfNetworkAvailable = $true

        # A wedged installer should not hold the task open until the next reboot.
        ExecutionTimeLimit = (New-TimeSpan -Hours $ExecutionTimeLimitHours)

        # A run already in progress wins; a second one would fight it for the
        # same package managers and the same log files.
        MultipleInstances = 'IgnoreNew'

        # Transient network failures are the common case, so try again twice.
        RestartCount    = 2
        RestartInterval = (New-TimeSpan -Minutes 30)

        # Do not wake a sleeping laptop to install updates. StartWhenAvailable
        # picks the run up once it is awake anyway.
        WakeToRun = $false
    }

    if ($AllowBattery) {
        $settings['AllowStartIfOnBatteries']    = $true
        $settings['DontStopIfGoingOnBatteries'] = $true
    }

    New-ScheduledTaskSettingsSet @settings
}

function Get-UpdateTaskArgument {
    # The command line the task runs. -File rather than -Command, since there are
    # no typed arguments to preserve here; -ExecutionPolicy Bypass because the
    # task must not depend on the machine's policy.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string] $ScriptPath,
        [bool] $Notify = $true,
        [string[]] $ExtraArgument = @()
    )

    $parts = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $ScriptPath))
    if ($Notify) { $parts += '-Notify' }
    if ($ExtraArgument) { $parts += $ExtraArgument }

    $parts -join ' '
}

function Get-CadenceDescription {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string] $Cadence,
        [Parameter(Mandatory)][System.DayOfWeek] $DayOfWeek,
        [Parameter(Mandatory)][datetime] $At
    )

    $time = $At.ToString('HH:mm')
    switch ($Cadence) {
        'Daily'        { "every day at $time" }
        'Weekly'       { "every $DayOfWeek at $time" }
        'PatchTuesday' { "the third Wednesday of each month at $time (always after Patch Tuesday)" }
    }
}

# ---------------------------------------------------------------------------
# Dot-source guard
# ---------------------------------------------------------------------------
if ($MyInvocation.InvocationName -eq '.') { return }

# ---------------------------------------------------------------------------
# Work
# ---------------------------------------------------------------------------
$fullTaskName = ($TaskPath.TrimEnd('\') + '\' + $TaskName)

if ($Show) {
    $existing = Get-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -ErrorAction SilentlyContinue
    if (-not $existing) {
        Write-Host "No scheduled task named '$fullTaskName'." -ForegroundColor Yellow
        exit 0
    }

    $info = Get-ScheduledTaskInfo -InputObject $existing
    Write-Host "Task     : $fullTaskName"
    Write-Host "State    : $($existing.State)"
    Write-Host "Runs as  : $($existing.Principal.UserId) (RunLevel $($existing.Principal.RunLevel), LogonType $($existing.Principal.LogonType))"
    Write-Host "Action   : $($existing.Actions[0].Execute) $($existing.Actions[0].Arguments)"
    Write-Host "Last run : $($info.LastRunTime)  result 0x$('{0:X}' -f $info.LastTaskResult)"
    Write-Host "Next run : $($info.NextRunTime)"
    exit 0
}

if ($Unregister) {
    $existing = Get-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -ErrorAction SilentlyContinue
    if (-not $existing) {
        Write-Host "No scheduled task named '$fullTaskName'; nothing to remove."
        exit 0
    }
    if ($PSCmdlet.ShouldProcess($fullTaskName, 'Unregister scheduled task')) {
        Unregister-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -Confirm:$false
        Write-Host "Removed scheduled task '$fullTaskName'." -ForegroundColor Green
    }
    exit 0
}

# Registering a task that runs elevated requires an elevated session. Say so
# rather than failing inside Register-ScheduledTask with an access denial.
if (-not (Test-IsAdministrator)) {
    Write-Warning 'Registering this task requires an elevated session, because the task itself runs with the highest privileges.'
    Write-Warning 'Start PowerShell as Administrator and run this script again. Nothing has been changed.'
    exit 64
}

if (-not $ScriptPath) {
    $ScriptPath = Join-Path $PSScriptRoot 'Update-Everything.ps1'
}
if (-not (Test-Path -LiteralPath $ScriptPath)) {
    Write-Error "Cannot find the script to schedule: $ScriptPath"
    exit 64
}
$ScriptPath = (Resolve-Path -LiteralPath $ScriptPath).Path

$existing = Get-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -ErrorAction SilentlyContinue
if ($existing -and -not $Force) {
    Write-Warning "A task named '$fullTaskName' already exists. Re-run with -Force to replace it, or -Unregister to remove it."
    exit 0
}

$action = New-ScheduledTaskAction `
    -Execute (Get-PowerShellHostPath) `
    -Argument (Get-UpdateTaskArgument -ScriptPath $ScriptPath -Notify $Notify -ExtraArgument $ExtraArgument) `
    -WorkingDirectory (Split-Path $ScriptPath -Parent)

$trigger = New-UpdateTaskTrigger -Cadence $Cadence -DayOfWeek $DayOfWeek -At $At `
    -RandomDelayMinutes $RandomDelayMinutes

$settings = New-UpdateTaskSettingsSet -AllowBattery:$AllowBattery `
    -ExecutionTimeLimitHours $ExecutionTimeLimitHours

# Interactive, as the current user, elevated. See the .DESCRIPTION: SYSTEM would
# be simpler but cannot show a notification to anybody.
$principal = New-ScheduledTaskPrincipal `
    -UserId ([Security.Principal.WindowsIdentity]::GetCurrent().Name) `
    -LogonType Interactive `
    -RunLevel Highest

$description = 'Runs Update-Everything.ps1 to update Windows, Microsoft 365, and every package manager it finds. ' +
    'https://github.com/briankronberg/PowerShell-Update-Script'

if ($PSCmdlet.ShouldProcess($fullTaskName, "Register scheduled task ($Cadence)")) {
    try {
        # -ErrorAction Stop, because Register-ScheduledTask reports a rejected
        # task XML as a non-terminating error. Without this the script carried
        # straight on and printed "Registered" over the top of the failure,
        # having registered nothing at all.
        $null = Register-ScheduledTask `
            -TaskName $TaskName `
            -TaskPath $TaskPath `
            -Action $action `
            -Trigger $trigger `
            -Settings $settings `
            -Principal $principal `
            -Description $description `
            -Force `
            -ErrorAction Stop
    } catch {
        Write-Error "Could not register '$fullTaskName': $($_.Exception.Message)"
        Write-Warning 'Nothing has been scheduled.'
        exit 1
    }

    Write-Host ''
    Write-Host "Registered '$fullTaskName'." -ForegroundColor Green
    Write-Host "  Schedule : $(Get-CadenceDescription -Cadence $Cadence -DayOfWeek $DayOfWeek -At $At)"
    Write-Host "  Runs as  : $([Security.Principal.WindowsIdentity]::GetCurrent().Name), elevated, while logged on"
    Write-Host "  Command  : $($action.Execute) $($action.Arguments)"
    Write-Host ''
    Write-Host '  The task runs only while you are logged on, so that it can show notifications.'
    Write-Host '  A run missed while the machine was off happens shortly after your next logon.'
    Write-Host ''
    Write-Host "  Inspect it later with:"
    Write-Host "    pwsh -NoProfile -ExecutionPolicy Bypass -File '$PSCommandPath' -Show"
    Write-Host "  Run it now with:       Start-ScheduledTask -TaskName '$TaskName' -TaskPath '$TaskPath'"
}

exit 0
