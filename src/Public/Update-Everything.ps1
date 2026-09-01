function Update-Everything {

    <#
    .SYNOPSIS
        One-shot maintenance script that updates everything on a Windows laptop
        through the package managers and update channels it can find.

    .DESCRIPTION
        Each update channel runs as an isolated step, so one failure does not stop
        the rest. Every step writes its own log, and the run ends with a summary
        table and a result object.

        What it drives:
          - winget: the source indexes, App Installer (winget itself, which
            "winget upgrade --all" does not reliably cover), then every source
          - Windows Update via the PSWindowsUpdate module, scanning Microsoft
            Update rather than Windows Update alone, so Office and other
            Microsoft products are included
          - Microsoft 365 Apps via OfficeC2RClient, and Defender signatures
          - PowerShell modules and help, with PSGallery trusted once
            (PowerShellGet v2 and PSResourceGet v3) so neither stops on the
            untrusted-repository prompt
          - Python (Install Manager), uv, pipx, npm, Chocolatey, Scoop, rustup,
            dotnet global tools and workloads, GitHub CLI extensions, WSL kernel
          - PowerShell 7 itself, installed or upgraded through winget in MSI form
            so it lands in C:\Program Files\PowerShell\7, the path Windows
            Terminal looks for
          - Windows Terminal's defaultProfile, pointed at the PowerShell Core
            profile GUID. Only that one value is changed; the rest of
            settings.json is preserved

        How it behaves:
          - Steps capture every stream (*>&1), not just warnings, so the step log
            is a complete record. Native stderr surfaces as error records too, and
            many CLIs write ordinary progress there, so only errors raised by
            PowerShell itself are counted -- those mark a step 'Warning' rather
            than 'OK'.
          - Package managers routinely return non-zero for "nothing to do" or for
            a partial success. Those codes are enumerated per step rather than
            being treated as run failures.
          - $LASTEXITCODE is reset per step, so a cmdlet-only step cannot inherit
            a stale code from an earlier native command.
          - Presence of an .exe is not proof a feature is installed. wsl.exe ships
            in System32 on every Windows 11 machine; Defender cmdlets exist even
            where a third-party AV has taken over. Both are probed before use.
          - winget output is localised and its Id column is truncated to the
            console width, so package presence is decided by exit code, never by
            text match.
          - The elevated relaunch passes -Command rather than -File, so typed
            [bool] parameters survive it.
          - Step logs and the transcript share one per-run stamp and are pruned by
            -LogRetentionDays.
          - The failed-step count is returned rather than exited with, so calling
            this from a session does not end that session. A scheduled task turns
            FailedCount into an exit code itself.

        Policy note: winget runs here with --accept-package-agreements, which
        accepts vendor licence agreements on your behalf for every package it
        touches. That is deliberate for unattended runs, but it is a real consent
        decision -- drop the flag if you would rather approve each one by hand.

    .PARAMETER IncludeWindowsUpdate
        Install pending updates via the PSWindowsUpdate module, scanning Microsoft
        Update so Office and other Microsoft products are covered alongside the OS
        and drivers. Default: $true. Requires admin and may require a reboot.

    .PARAMETER IncludePowerShell7
        Install PowerShell 7 if missing, or upgrade it to the latest release.
        Default: $true. A machine-wide MSI install/upgrade requires admin.

    .PARAMETER SetPwshTerminalDefault
        Point Windows Terminal's default profile at PowerShell 7. Default: $true.
        Per-user change; silently skipped if Windows Terminal is not installed.

    .PARAMETER IncludePowerShellModules
        Update every installed PowerShell module. Default: $true.

        Set it to $false for a run that should leave modules alone, which is
        usually because one is pinned to a version something else depends on.
        The step is reported as skipped rather than dropped.

        -ExcludeTag PowerShell is the broader hammer: it also skips the gallery
        trust, the gallery tooling, help, PowerShell 7 and the Terminal default.

    .PARAMETER AutoReboot
        Allow Windows Update to reboot automatically if required. Default: $false

    .PARAMETER IncludePrerelease
        Include prerelease/preview builds where the tool supports it. Default: $false.
        Currently applies to PowerShell module updates (Update-PSResource -Prerelease
        / Update-Module -AllowPrerelease).

    .PARAMETER UpdateGlobalNpm
        Update global npm packages in addition to npm itself. Default: $false

    .PARAMETER SkipElevation
        Do not relaunch elevated. Steps marked as requiring administrator are
        reported as skipped with that reason rather than failing on a permissions
        error. Useful for unattended/standard-user runs.

    .PARAMETER AllowInstall
        Which missing components this run may install for the first time. Updating
        something already present never needs approval; installing something new
        always does.

        This is an update script, not an installer. Left unset, nothing new is
        installed: an interactive run asks before each one, and a non-interactive
        run (a scheduled task) declines and reports the step as skipped, because
        there is nobody there to ask.

        Accepts any of:
          All              approve everything below
          PowerShell7      install PowerShell 7 via winget (machine-wide MSI)
          PSWindowsUpdate  install the PSWindowsUpdate module (AllUsers scope)
          NuGetProvider    install the NuGet package provider (CurrentUser)
          BurntToast       install the BurntToast module for -Notify (CurrentUser)
          PowerShellGet    replace the PowerShellGet 1.0.0.1 Windows ships with
                           2.x, which can accept module licenses and can see
                           modules installed by newer versions (AllUsers when
                           elevated, otherwise CurrentUser)
          PSResourceGet    install Microsoft.PowerShell.PSResourceGet, the
                           current gallery client. Changes which client every
                           later module update uses (AllUsers when elevated,
                           otherwise CurrentUser)

        NuGetProvider also covers refreshing a provider that is already present.
        There is no update command for a package provider, so moving one forward
        means installing the newer version, and that asks.

        A scheduled task cannot prompt, so pass the approvals it should have:
            -AllowInstall PSWindowsUpdate,BurntToast

    .PARAMETER PromptBeforeRun
        Pause before doing anything and offer a way out: run now, skip this run, or
        wait -DelayMinutes and then run. Intended for a scheduled run that may land
        while you are in the middle of something.

        The prompt takes the default (run now) after -PromptTimeoutSeconds, so an
        unattended machine is never left waiting on an answer nobody is there to
        give. If the run cannot prompt at all -- a hidden window, redirected input --
        it says so and starts immediately rather than blocking.

    .PARAMETER PromptTimeoutSeconds
        How long the -PromptBeforeRun prompt waits before starting the run anyway.
        Default: 60.

    .PARAMETER DelayMinutes
        How long the "wait, then run" answer waits. Default: 60.

    .PARAMETER Notify
        Show Windows toast notifications when the run finishes: a summary, and a
        separate urgent notification when a restart is required. Off by default,
        because an interactive run already prints everything to the console. Meant
        for scheduled runs, where the summary would otherwise go unseen.

        Requires the BurntToast module (https://github.com/Windos/BurntToast) and an
        interactive desktop session. Either being absent degrades to no
        notifications; it never fails the run.

        That check happens before the first update step, not at the end, so the
        warning lands at the top of the transcript rather than after a long run.
        The reason is repeated in the closing summary, because by then the original
        warning has scrolled well out of sight.

    .PARAMETER UpdateSelf
        Update this module before doing anything else. Default: $false.
        -UpdateSelfSource decides where from, and defaults to the gallery.

        It takes effect on the *next* run either way. Unlike winget, which is a
        fresh process every step, this module is already loaded by the time the
        step runs: the files on disk are replaced, and the functions executing
        now stay on the code already in memory.

        Off by default. From Main it fetches and runs an installer from a
        branch, which is a supply-chain decision rather than a routine update,
        and a scheduled task that quietly followed main would be making that
        decision on every run.

    .PARAMETER Tag
        Run only the steps carrying one of these tags. Everything else is
        reported as skipped with that reason, so the summary still accounts for
        every step.

        A step carries one or more of: Windows, Microsoft, PowerShell,
        PackageManager, Python, Node, DotNet, Rust, Git, Self, Inventory.

            Update-Everything -Tag Python
            Update-Everything -Tag Inventory    report what is installed, update nothing

    .PARAMETER ExcludeTag
        Run everything except the steps carrying one of these tags. Takes the
        same values as -Tag.

            Update-Everything -ExcludeTag Python

        Both may be given at once, and exclusion wins. That makes two scheduled
        tasks able to divide the work between them: one that updates everything
        but Python daily, and one that updates only Python monthly, for a
        toolchain something else depends on being held steady.

    .PARAMETER UpdateSelfSource
        Where -UpdateSelf gets this module from. Default: Gallery.

          Gallery  the newest published release, through Update-Module
          Main     the development head, by fetching Install.ps1 from GitHub

        Gallery is the default because a published release is what most people
        want. Main is for tracking a fix that has landed but not shipped, and
        for testing.

        Gallery cannot move a copy that PowerShellGet did not install -- one put
        there by the GitHub installer, for instance. The run says so and names
        the way forward rather than failing.

    .PARAMETER LogRetentionDays
        Delete logs and settings.json backups in the log directory older than this
        many days. Default: 30. Set to 0 to keep everything.

    .OUTPUTS
        An object describing the run:

          Ran            $false when nothing was attempted, for example because
                         the session could not become Administrator
          Reason         why it did not run, when Ran is $false
          Elevated       whether the run had administrator rights
          Steps          one record per step, with Status, Seconds and Log
          OkCount, WarningCount, SkippedCount, FailedCount
          RebootPending  whether Windows is waiting on a restart
          RebootReason   what is holding the restart
          LogDirectory   where the logs went
          MainLog        the transcript for this run

        FailedCount is what a scheduled task turns into an exit code. Warning
        steps completed and do not count.

    .NOTES
        Elevation is checked before it is requested. A standard user gets a clear
        explanation and exit 64 rather than a UAC prompt that cannot succeed. Run
        with -SkipElevation to perform the steps that do not need admin.

        Execution policy: the elevated relaunch passes -ExecutionPolicy Bypass.
        Importing the module obeys whatever policy is in force, so on a machine
        set to AllSigned or Restricted, start the session with:
            pwsh -NoProfile -ExecutionPolicy Bypass -Command "Import-Module UpdateEverything; Update-Everything"
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Write-Host is the user interface of a console maintenance tool. Its output is progress a person watches, not data a caller consumes, and the summary uses colour to separate failures from noise.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Every action that changes the machine is already gated: -PromptBeforeRun offers a way out, -AllowInstall gates first-time installs, and each step reports what it did. A -WhatIf that ran nothing would duplicate -SkipElevation without adding safety.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [bool]   $IncludeWindowsUpdate   = $true,
        [bool]   $IncludePowerShell7     = $true,
        [bool]   $SetPwshTerminalDefault = $true,
        [bool]   $IncludePowerShellModules = $true,
        [switch] $AutoReboot,
        [switch] $IncludePrerelease,
        [switch] $UpdateGlobalNpm,
        [switch] $SkipElevation,
        [switch] $PromptBeforeRun,
        [ValidateRange(5, 3600)]
        [int]    $PromptTimeoutSeconds    = 60,
        [ValidateRange(1, 1440)]
        [int]    $DelayMinutes            = 60,
        [switch] $Notify,
        [ValidateSet('All', 'PowerShell7', 'PSWindowsUpdate', 'NuGetProvider', 'BurntToast', 'PowerShellGet', 'PSResourceGet')]
        [string[]] $AllowInstall = @(),
        [ValidateSet('Windows', 'Microsoft', 'PowerShell', 'PackageManager', 'Python', 'Node', 'DotNet', 'Rust', 'Git', 'Self', 'Inventory')]
        [string[]] $Tag = @(),
        [ValidateSet('Windows', 'Microsoft', 'PowerShell', 'PackageManager', 'Python', 'Node', 'DotNet', 'Rust', 'Git', 'Self', 'Inventory')]
        [string[]] $ExcludeTag = @(),
        [ValidateRange(0, 3650)]
        [int]    $LogRetentionDays       = 30,
        [switch] $UpdateSelf,
        [ValidateSet('Gallery', 'Main')]
        [string] $UpdateSelfSource = 'Gallery'
    )

    # State shared with the private helpers is assigned with $script:. Inside a
    # module a plain assignment is function-scoped, so Invoke-Step would read an
    # unset $script:logDir and fail on every step.
    #
    # No hardcoded TLS override: current Windows and PowerShell negotiate TLS
    # 1.2/1.3 on their own.
    $originalOutputEncoding = Initialize-ConsoleEncoding

    # ---------------------------------------------------------------------------
    # 1. Logging
    #
    # Set up before the elevation decision, not after it, so that every way this
    # run can decline to start -- a standard user, UAC switched off, a host that
    # cannot be elevated at all -- still leaves a log behind to read.
    # ---------------------------------------------------------------------------
    $script:logDir = Get-UpdateLogDirectory

    # One stamp shared by the transcript and every step log, so a single run's files
    # sort together and can be pruned as a unit.
    $script:runStamp = '{0:yyyyMMdd-HHmmss}' -f (Get-Date)
    $mainLog  = Join-Path $logDir "Update-Everything-$runStamp.log"

    # Asked before pruning and before the transcript is started, both of which
    # would otherwise answer it wrongly: pruning can empty the directory on a
    # machine that has simply not run in a while, and the transcript would find
    # its own log and conclude the run had happened before.
    $isFirstRun = -not @(Get-ChildItem -LiteralPath $logDir -Filter 'Update-Everything-*.log' `
        -File -ErrorAction SilentlyContinue).Count

    # Step logs rotate per run rather than being appended to forever, so old ones
    # (and stale Terminal settings backups) are pruned by age instead.
    if ($LogRetentionDays -gt 0) {
        $cutoff = (Get-Date).AddDays(-$LogRetentionDays)
        Get-ChildItem -LiteralPath $logDir -File -ErrorAction SilentlyContinue |
            Where-Object { ($_.Name -like '*.log' -or $_.Name -like '*.json.bak') -and $_.LastWriteTime -lt $cutoff } |
            Remove-Item -Force -ErrorAction SilentlyContinue
    }

    # A transcript is a nice-to-have, not a prerequisite: it fails if one is already
    # running or the path is not writable, and that must not kill the run.
    $transcriptRunning = $false
    try {
        Start-Transcript -Path $mainLog -Append -ErrorAction Stop | Out-Null
        $transcriptRunning = $true
    } catch {
        Write-Warning "Transcript unavailable ($($_.Exception.Message)); per-step logs are unaffected."
    }

    $script:isAdmin = Test-IsAdministrator
    if (-not $isAdmin -and -not $SkipElevation) {
        # Ask whether elevation is possible before asking for it. Without this the
        # script raises a UAC prompt a standard user can never satisfy, and reports
        # the refusal as though the user had declined it.
        $elevation = Test-ElevationCapability
        if (-not $elevation.CanElevate) {
            Write-Warning "Cannot run elevated: $($elevation.Reason)"
            Write-Warning 'Nothing has been changed. Re-run with -SkipElevation to run the steps that do not need administrator rights.'

            if ($transcriptRunning) { try { Stop-Transcript | Out-Null } catch { Write-Verbose "Transcript already stopped." } }
            try { [Console]::OutputEncoding = $originalOutputEncoding } catch { Write-Verbose "Could not restore the console encoding." }

            return (New-UpdateEverythingResult -Ran $false -Reason $elevation.Reason `
                -LogDirectory $logDir -MainLog $mainLog)
        }

        # Close the transcript before handing off, and reopen it afterwards to
        # record the outcome.
        #
        # The child computes its own run stamp and starts its own transcript.
        # Stamps have one-second resolution, so two starting in the same second
        # resolve to the same path, and two processes holding it open is not
        # benign: -Append reports success and the child's content is then lost.
        # A child needs long enough to start and import that the stamps differ in
        # practice, but not overlapping costs nothing and does not rely on that
        # margin holding on faster hardware.
        #
        # The note is written before the close, not after. If the elevated child
        # hangs, this transcript is all there is, and it has to name the log the
        # real work went to.
        $childNote = "Handing off to an elevated run. Its transcript is a separate Update-Everything-*.log in $logDir, stamped when it starts."
        Write-Host $childNote -ForegroundColor Yellow

        if ($transcriptRunning) {
            try { Stop-Transcript | Out-Null } catch { Write-Verbose "Transcript already stopped." }
            $transcriptRunning = $false
        }

        # A module function must not kill the session it was called from, so the
        # elevated child's outcome comes back as a result rather than an exit.
        $child = Invoke-SelfElevation -BoundParameters $PSBoundParameters

        try {
            Start-Transcript -Path $mainLog -Append -ErrorAction Stop | Out-Null
            $transcriptRunning = $true
        } catch {
            Write-Verbose "Could not reopen the transcript to record the elevated run's outcome."
        }
        Write-Host "Elevated run finished with exit code $child." -ForegroundColor Green

        if ($transcriptRunning) { try { Stop-Transcript | Out-Null } catch { Write-Verbose "Transcript already stopped." } }
        try { [Console]::OutputEncoding = $originalOutputEncoding } catch { Write-Verbose "Could not restore the console encoding." }

        return (New-UpdateEverythingResult -Ran $false -Elevated `
            -Reason "Re-ran elevated in a separate window, which finished with exit code $child." `
            -FailedCount ([int] $child) `
            -LogDirectory $logDir -MainLog $mainLog)
    }

    if (-not $isAdmin) {
        Write-Warning 'Running without administrator rights. Steps that require admin will be skipped and listed in the summary.'
    }

    # Offer a way out before anything is touched. This sits after the transcript
    # starts, so the decision is on record, and before the notification and
    # install checks, so skipping costs nothing.
    if ($PromptBeforeRun) {
        if (-not (Test-CanPrompt)) {
            # A hidden window or redirected input cannot answer. Starting anyway
            # beats blocking until the task's time limit kills the run.
            Write-Warning 'PromptBeforeRun was requested, but this run cannot prompt (no interactive console, or input is redirected). Starting immediately.'
        } else {
            switch (Request-RunDecision -TimeoutSeconds $PromptTimeoutSeconds -DelayMinutes $DelayMinutes) {
                'Skip' {
                    Write-Host 'Skipped at your request. Nothing was changed.' -ForegroundColor Yellow
                    if ($transcriptRunning) { try { Stop-Transcript | Out-Null } catch { Write-Verbose "Transcript already stopped." } }
                    try { [Console]::OutputEncoding = $originalOutputEncoding } catch { Write-Verbose "Could not restore the console encoding." }
                    # Ran $false, not a failure: the next scheduled run stands.
                    return (New-UpdateEverythingResult -Ran $false -Elevated:$isAdmin `
                        -Reason 'Skipped at the pre-run prompt.' -LogDirectory $logDir -MainLog $mainLog)
                }
                'Delay' {
                    Write-Host "Waiting ${DelayMinutes} minute(s) before starting. Close this window to cancel." -ForegroundColor Yellow
                    Start-Sleep -Seconds ($DelayMinutes * 60)
                    Write-Host 'Resuming.' -ForegroundColor Green
                }
            }
        }
    }

    # Answers to install prompts, remembered for the run so a component is asked
    # about at most once.
    $script:InstallDecision = @{}

    # Resolved before any work starts, so a missing prerequisite is reported at
    # the top of the transcript rather than after the run it was meant to report
    # on, and so BurntToast is installed before rather than afterwards.
    $script:NotificationsAvailable = $false
    $notificationStatus = $null
    if ($Notify) {
        $notificationStatus = Initialize-NotificationSupport -Approved $AllowInstall
        $script:NotificationsAvailable = $notificationStatus.Available
    }

    $script:Results = [System.Collections.Generic.List[object]]::new()

    # Read by Invoke-Step, which decides per step. Held at script scope for the
    # same reason as $script:isAdmin: a step action runs inside Invoke-Step, not
    # here.
    $script:TagFilter        = $Tag
    $script:ExcludeTagFilter = $ExcludeTag

    if ($Tag -or $ExcludeTag) {
        $selection = @()
        if ($Tag)        { $selection += "only $($Tag -join ', ')" }
        if ($ExcludeTag) { $selection += "excluding $($ExcludeTag -join ', ')" }
        Write-Host "Step selection: $($selection -join ', '). Everything else is reported as skipped." -ForegroundColor Cyan
    }

    # winget exit codes that mean "nothing to do" rather than "failed".
    #   0x8A15002B (-1978335189) APPINSTALLER_CLI_ERROR_UPDATE_NOT_APPLICABLE
    #   0x8A150014 (-1978335212) APPINSTALLER_CLI_ERROR_NO_APPLICATIONS_FOUND
    $WingetNothingToDo = @(-1978335189, -1978335212)

    # The version that produced this log. Nothing else in a run said it, so a
    # transcript could not be read against the code that made it -- a step that
    # failed two releases ago looked identical to one failing now.
    #
    # The running version, from the module executing this, not the highest
    # installed. A session imported by path, or one that loaded before an update
    # replaced the files, is running something else.
    $script:RunningVersion = $MyInvocation.MyCommand.Module.Version

    Write-Host "Maintenance run started $(Get-Date)  |  Admin: $isAdmin  |  Main Log: $mainLog" -ForegroundColor Green
    if ($script:RunningVersion) {
        Write-Host "UpdateEverything $script:RunningVersion" -ForegroundColor Green
    }

    # ---------------------------------------------------------------------------
    # 1a. What this machine actually has
    # ---------------------------------------------------------------------------
    Invoke-Step -Name 'Inventory' -Tag 'Inventory' -Action {
        $inventory = @(Get-UpdateToolInventory)
        $present = @($inventory | Where-Object Present)
        $absent = @($inventory | Where-Object { -not $_.Present })

        Write-Output "$($present.Count) of $($inventory.Count) tools present."
        Write-Output ''

        # Aligned by hand rather than with Format-Table. Inside a step action the
        # output has to reach the pipeline so Invoke-Step can capture it for the
        # step log, and Format-Table's records would only render correctly on
        # their way to a host -- which is the one place a step must not write.
        $nameWidth = 0
        $ownerWidth = 0
        foreach ($tool in $present) {
            if ($tool.Name.Length -gt $nameWidth) { $nameWidth = $tool.Name.Length }
            if ("$($tool.Owner)".Length -gt $ownerWidth) { $ownerWidth = "$($tool.Owner)".Length }
        }
        foreach ($tool in $present) {
            Write-Output ("  {0,-$nameWidth}  {1,-$ownerWidth}  {2}" -f $tool.Name, $tool.Owner, $tool.Version)
        }

        if ($absent.Count) {
            Write-Output ''
            Write-Output "Not installed: $(($absent.Name | Sort-Object) -join ', ')"
            Write-Output 'Their steps report Skipped, which is the expected result rather than a fault.'
        }

        # The module's own version, compared against the gallery. Here rather than
        # in the banner because it costs a network call: a scheduled run on a
        # machine with no network should not pay a timeout before it starts, and
        # -ExcludeTag Inventory already turns this off for one that does not want
        # it.
        if ($script:RunningVersion) {
            Write-Output ''
            Write-Output (Format-SelfVersionStatus -Running $script:RunningVersion `
                -Status (Get-GalleryModuleStatus -Name 'UpdateEverything'))
        }

        # More than one executable of a name on PATH means the version above is
        # the one that runs and the others are updated by nobody. It is also how
        # a tool ends up updated by a manager that does not own the copy in use.
        $duplicated = @($present | Where-Object { $_.Copies -gt 1 })
        if ($duplicated.Count) {
            Write-Output ''
            foreach ($tool in $duplicated) {
                Write-Warning "$($tool.Name) is installed in $($tool.Copies) places; the first is the one that runs: $($tool.Places -join '; ')"
            }
        }
    }

    # ---------------------------------------------------------------------------
    # 1b. The module itself
    # ---------------------------------------------------------------------------
    if ($UpdateSelf) {
        Invoke-Step -Name 'UpdateEverything (self)' -Tag 'Self' -Action {
            if ($UpdateSelfSource -eq 'Gallery') {
                $status = Get-GalleryModuleStatus -Name 'UpdateEverything'

                if (-not $status.Available) {
                    Write-Output "UpdateEverything $($status.Installed) is installed; the gallery could not be asked about it."
                } elseif (-not $status.Updatable) {
                    # A copy the GitHub installer put there was not installed by
                    # PowerShellGet, so Update-Module refuses it. That is not a
                    # fault, and -UpdateSelfSource Main is the matching path.
                    Write-Output "UpdateEverything $($status.Installed) was not installed from the gallery, so Update-Module cannot move it. The published version is $($status.Available)."
                    Write-Output 'Use -UpdateSelfSource Main to track the branch it came from, or Install-Module UpdateEverything -Force to switch to the gallery copy.'
                } elseif (-not $status.NeedsUpdate) {
                    Write-Output "UpdateEverything $($status.Installed) is the newest published release."
                } else {
                    Write-Output "UpdateEverything $($status.Installed) -> $($status.Available)..."
                    Update-Module -Name 'UpdateEverything' -Force -Confirm:$false -ErrorAction Stop
                    Write-Output 'Updated. The new version loads on the next run; this one continues on the code already in memory.'
                }
                return
            }

            # Main. Reinstalls whether or not the version differs, because the
            # module version does not move with every commit: "already 1.0.0" is
            # the normal state of an out-of-date working copy, so a version
            # check cannot decide whether a reinstall is needed.
            $uri = 'https://raw.githubusercontent.com/briankronberg/UpdateEverything/main/Install.ps1'
            $installer = Join-Path ([System.IO.Path]::GetTempPath()) "Install-UpdateEverything-$script:runStamp.ps1"

            try {
                Write-Output "Fetching the installer from $uri"
                Invoke-WebRequest -Uri $uri -OutFile $installer -UseBasicParsing -ErrorAction Stop
                Unblock-File -LiteralPath $installer -ErrorAction SilentlyContinue

                # In a child process, and powershell rather than the current
                # host: the installer imports the module when it finishes, which
                # inside this session would re-import a module whose files have
                # just been replaced under it. powershell.exe is also always
                # present, which pwsh is not.
                & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $installer -Force
                if ($LASTEXITCODE -ne 0) {
                    throw "The installer exited with code $LASTEXITCODE."
                }

                # Unlike winget, which is a fresh process every step, this module
                # is already loaded: the functions running now stay on the code
                # in memory however new the files on disk are.
                Write-Output 'Updated. The new version loads on the next run; this one continues on the code already in memory.'
            } finally {
                Remove-Item -LiteralPath $installer -Force -ErrorAction SilentlyContinue
            }
        }
    } else {
        Add-SkippedStep -Name 'UpdateEverything (self)' -Reason 'not requested (-UpdateSelf)'
    }

    # ---------------------------------------------------------------------------
    # 2. winget (apps from winget + Microsoft Store sources)
    # ---------------------------------------------------------------------------
    Invoke-Step -Name 'winget self-update' -RequiresCommand 'winget' -Tag 'Windows', 'PackageManager' -Action {
        # Refresh the source indexes first. A stale index makes 'upgrade --all'
        # quietly miss packages rather than fail loudly, so this is not just hygiene.
        winget source update --disable-interactivity
        if ($LASTEXITCODE -ne 0) {
            Write-Output "winget source update returned $LASTEXITCODE; continuing (a stale index is not fatal)."
            $global:LASTEXITCODE = 0
        }

        # 'upgrade --all' does not reliably update App Installer (winget itself),
        # so ask for it by ID.
        winget upgrade --id Microsoft.AppInstaller --exact --source winget --silent `
            --accept-source-agreements --accept-package-agreements --disable-interactivity
        if ($WingetNothingToDo -contains $LASTEXITCODE) {
            Write-Output 'App Installer (winget) is already at the latest version.'
            $global:LASTEXITCODE = 0
        }
    }

    Invoke-Step -Name 'winget (all sources)' -RequiresCommand 'winget' -Tag 'Windows', 'PackageManager' -Action {
        # Accumulated and passed through in one pass, rather than captured and
        # echoed afterwards. A winget upgrade can run for minutes and the console
        # should show it happening.
        #
        # The upgrade table winget prints first is the "before" list, so no extra
        # call is needed for it.
        $captured = [System.Collections.Generic.List[string]]::new()

        winget upgrade --all --include-unknown --silent `
            --accept-source-agreements --accept-package-agreements --disable-interactivity 2>&1 |
            ForEach-Object { $captured.Add("$_"); $_ }

        $code = $LASTEXITCODE
        $global:LASTEXITCODE = 0

        # 'upgrade --all' returns non-zero for entirely routine reasons: nothing
        # applicable, or a subset of packages (pinned, Store-sourced, or currently
        # running) failing while the rest upgrade fine. Report the code instead of
        # failing the run over it; Write-Error marks the step 'Warning'.
        if ($code -ne 0 -and $WingetNothingToDo -notcontains $code) {

            # Which ones, and whether anything can be done about them. The exit
            # code says only that something did not upgrade, and a person then
            # has to read the step log to find out what -- or, as happened,
            # notice across two runs that one package never moves.
            $text = $captured -join "`n"
            $before = @(Get-WingetUpgradeTable -Text $text)
            $after = @(Get-WingetUpgradeTable -Text (
                winget upgrade --include-unknown --disable-interactivity 2>&1 | Out-String))
            $global:LASTEXITCODE = 0

            $leftover = @(Get-WingetLeftover -Before $before -After $after -Output $text)

            $attempted = @($leftover | Where-Object { $_.Attempted })
            $skipped = @($leftover | Where-Object { -not $_.Attempted })

            if ($attempted.Count) {
                Write-Output ''
                Write-Output 'Still out of date after this run:'
                foreach ($package in $attempted) {
                    Write-Output ("  {0} {1} -> {2}  ({3})" -f $package.Id, $package.Version, $package.Available, $package.Reason)
                }
            }

            # Written as information rather than as a problem. These do not
            # change until the vendor ships something that applies, so a person
            # who reads them as failures learns to skim past the ones that are.
            if ($skipped.Count) {
                Write-Output ''
                Write-Output 'Not upgradable on this machine, and expected to stay that way:'
                foreach ($package in $skipped) {
                    Write-Output ("  {0} {1} -> {2}  ({3})" -f $package.Id, $package.Version, $package.Available, $package.Reason)
                }
            }

            # The error, and so the Warning status, is raised only for something
            # that was actually tried. A package winget declined is not a fault
            # of this run and must not colour it.
            if ($attempted.Count) {
                Write-Error ('winget could not upgrade {0} package(s): {1}. Exit code {2} (0x{2:X8}).' -f
                    $attempted.Count, (($attempted.Id) -join ', '), $code)
            } elseif (-not $leftover.Count) {
                Write-Error ('winget upgrade --all returned {0} (0x{0:X8}); one or more packages may not have upgraded.' -f $code)
            } else {
                Write-Output ''
                Write-Output 'Nothing this run could have upgraded was left behind.'
            }
        } elseif ($code -ne 0) {
            Write-Output 'winget reports nothing left to upgrade.'
        }
    }

    # ---------------------------------------------------------------------------
    # A manager runs before the tools it may own. Chocolatey and Scoop install
    # language toolchains, so updating uv or npm first and the manager that owns
    # it second updates a tool and then the thing responsible for it. The
    # toolchain steps ask Get-ToolInstallSource before self-updating, so this is
    # sequence rather than a live conflict -- but the sequence should read the
    # way the dependency runs.
    # ---------------------------------------------------------------------------
    # 2b. Chocolatey and Scoop, before the toolchains they may own
    # ---------------------------------------------------------------------------
    # 1641 and 3010 are the MSI "reboot initiated" / "reboot required" codes, which
    # Chocolatey passes straight through on an otherwise successful upgrade.
    Invoke-Step -Name 'Chocolatey' -RequiresCommand 'choco' -AllowedExitCodes 1641, 3010 -Tag 'PackageManager' -Action {
        choco upgrade all -y
    }

    Invoke-Step -Name 'Scoop' -RequiresCommand 'scoop' -Tag 'PackageManager' -Action {
        # Run the three phases independently: a failure in one (a broken bucket, an
        # app that will not clean up) should not hide the others.
        $phases = @(
            @{ Label = 'scoop update (scoop itself + buckets)'; Args = @('update') },
            @{ Label = 'scoop update * (installed apps)';       Args = @('update', '*') },
            @{ Label = 'scoop cleanup * (old versions)';        Args = @('cleanup', '*') }
        )
        foreach ($phase in $phases) {
            Write-Output "-> $($phase.Label)"
            $phaseArgs = $phase.Args
            & scoop @phaseArgs
            if ($LASTEXITCODE -ne 0) {
                Write-Warning "$($phase.Label) returned $LASTEXITCODE; continuing with the next phase."
                $global:LASTEXITCODE = 0
            }
        }
    }

    # ---------------------------------------------------------------------------
    # 2c. PowerShell 7 (install if missing, else upgrade to the latest release)
    # ---------------------------------------------------------------------------
    if ($IncludePowerShell7) {
        Invoke-Step -Name 'PowerShell 7 (latest)' -RequiresCommand 'winget' -RequiresAdmin -Tag 'PowerShell', 'Windows' -Action {
            $id  = 'Microsoft.PowerShell'
            $exe = Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe'

            # Decide by exit code, not by matching text: winget localises its output
            # and truncates the Id column to the console width, so a string match
            # gives false negatives in a narrow window. 0 = found.
            winget list --id $id --exact --accept-source-agreements --disable-interactivity
            $isInstalled = ($LASTEXITCODE -eq 0)
            $global:LASTEXITCODE = 0

            # Second opinion: the MSI drops pwsh.exe here whatever winget believes.
            if (-not $isInstalled -and (Test-Path -LiteralPath $exe)) {
                Write-Output 'winget does not list PowerShell 7, but pwsh.exe is present; treating as installed.'
                $isInstalled = $true
            }

            if (-not $isInstalled) {
                if (-not (Approve-Install -Component 'PowerShell7' -Approved $AllowInstall `
                        -Description 'PowerShell 7 is not installed. This would install it machine-wide via winget (MSI package, into C:\Program Files\PowerShell\7).')) {
                    Stop-StepAsSkipped -Reason 'installing PowerShell 7 was not approved'
                }

                Write-Output 'PowerShell 7 not detected; installing the MSI package via winget...'
                # --installer-type wix forces the MSI (winget 7.6+ defaults to MSIX) so it
                # installs to C:\Program Files\PowerShell\7 where Terminal expects it.
                winget install --id $id --exact --source winget --installer-type wix `
                    --accept-source-agreements --accept-package-agreements --disable-interactivity
                if ($LASTEXITCODE -ne 0) { throw "winget install returned $LASTEXITCODE" }
            } else {
                Write-Output 'PowerShell 7 present; checking for an upgrade...'
                winget upgrade --id $id --exact --include-unknown `
                    --accept-source-agreements --accept-package-agreements --disable-interactivity
                if ($WingetNothingToDo -contains $LASTEXITCODE) {
                    Write-Output 'PowerShell 7 is already at the latest version.'
                    $global:LASTEXITCODE = 0
                } elseif ($LASTEXITCODE -ne 0) {
                    throw "winget upgrade returned $LASTEXITCODE"
                }
            }

            if (Test-Path -LiteralPath $exe) {
                $reported = & $exe -NoProfile -Command '$PSVersionTable.PSVersion.ToString()'
                if ($LASTEXITCODE -ne 0) { $global:LASTEXITCODE = 0 }
                Write-Output "Installed pwsh version: $reported"
            } else {
                # The install branch forces --installer-type wix, but the upgrade
                # branch cannot convert a PowerShell that is already packaged, so
                # say what it costs and how to switch. An MSIX pwsh works fine for
                # everything except elevating and being named in a scheduled task,
                # which are two things this module needs.
                Write-Output "Note: $exe not found, so PowerShell 7 here is the MSIX package. It runs normally, but Windows will not elevate it and its path changes at every update, so scheduled tasks cannot rely on it."
                Write-Output 'To switch: winget install --id Microsoft.PowerShell --exact --source winget --installer-type wix'
            }
        }
    } else {
        Add-SkippedStep -Name 'PowerShell 7 (latest)'
    }

    # ---------------------------------------------------------------------------
    # 2d. Microsoft 365 Apps (click-to-run)
    # ---------------------------------------------------------------------------
    Invoke-Step -Name 'Microsoft 365 Apps' -Tag 'Microsoft' -Action {
        $roots = @($env:ProgramFiles, ${env:ProgramFiles(x86)}) | Where-Object { $_ }
        # Indexed rather than "| Select-Object -First 1": that stops the upstream
        # pipeline, and inside a step -- where every stream is merged with *>&1 --
        # the transcript records the stop as 'TerminatingError(): "The pipeline has
        # been stopped."'. Nothing is wrong, but it reads as though something is.
        $found = @($roots |
            ForEach-Object { Join-Path $_ 'Common Files\Microsoft Shared\ClickToRun\OfficeC2RClient.exe' } |
            Where-Object { Test-Path -LiteralPath $_ })
        $c2r = if ($found.Count) { $found[0] } else { $null }

        if (-not $c2r) {
            Stop-StepAsSkipped -Reason 'OfficeC2RClient.exe is not present, so there is no click-to-run Office install'
        }

        # The same action as the "Update Now" button, minus the prompts. C2R hands
        # the work to its background service and returns immediately, so exit 0 here
        # means "update requested", not "update applied".
        & $c2r /update user updatepromptuser=false displaylevel=false
        if ($LASTEXITCODE -ne 0) {
            Write-Output "OfficeC2RClient returned $LASTEXITCODE; the update request may not have been accepted."
            $global:LASTEXITCODE = 0
        }
        Write-Output "Requested a Microsoft 365 Apps update via $c2r (applied in the background)."
    }

    # ---------------------------------------------------------------------------
    # 3. PowerShell repository trust, modules + help
    # ---------------------------------------------------------------------------
    # PSGallery ships as "Untrusted", so every module install/update stops on the
    # "You are installing the modules from an untrusted repository" prompt.
    # -ErrorAction SilentlyContinue does NOT suppress that: it is a confirmation
    # prompt, not an error. Trust is stored per-user under LOCALAPPDATA, and UAC
    # elevation keeps the same user profile, so setting it once here sticks for
    # both the elevated and the non-elevated run.
    Invoke-Step -Name 'Trust PSGallery' -Tag 'PowerShell' -Action {
        # PowerShellGet v2 pulls the NuGet provider on first use and prompts for it.
        if (-not (Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue)) {
            if (-not (Approve-Install -Component 'NuGetProvider' -Approved $AllowInstall `
                    -Description 'The NuGet package provider is missing. PowerShellGet needs it to reach the PowerShell Gallery. This would install it for the current user only.')) {
                Stop-StepAsSkipped -Reason 'installing the NuGet provider was not approved'
            }

            Write-Output 'Bootstrapping NuGet package provider...'
            $null = Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 `
                -Force -Scope CurrentUser -ErrorAction Stop
        }

        # PSResourceGet (v3) - backs Update-PSResource below
        if (Get-Command Set-PSResourceRepository -ErrorAction SilentlyContinue) {
            $repo = Get-PSResourceRepository -Name PSGallery -ErrorAction SilentlyContinue
            if (-not $repo) {
                Register-PSResourceRepository -PSGallery -Trusted -ErrorAction Stop
                Write-Output 'Registered PSGallery (PSResourceGet) as Trusted.'
            } elseif (-not $repo.Trusted) {
                Set-PSResourceRepository -Name PSGallery -Trusted -Confirm:$false -ErrorAction Stop
                Write-Output 'PSGallery (PSResourceGet) set to Trusted.'
            } else {
                Write-Output 'PSGallery (PSResourceGet) already Trusted.'
            }
        }

        # PowerShellGet (v2) - backs Update-Module and Install-Module PSWindowsUpdate
        if (Get-Command Set-PSRepository -ErrorAction SilentlyContinue) {
            $repo2 = Get-PSRepository -Name PSGallery -ErrorAction SilentlyContinue
            if ($repo2 -and $repo2.InstallationPolicy -ne 'Trusted') {
                Set-PSRepository -Name PSGallery -InstallationPolicy Trusted -ErrorAction Stop
                Write-Output 'PSGallery (PowerShellGet v2) set to Trusted.'
            } else {
                Write-Output 'PSGallery (PowerShellGet v2) already Trusted.'
            }
        }

        # This step sets trust and stops there. Moving PowerShellGet itself
        # forward belongs to the Gallery tooling step below, which handles the
        # 1.0.0.1 Windows ships as one case of a general rule rather than as a
        # version comparison of its own.
    }

    # The tooling every other gallery step runs on. It is bootstrapped above when
    # missing, but nothing until now brought it forward once present, so a
    # machine could carry a years-old NuGet provider or a PowerShellGet 2.1 for
    # as long as it lived. This runs before 'PowerShell modules' because that
    # step is one of the things that depends on it.
    Invoke-Step -Name 'Gallery tooling' -Tag 'PowerShell' -Action {
        # Not admin-gated, and -Scope AllUsers fails without elevation, so the
        # scope follows what the run actually has.
        $scope = if ($isAdmin) { 'AllUsers' } else { 'CurrentUser' }

        # --- NuGet package provider ------------------------------------------
        #
        # There is no Update-PackageProvider; Install-PackageProvider is the only
        # way to move one forward. That makes the refresh an install command
        # fetching a binary provider assembly, so it asks under the same
        # 'NuGetProvider' component as the bootstrap rather than proceeding on
        # the grounds that something is already there. Declining is not fatal:
        # the provider that is present keeps working.
        $nuget = @(Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue |
            Sort-Object Version -Descending)
        if (-not $nuget.Count) {
            Write-Output 'No NuGet package provider is present; the Trust PSGallery step reports why.'
        } else {
            $current = $nuget[0].Version

            # SilentlyContinue and a check, not Stop and a catch. PowerShell 7
            # registers no provider bootstrap source, so this cannot be answered
            # there at all -- the normal, healthy case on half the supported
            # hosts. Start-Transcript records a terminating error whether or not
            # it is caught, so throwing for the expected answer puts
            # "TerminatingError(Find-PackageProvider)" in the middle of a step
            # that went on to report the right thing.
            #
            # Test-PendingReboot carries the same lesson about Get-ItemProperty.
            $newest = $null
            try {
                $candidates = @(Find-PackageProvider -Name NuGet -ErrorAction SilentlyContinue |
                    Sort-Object Version -Descending)
                if ($candidates.Count) { $newest = $candidates[0].Version }
            } catch {
                # A backstop for a hard failure. The ordinary answer no longer
                # throws, which is the point.
                Write-Verbose "Asking for the newest NuGet provider failed outright: $($_.Exception.Message)"
            }

            if (-not $newest) {
                # Not the same as up to date, and must not read like it.
                Write-Output "NuGet package provider $current is installed; no newer version could be looked up on this host."
            } elseif ($newest -gt $current) {
                if (Approve-Install -Component 'NuGetProvider' -Approved $AllowInstall `
                        -Description "The NuGet package provider is at $current and $newest is available. There is no update command for a provider, so this would install the newer one $(if ($isAdmin) { 'for all users on this machine' } else { 'for the current user only' }).") {
                    $null = Install-PackageProvider -Name NuGet -Force -Scope $scope -ErrorAction Stop
                    Write-Output "NuGet package provider $current -> $newest."
                }
            } else {
                Write-Output "NuGet package provider $current is current."
            }
        }

        # --- PowerShellGet and PSResourceGet ---------------------------------
        #
        # Three cases, and they are not the same decision:
        #
        #   absent                  an install, and asks
        #   present but not ours    a copy the host shipped. Update-Module
        #                           refuses it, so moving it forward is a
        #                           side-by-side install, and asks
        #   present and ours        an update, and does not ask
        #
        # The middle case is why the version alone is not the test. Windows
        # PowerShell ships PowerShellGet 1.0.0.1 under Program Files rather than
        # $PSHOME, and Update-Module answers "Module 'PowerShellGet' was not
        # installed by using Install-Module, so it cannot be updated".
        foreach ($tool in @(
                @{ Module = 'PowerShellGet';                      Component = 'PowerShellGet' }
                @{ Module = 'Microsoft.PowerShell.PSResourceGet'; Component = 'PSResourceGet' }
            )) {
            $name = $tool.Module
            $status = Get-GalleryModuleStatus -Name $name

            if (-not $status.Available) {
                $known = if ($status.Installed) { "$name $($status.Installed) is installed" } else { "$name is not installed" }
                Write-Output "$known; the gallery could not be asked about it."
                continue
            }

            if ($status.Installed -and $status.Updatable -and -not $status.NeedsUpdate) {
                Write-Output "$name $($status.Installed) is current."
                continue
            }

            if ($status.Installed -and $status.Updatable) {
                Write-Output "$name $($status.Installed) -> $($status.Available)..."
                if (Get-Command Update-PSResource -ErrorAction SilentlyContinue) {
                    Update-PSResource -Name $name -TrustRepository -Confirm:$false -ErrorAction Stop
                } else {
                    Update-Module -Name $name -Force -Confirm:$false -ErrorAction Stop
                }

                # The same trap as -UpdateSelf: the module is already loaded, so
                # the files on disk are replaced and the cmdlets running now stay
                # on the code in memory.
                Write-Output "$name updated. It loads in the next session; this run continues on the version already in memory."
                continue
            }

            # Nothing left but an install: either absent, or a shipped copy that
            # can only be replaced side by side.
            if ($status.Installed -and $status.Installed -ge $status.Available) {
                Write-Output "$name $($status.Installed) shipped with this host and is not behind the gallery; leaving it alone."
                continue
            }

            $what = if ($status.Installed) {
                "$name $($status.Installed) is the copy this PowerShell shipped with, which cannot be updated in place. Installing $($status.Available) alongside it is the only way forward"
            } else {
                "$name is not installed. It is the current PowerShell Gallery client, and installing it changes which client every later module update uses. This would install $($status.Available)"
            }

            if (Approve-Install -Component $tool.Component -Approved $AllowInstall `
                    -Description "$what $(if ($isAdmin) { 'for all users on this machine' } else { 'for the current user only' }).") {

                Install-Module -Name $name -Force -AllowClobber -Scope $scope `
                    -Confirm:$false -ErrorAction Stop
                Write-Output "Installed $name $($status.Available) ($scope). It loads in the next session."
            }
        }
    }

    if (-not $IncludePowerShellModules) {
        Add-SkippedStep -Name 'PowerShell modules'
    } else {
    Invoke-Step -Name 'PowerShell modules' -Tag 'PowerShell' -Action {
        # Both update commands are silent on success, so the step reported OK and
        # a duration and nothing else. Taken either side of the pass, this says
        # what actually moved.
        $before = Get-ModuleVersionMap

        if (Get-Command Update-PSResource -ErrorAction SilentlyContinue) {
            # -TrustRepository suppresses the prompt for this call even when the
            # Trust PSGallery step could not persist the setting.
            $p = @{
                Name            = '*'
                TrustRepository = $true
                AcceptLicense   = $true
                Confirm         = $false
                ErrorAction     = 'SilentlyContinue'
            }
            if ($IncludePrerelease) { $p.Prerelease = $true }
            Update-PSResource @p
        } elseif (Get-Command Update-Module -ErrorAction SilentlyContinue) {
            $p = @{
                Force       = $true
                Confirm     = $false
                ErrorAction = 'SilentlyContinue'
            }

            # PowerShellGet 1.0.0.1 -- the version Windows PowerShell ships -- has
            # no -AcceptLicense, and splatting a parameter that does not exist is
            # a terminating error, which would fail this step outright on 5.1.
            if (Test-ParameterSupport -Command 'Update-Module' -Parameter 'AcceptLicense') {
                $p.AcceptLicense = $true
            } else {
                Write-Output 'PowerShellGet on this host predates -AcceptLicense; continuing without it. A module that requires accepting a license will be skipped rather than prompt.'
            }

            if ($IncludePrerelease) { $p.AllowPrerelease = $true }
            Update-Module @p
        } else {
            Write-Output 'No PowerShellGet/PSResourceGet available; skipping.'
            return
        }

        $after = Get-ModuleVersionMap

        $moved = foreach ($name in ($after.Keys | Sort-Object)) {
            if (-not $before.ContainsKey($name)) {
                "  {0} {1} (new)" -f $name, $after[$name]
            } elseif ($after[$name] -gt $before[$name]) {
                "  {0} {1} -> {2}" -f $name, $before[$name], $after[$name]
            }
        }

        $moved = @($moved)
        if ($moved.Count) {
            Write-Output ''
            Write-Output "$($moved.Count) module(s) updated:"
            $moved | ForEach-Object { Write-Output $_ }
        } else {
            Write-Output "No modules needed updating. $($after.Count) installed."
        }
    }
    }

    Invoke-Step -Name 'PowerShell help' -Tag 'PowerShell' -Action {
        $helpParams = @{ Force = $true; ErrorAction = 'SilentlyContinue' }

        # -Scope only exists on PS 6+; AllUsers writes under $PSHOME and needs admin.
        if ((Get-Command Update-Help).Parameters.ContainsKey('Scope')) {
            $helpParams.Scope = if ($isAdmin) { 'AllUsers' } else { 'CurrentUser' }
        }
        # Most modules only publish en-US help; pinning the culture avoids a wall of
        # "unable to retrieve the HelpInfo XML" errors under any other UI culture.
        if ((Get-UICulture).Name -ne 'en-US') { $helpParams.UICulture = 'en-US' }

        Update-Help @helpParams
    }

    # ---------------------------------------------------------------------------
    # 4. Python toolchain
    # ---------------------------------------------------------------------------
    Invoke-Step -Name 'Python (Install Manager)' -Tag 'Python' -Action {
        # Reported as skipped rather than OK. A step that did nothing because
        # the tool is absent is not the same as a step that updated something,
        # and the summary should not read as though Python were handled.
        if     (Get-Command pymanager -ErrorAction SilentlyContinue) { pymanager install --update }
        elseif (Get-Command py        -ErrorAction SilentlyContinue) { py install --update }
        else   { Stop-StepAsSkipped -Reason 'the Python Install Manager is not installed' }
    }

    Invoke-Step -Name 'uv' -RequiresCommand 'uv' -Tag 'Python' -Action {
        # Self-update only what nothing else is managing. Running "uv self
        # update" against a uv that scoop or winget installed fights whichever
        # one owns it, and that manager's own step will update it anyway.
        $owner = Get-ToolInstallSource -Name 'uv'
        if ($owner -notin 'Standalone', 'Unknown') {
            Stop-StepAsSkipped -Reason "uv is managed by $owner, which updates it in its own step"
        }

        $output = uv self update 2>&1
        $output

        if ($LASTEXITCODE -ne 0) {
            # uv refuses to self-update when a package manager owns it, and says
            # so in its output. That is correct behaviour rather than a failed
            # run. Any other non-zero exit is reported as a real failure.
            if (($output | Out-String) -match 'package manager|self-update.*(disabled|unavailable)') {
                Write-Output 'uv declined to self-update because something else manages it.'
                $global:LASTEXITCODE = 0
            } else {
                Write-Error "uv self update failed with exit code $LASTEXITCODE. uv's own message is in this step's log."
                $global:LASTEXITCODE = 0
            }
        }
    }

    Invoke-Step -Name 'pip' -Tag 'Python' -Action {
        # Never inside an active virtual environment. Its packages belong to
        # whatever project made it, not to this machine, and it is both the
        # easiest interpreter to reach from here and the worst one to change.
        if ($env:VIRTUAL_ENV) {
            Stop-StepAsSkipped -Reason "a virtual environment is active ($env:VIRTUAL_ENV), and its packages belong to that project rather than to this machine"
        }

        # Indexed rather than "| Select-Object -First 1": that halts the upstream
        # pipeline, and inside a step action the transcript records the stop as a
        # TerminatingError.
        $found = @('py', 'python' | ForEach-Object {
            Get-Command $_ -CommandType Application -ErrorAction SilentlyContinue
        })
        if (-not $found.Count) {
            Stop-StepAsSkipped -Reason 'no Python interpreter is on PATH'
        }
        $interpreter = $found[0].Source

        $version = (& $interpreter -m pip --version 2>&1 | Out-String).Trim()
        $global:LASTEXITCODE = 0
        if (-not $version -or $version -notmatch '^pip\s') {
            Stop-StepAsSkipped -Reason "pip is not available to $interpreter"
        }
        Write-Output $version

        # python -m pip, never the bare pip.exe. On Windows pip cannot replace
        # its own running executable, so "pip install --upgrade pip" fails on a
        # locked file; run through the interpreter and the exe is not running.
        & $interpreter -m pip install --upgrade pip --disable-pip-version-check
        if ($LASTEXITCODE -ne 0) {
            Write-Error "Could not upgrade pip for $interpreter (exit $LASTEXITCODE). pip's own message is in this step's log."
            $global:LASTEXITCODE = 0
        } else {
            Write-Output ((& $interpreter -m pip --version 2>&1 | Out-String).Trim())
            $global:LASTEXITCODE = 0
        }

        # Only this interpreter's pip. The others are named rather than touched:
        # upgrading pip in every Python on a machine is a larger claim than a
        # maintenance run should make on its own.
        $others = @(py --list 2>&1 | Out-String -Stream | Where-Object { $_ -match '^\s*-V:' -and $_ -notmatch '\*' })
        $global:LASTEXITCODE = 0
        if ($others.Count) {
            Write-Output ''
            Write-Output "$($others.Count) other interpreter(s) are installed and were not changed:"
            $others | ForEach-Object { Write-Output "  $($_.Trim())" }
        }

        # Installed packages are deliberately left alone. pip has no upgrade-all,
        # and list-outdated-then-upgrade-each does not keep the dependency set
        # consistent -- upgrading one package can silently downgrade another's
        # dependency. That is the problem pipx and uv exist to avoid, and both
        # have their own steps.
    }

    Invoke-Step -Name 'pipx packages' -RequiresCommand 'pipx' -Tag 'Python' -Action {
        pipx upgrade-all
    }

    # ---------------------------------------------------------------------------
    # 5. Node / npm
    # ---------------------------------------------------------------------------
    Invoke-Step -Name 'npm' -RequiresCommand 'npm' -Tag 'Node' -Action {
        # npm writes progress and deprecation notices to stderr as a matter of course,
        # so judge it by exit code only.
        # Output is captured as well as passed through, because the reason npm failed
        # is usually in it.
        $npmOutput = npm install -g npm@latest 2>&1
        $npmOutput
        if ($LASTEXITCODE -ne 0) {
            $npmText = $npmOutput | Out-String

            # EBADENGINE means the newest npm does not support the installed Node,
            # which is a fact about this machine rather than a fault in the
            # update. Reported in full, because the bare exit code does not say
            # which of the two it is.
            if ($npmText -match 'EBADENGINE') {
                $nodeVersion = try { node --version 2>$null } catch { 'unknown' }
                Write-Error ("npm could not update itself: the latest npm does not support the installed Node.js ($nodeVersion). " +
                    'npm reported EBADENGINE and left the existing npm in place, so nothing is broken. ' +
                    'Moving to a Node.js version npm supports (an LTS release) clears this.')
            } else {
                Write-Error "npm self-update failed with exit code $LASTEXITCODE. npm's own message is in this step's log."
            }
            $global:LASTEXITCODE = 0
        }

        if ($UpdateGlobalNpm) {
            npm update -g
            if ($LASTEXITCODE -ne 0) {
                Write-Error "npm update -g failed with exit code $LASTEXITCODE."
                $global:LASTEXITCODE = 0
            }
        } else {
            Write-Output 'Skipping global package upgrade (use -UpdateGlobalNpm to enable).'
        }
    }

    # ---------------------------------------------------------------------------
    # 6. .NET global tools
    # ---------------------------------------------------------------------------
    Invoke-Step -Name '.NET global tools' -RequiresCommand 'dotnet' -Tag 'DotNet' -Action {
        # 'dotnet' exists for runtime-only installs too, and 'dotnet --version' fails
        # outright when there is no SDK or when a global.json pins a missing one.
        # Validate the string before casting it to an int.
        $verRaw = (@(dotnet --version 2>&1)[0] | Out-String).Trim()
        $verOk  = ($LASTEXITCODE -eq 0)
        $global:LASTEXITCODE = 0

        # Evaluate the match on its own: with a short-circuited -or, $Matches could
        # still be holding results from an earlier, unrelated match.
        if (-not $verOk) {
            Write-Output "'dotnet --version' failed ('$verRaw'); no usable SDK, skipping global tools."
            return
        }
        if ($verRaw -notmatch '^(\d+)\.') {
            Write-Output "Could not parse an SDK version from '$verRaw'; skipping global tools."
            return
        }

        $major = [int]$Matches[1]
        if ($major -lt 6) {
            Write-Output ".NET global tool update skipped (SDK $verRaw; requires 6 or higher)."
            return
        }

        dotnet tool update --all --global
        if ($LASTEXITCODE -ne 0) {
            # '--all' is not accepted by every SDK that reports 6+. Fall back to
            # enumerating the installed tools and updating them one at a time.
            $global:LASTEXITCODE = 0
            Write-Output "'dotnet tool update --all' was rejected; updating tools individually."

            $tools = @(dotnet tool list --global |
                Select-Object -Skip 2 |
                ForEach-Object { ($_ -split '\s+')[0] } |
                Where-Object { $_ -and $_ -notmatch '^-+$' })
            $global:LASTEXITCODE = 0

            if (-not $tools) {
                Write-Output 'No global .NET tools installed.'
                return
            }
            foreach ($tool in $tools) {
                dotnet tool update --global $tool
                if ($LASTEXITCODE -ne 0) {
                    Write-Warning "Could not update $tool (exit $LASTEXITCODE)."
                    $global:LASTEXITCODE = 0
                }
            }
        }
    }

    Invoke-Step -Name '.NET workloads' -RequiresCommand 'dotnet' -Tag 'DotNet' -Action {
        # No-ops cleanly ("No workloads to update") when none are installed, but a
        # runtime-only install has no workload command at all.
        dotnet workload update
        if ($LASTEXITCODE -ne 0) {
            Write-Output "dotnet workload update returned $LASTEXITCODE (no SDK, or no workloads to update)."
            $global:LASTEXITCODE = 0
        }
    }

    # ---------------------------------------------------------------------------
    # 7. Self-updating tools
    # ---------------------------------------------------------------------------
    Invoke-Step -Name 'rustup' -RequiresCommand 'rustup' -Tag 'Rust' -Action {
        rustup update
    }

    Invoke-Step -Name 'GitHub CLI extensions' -RequiresCommand 'gh' -Tag 'Git' -Action {
        # 'gh extension upgrade --all' exits non-zero when nothing is installed,
        # which would otherwise fail the step. Check before calling it.
        $installed = (gh extension list 2>&1 | Out-String).Trim()
        $global:LASTEXITCODE = 0
        if (-not $installed) {
            Write-Output 'No gh extensions installed; nothing to upgrade.'
            return
        }
        gh extension upgrade --all
    }

    # ---------------------------------------------------------------------------
    # 8. WSL kernel
    # ---------------------------------------------------------------------------
    Invoke-Step -Name 'WSL kernel' -RequiresCommand 'wsl' -Tag 'Windows' -Action {
        # wsl.exe ships in System32 on every Windows 11 machine, so -RequiresCommand
        # proves nothing here. --status fails when the feature is not actually enabled.
        wsl --status
        if ($LASTEXITCODE -ne 0) {
            $global:LASTEXITCODE = 0
            Write-Output 'wsl.exe is present but WSL is not installed or enabled; skipping.'
            return
        }
        $global:LASTEXITCODE = 0

        wsl --update
        if ($LASTEXITCODE -ne 0) {
            Write-Output "wsl --update returned $LASTEXITCODE (commonly 'no updates available')."
            $global:LASTEXITCODE = 0
        }
    }

    # ---------------------------------------------------------------------------
    # 9. Microsoft Defender signatures
    # ---------------------------------------------------------------------------
    Invoke-Step -Name 'Defender signatures' -RequiresCommand 'Update-MpSignature' -RequiresAdmin -Tag 'Windows', 'Microsoft' -Action {
        # The Defender cmdlets are present even on machines where a third-party AV has
        # taken over and the antimalware service is off. Probe before updating so that
        # a managed device does not report a failed step every run.
        try {
            $mp = Get-MpComputerStatus -ErrorAction Stop
        } catch {
            Write-Output "Defender status unavailable ($($_.Exception.Message)); skipping signature update."
            return
        }
        if (-not $mp.AMServiceEnabled) {
            Write-Output 'Defender antimalware service is disabled (third-party AV in use?); skipping.'
            return
        }

        Update-MpSignature -ErrorAction Stop
    }

    # ---------------------------------------------------------------------------
    # 9b. Make PowerShell 7 the default Windows Terminal profile
    #     (placed before Windows Update so an AutoReboot can't skip it)
    # ---------------------------------------------------------------------------
    if ($SetPwshTerminalDefault) {
        Invoke-Step -Name 'Windows Terminal default = PowerShell 7' -Tag 'PowerShell', 'Windows' -Action {
            Set-PwshAsWindowsTerminalDefault -LogDir $logDir
        }
    } else {
        Add-SkippedStep -Name 'Windows Terminal default = PowerShell 7'
    }

    # ---------------------------------------------------------------------------
    # 10. Windows Update (OS + drivers) via PSWindowsUpdate
    # ---------------------------------------------------------------------------
    if ($IncludeWindowsUpdate) {
        Invoke-Step -Name 'Windows Update' -RequiresAdmin -Tag 'Windows', 'Microsoft' -Action {
            if (-not $isAdmin) { throw 'Administrator rights required for Windows Update.' }

            if (-not (Get-Module -ListAvailable -Name PSWindowsUpdate)) {
                if (-not (Approve-Install -Component 'PSWindowsUpdate' -Approved $AllowInstall `
                        -Description 'The PSWindowsUpdate module is not installed. Windows Update cannot be driven without it. This would install it from the PowerShell Gallery for all users on this machine.')) {
                    Stop-StepAsSkipped -Reason 'installing PSWindowsUpdate was not approved'
                }

                try {
                    $install = @{
                        Name         = 'PSWindowsUpdate'
                        Force        = $true
                        Scope        = 'AllUsers'
                        AllowClobber = $true
                        Confirm      = $false
                        ErrorAction  = 'Stop'
                    }

                    # Same reason as the module-update step: the PowerShellGet
                    # Windows ships has no -AcceptLicense to splat.
                    if (Test-ParameterSupport -Command 'Install-Module' -Parameter 'AcceptLicense') {
                        $install.AcceptLicense = $true
                    }

                    Install-Module @install
                } catch {
                    throw "Failed to install PSWindowsUpdate module: $_"
                }
            }

            Import-Module PSWindowsUpdate -ErrorAction Stop

            # Windows Update alone offers the OS and drivers. Registering the
            # Microsoft Update service widens the scan to Office and other
            # Microsoft products. Managed devices often block this by policy, so
            # degrade to a Windows-Update-only scan rather than failing the step.
            $useMicrosoftUpdate = $false
            $muServiceId = '7971f918-a847-4430-9279-4a52d1efe18d'
            try {
                if (Get-WUServiceManager -ErrorAction Stop | Where-Object { $_.ServiceID -eq $muServiceId }) {
                    $useMicrosoftUpdate = $true
                } else {
                    Add-WUServiceManager -ServiceID $muServiceId -AddServiceFlag 7 -Confirm:$false -ErrorAction Stop | Out-Null
                    $useMicrosoftUpdate = $true
                    Write-Output 'Registered the Microsoft Update service.'
                }
            } catch {
                Write-Warning "Could not enable the Microsoft Update service ($($_.Exception.Message)); scanning Windows Update only."
            }

            $params = @{ AcceptAll = $true; Install = $true }
            if ($useMicrosoftUpdate) { $params.MicrosoftUpdate = $true }
            if ($AutoReboot)         { $params.AutoReboot      = $true }
            else                     { $params.IgnoreReboot    = $true }

            Get-WindowsUpdate @params
        }
    } else {
        Add-SkippedStep -Name 'Windows Update'
    }

    # ---------------------------------------------------------------------------
    # 11. Summary + reboot check
    # ---------------------------------------------------------------------------
    Write-Host "`n================ SUMMARY ================" -ForegroundColor Green
    # Out-Host, not a bare pipeline. Inside a function, unassigned pipeline
    # output is the return value, so without it the caller would receive the
    # table's formatting objects alongside the result and the summary would not
    # appear in the run log.
    $Results | Format-Table -AutoSize -Property Step, Status, Seconds | Out-Host

    $failedSteps  = @($Results | Where-Object { $_.Status -eq 'Failed' })
    $warnedSteps  = @($Results | Where-Object { $_.Status -eq 'Warning' })

    if ($failedSteps.Count -or $warnedSteps.Count) {
        Write-Host "`nSteps needing attention:" -ForegroundColor Yellow
        foreach ($r in @($failedSteps) + @($warnedSteps)) {
            Write-Host ("  {0,-8} {1,-42} {2}" -f $r.Status, $r.Step, $r.Log)
        }
    }

    $reboot = Test-PendingReboot
    if ($reboot.IsPending) {
        Write-Host "`n[!] A reboot is pending. Restart to finish applying updates." -ForegroundColor Yellow
        foreach ($reason in $reboot.Reasons) { Write-Host "    - $reason" -ForegroundColor Yellow }
    } else {
        Write-Host "`n[OK] No pending reboots detected." -ForegroundColor Green
    }

    if ($Notify) {
        $okCount      = @($Results | Where-Object { $_.Status -eq 'OK' }).Count
        $skippedCount = @($Results | Where-Object { $_.Status -eq 'Skipped' }).Count
        $headline     = if ($failedSteps.Count) { "Updates finished with $($failedSteps.Count) failure(s)" } else { 'Updates finished' }

        Send-UpdateNotification -Text @(
            $headline
            "$okCount updated, $($failedSteps.Count) failed, $($warnedSteps.Count) with warnings, $skippedCount skipped."
            "Logs: $logDir"
        )

        # Sent second and separately so it is the one left on screen, and marked
        # urgent so Focus Assist does not hide the fact that the machine is only
        # half-updated until it restarts.
        if ($reboot.IsPending) {
            Send-UpdateNotification -Urgent -UniqueIdentifier 'Update-Everything-Reboot' -Text @(
                'Restart required'
                'Windows needs a restart to finish applying updates.'
                (($reboot.Reasons | Select-Object -First 2) -join '; ')
            )
        }
    }

    # Repeated here because the warning at startup is thousands of lines back by now.
    if ($Notify -and -not $script:NotificationsAvailable) {
        Write-Host ''
        Write-Host '[!] Notifications were requested but could not be sent.' -ForegroundColor Yellow
        Write-Host "    Reason: $($notificationStatus.Reason)" -ForegroundColor Yellow
        Write-Host '    The update run itself was unaffected.' -ForegroundColor Yellow
    } elseif (-not $Notify) {
        # State that nothing was asked for. Without this the run says nothing at
        # all about notifications, which reads as a broken feature rather than an
        # unrequested one.
        Write-Host ''
        Write-Host 'Notifications: not requested. Pass -Notify for a toast when the run finishes.' -ForegroundColor DarkGray
    }

    # Said at the end rather than at the start: by here the run has shown what
    # this machine has and has not, which is what makes the suggestion concrete.
    # Once, and only on the first run -- a tool that repeats advice on every run
    # teaches people to skim past its output.
    if ($isFirstRun) {
        Write-Host ''
        Write-Host 'That was the first run on this machine. Initialize-UpdateEverything sets up a' -ForegroundColor Cyan
        Write-Host 'schedule, installs the tools this then keeps updated, and asks before each one.' -ForegroundColor Cyan
    }

    Write-Host "Finished $(Get-Date). Detailed logs saved to: $logDir" -ForegroundColor Green
    if ($failedSteps.Count) {
        Write-Host "$($failedSteps.Count) step(s) failed." -ForegroundColor Red
    }

    if ($transcriptRunning) { try { Stop-Transcript | Out-Null } catch { Write-Verbose "Transcript already stopped." } }
    try { [Console]::OutputEncoding = $originalOutputEncoding } catch { Write-Verbose "Could not restore the console encoding." }

    # Returned rather than exited. A scheduled task turns FailedCount into an
    # exit code itself; a session that called this function keeps running.
    New-UpdateEverythingResult -Ran $true -Elevated:$isAdmin -Steps $Results `
        -RebootPending $reboot.IsPending -RebootReason $reboot.Reasons `
        -LogDirectory $logDir -MainLog $mainLog
}
