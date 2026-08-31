function Register-UpdateEverythingTask {
    <#
    .SYNOPSIS
        Registers Update-Everything as a Windows scheduled task, with settings
        chosen for a laptop rather than a server.

    .DESCRIPTION
        Creates a task that runs as you, elevated, while you are logged on.

        Running as the logged-on user is the whole design, not a detail. A task
        running as SYSTEM cannot draw a toast notification, because there is no
        interactive desktop session to draw into, so the run would finish
        silently and the restart notice would never appear. Running as the user
        with RunLevel Highest gets both administrator rights and a session
        notifications can reach.

        The cost is that the task only runs while you are logged on.
        StartWhenAvailable covers the common laptop case. A run missed because
        the machine was asleep or shut down happens shortly after your next
        logon.

        Registering needs an elevated session, because the task itself runs with
        the highest privileges.

    .PARAMETER Cadence
        How often to run.

          Weekly        (default) Every week on -DayOfWeek. Recommended for a
                        personal machine. It picks up Patch Tuesday within a few
                        days and keeps the package managers current without a
                        heavy job every day.

          PatchTuesday  Monthly, on the third Wednesday. That is always 1 to 8
                        days after Patch Tuesday, so updates have been public for
                        a few days before they are installed.

                        The tempting choice, the second Wednesday, is wrong. In
                        12 of the 84 months from 2026 to 2032 it falls before
                        Patch Tuesday, so the run would happen before the patches
                        exist.

          Daily         Every day. Thorough but heavy. Windows already updates
                        Defender signatures on its own several times a day.

    .PARAMETER DayOfWeek
        Which day the Weekly cadence runs. Default: Wednesday.

    .PARAMETER At
        Time of day to run. Default: 12:00. The task needs you logged on, so a
        middle-of-the-night time mostly means the run is deferred to your next
        logon.

    .PARAMETER TaskName
        Name of the scheduled task. Default: Update-Everything.

    .PARAMETER TaskPath
        Task Scheduler folder. Default: \ (the root).

    .PARAMETER Notify
        Pass -Notify to the run so it raises toast notifications. Default: $true,
        since an unattended run is the case notifications exist for.

    .PARAMETER AllowInstall
        Approvals to pass through for first-time installs. A scheduled run cannot
        prompt, so anything not approved here is declined and its step reported
        as skipped. Accepts All, PowerShell7, PSWindowsUpdate, NuGetProvider,
        BurntToast, PowerShellGet.

    .PARAMETER WindowStyle
        How the run's console window appears: Normal (default), Minimized or
        Hidden. Hidden still flashes a window briefly as the process starts,
        which is Windows behaviour rather than something this can suppress.
        Ignored when -PromptBeforeRun is set.

    .PARAMETER PromptBeforeRun
        Have the run pause and offer to run now, skip, or wait, instead of
        starting the moment the trigger fires. Forces -WindowStyle Normal,
        because a window you cannot see cannot ask you anything.

    .PARAMETER PromptTimeoutSeconds
        How long that prompt waits before starting the run anyway. Default: 60.

    .PARAMETER ExtraArgument
        Additional arguments for Update-Everything, for example
        -ExtraArgument '-IncludeWindowsUpdate','$false'.

    .PARAMETER AllowBattery
        Allow the run to start, and continue, on battery power. Off by default,
        because a full update pass is heavy.

    .PARAMETER RandomDelayMinutes
        Spread the start time over this many minutes. Default: 15.

    .PARAMETER ExecutionTimeLimitHours
        Stop the task if it runs longer than this. Default: 2. Without a limit,
        one wedged installer leaves the task running until the machine reboots.

    .PARAMETER Force
        Replace an existing task of the same name without prompting.

    .EXAMPLE
        Register-UpdateEverythingTask

        Weekly, Wednesday at noon, with notifications.

    .EXAMPLE
        Register-UpdateEverythingTask -Cadence PatchTuesday -AllowInstall PSWindowsUpdate

        Monthly on the third Wednesday, permitted to install PSWindowsUpdate.

    .OUTPUTS
        The registered scheduled task.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Write-Host is the user interface of a console maintenance tool. Its output is progress a person watches, not data a caller consumes, and the summary uses colour to separate failures from noise.')]
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

        [bool] $Notify = $true,

        [ValidateSet('All', 'PowerShell7', 'PSWindowsUpdate', 'NuGetProvider', 'BurntToast', 'PowerShellGet', 'PSResourceGet')]
        [string[]] $AllowInstall = @(),

        # Passed straight through to the run this task performs, so one machine
        # can carry a daily task that skips a toolchain and a monthly one that
        # updates only that toolchain.
        [ValidateSet('Windows', 'Microsoft', 'PowerShell', 'PackageManager', 'Python', 'Node', 'DotNet', 'Rust', 'Git', 'Self')]
        [string[]] $Tag = @(),

        [ValidateSet('Windows', 'Microsoft', 'PowerShell', 'PackageManager', 'Python', 'Node', 'DotNet', 'Rust', 'Git', 'Self')]
        [string[]] $ExcludeTag = @(),

        [ValidateSet('Normal', 'Minimized', 'Hidden')]
        [string] $WindowStyle = 'Normal',

        [switch] $PromptBeforeRun,

        [ValidateRange(5, 3600)]
        [int] $PromptTimeoutSeconds = 60,

        [string[]] $ExtraArgument = @(),

        [switch] $AllowBattery,

        [ValidateRange(0, 1440)]
        [int] $RandomDelayMinutes = 15,

        [ValidateRange(1, 24)]
        [int] $ExecutionTimeLimitHours = 2,

        [switch] $Force
    )

    $fullTaskName = ($TaskPath.TrimEnd('\') + '\' + $TaskName)

    if (-not (Test-IsAdministrator)) {
        throw 'Registering this task requires an elevated session, because the task itself runs with the highest privileges. Start PowerShell as Administrator and try again. Nothing has been changed.'
    }

    $existing = Get-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -ErrorAction SilentlyContinue
    if ($existing -and -not $Force) {
        throw "A task named '$fullTaskName' already exists. Use -Force to replace it, or Unregister-UpdateEverythingTask to remove it."
    }

    $effectiveWindowStyle = Resolve-WindowStyle -Requested $WindowStyle -PromptBeforeRun:$PromptBeforeRun

    $arguments = Get-UpdateTaskArgument -ModuleRoot $script:ModuleRoot -Notify $Notify `
        -WindowStyle $effectiveWindowStyle -PromptBeforeRun:$PromptBeforeRun `
        -PromptTimeoutSeconds $PromptTimeoutSeconds `
        -AllowInstall $AllowInstall -Tag $Tag -ExcludeTag $ExcludeTag `
        -ExtraArgument $ExtraArgument

    $action = New-ScheduledTaskAction -Execute (Get-PowerShellHostPath) -Argument $arguments

    $trigger = New-UpdateTaskTrigger -Cadence $Cadence -DayOfWeek $DayOfWeek -At $At `
        -RandomDelayMinutes $RandomDelayMinutes

    $settings = New-UpdateTaskSettingsSet -AllowBattery:$AllowBattery `
        -ExecutionTimeLimitHours $ExecutionTimeLimitHours

    # Interactive, as the current user, elevated. SYSTEM would be simpler but
    # cannot show a notification to anybody.
    $principal = New-ScheduledTaskPrincipal `
        -UserId ([Security.Principal.WindowsIdentity]::GetCurrent().Name) `
        -LogonType Interactive `
        -RunLevel Highest

    $description = 'Runs Update-Everything to update Windows, Microsoft 365, and every package manager it finds. ' +
        'https://github.com/briankronberg/UpdateEverything'

    if (-not $PSCmdlet.ShouldProcess($fullTaskName, "Register scheduled task ($Cadence)")) {
        return
    }

    $task = Register-ScheduledTask `
        -TaskName $TaskName `
        -TaskPath $TaskPath `
        -Action $action `
        -Trigger $trigger `
        -Settings $settings `
        -Principal $principal `
        -Description $description `
        -Force `
        -ErrorAction Stop

    Write-Host ''
    Write-Host "Registered '$fullTaskName'." -ForegroundColor Green
    Write-Host "  Schedule : $(Get-CadenceDescription -Cadence $Cadence -DayOfWeek $DayOfWeek -At $At)"
    Write-Host "  Runs as  : $([Security.Principal.WindowsIdentity]::GetCurrent().Name), elevated, while logged on"
    $windowNote = if ($PromptBeforeRun) { ", prompting first (${PromptTimeoutSeconds}s to answer)" } else { '' }
    Write-Host "  Window   : ${effectiveWindowStyle}${windowNote}"
    Write-Host ''
    Write-Host '  The task runs only while you are logged on, so that it can show notifications.'
    Write-Host '  A run missed while the machine was off happens shortly after your next logon.'

    if ($Notify -and -not (Test-NotificationModuleAvailable) -and
        -not ($AllowInstall -contains 'All' -or $AllowInstall -contains 'BurntToast')) {
        Write-Host ''
        Write-Warning 'The task passes -Notify, but the BurntToast module is not installed, so it will run and notify nobody.'
        Write-Warning 'A scheduled run cannot prompt for consent to install it. Either install it once with:'
        Write-Warning '    Install-Module BurntToast -Scope CurrentUser'
        Write-Warning '_or re-register with -AllowInstall BurntToast.'
    }

    $task
}
