function Update-Everything {

    <#
    .SYNOPSIS
        One-shot maintenance script that updates everything on a Windows laptop
        through the package managers and update channels it can find.

    .DESCRIPTION
        Each update channel runs as an isolated step, so one failure does not stop
        the rest. Every step writes its own log, and the run ends with a summary
        table and a result object.

        Steps cover winget and the Microsoft Store, Windows Update through
        PSWindowsUpdate, Microsoft 365 Apps, Defender signatures, PowerShell
        modules and help, Chocolatey, Scoop, Python, uv, pip, pipx, npm, Deno,
        Bun, pnpm, rustup, cargo binaries, Go binaries, dotnet, GitHub CLI
        extensions, the Azure and Google Cloud CLIs, conda, the WSL kernel,
        PowerShell 7 itself and the Windows Terminal default profile. The README
        lists what each runs.

        Presence of an executable is not proof a feature is installed, and package
        managers routinely return non-zero for "nothing to do", so steps that
        drive an external tool probe for it first, and each step decides which
        of its tool's exit codes are routine. Steps
        capture every stream (*>&1); only errors raised by PowerShell itself are
        counted, and those mark a step Warning rather than OK.

        FailedCount is returned rather than exited with, so calling this from a
        session does not end that session.

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
          NuGetProvider    install or refresh the NuGet package provider
                           (the first bootstrap is CurrentUser; a refresh is
                           AllUsers when elevated, otherwise CurrentUser)
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
        Update this module, and run nothing else: a shortcut for Install-Module
        UpdateEverything -Force, or for the Main installer with
        -UpdateSelfSource Main. Default: $false. -Tag and -ExcludeTag are
        ignored for the run, and elevation is never requested, because a
        CurrentUser install needs none.

        The new version takes effect on the *next* run. This module is already
        loaded by the time the step runs: the files on disk are replaced, and
        the functions executing now stay on the code already in memory.

        Off by default. From Main it fetches and runs an installer from a
        branch, which is a supply-chain decision rather than a routine update,
        and a scheduled task that quietly followed main would be making that
        decision on every run.

    .PARAMETER Tag
        Run only the steps carrying one of these tags. Everything else is
        reported as skipped with that reason, so the summary still accounts for
        every step.

        A step carries one or more of: Windows, Microsoft, PowerShell,
        PackageManager, Python, Node, DotNet, Rust, Go, Cloud, Git, Self,
        Inventory.

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
        explanation and a result with Ran = $false rather than a UAC prompt that
        cannot succeed. Run with -SkipElevation to perform the steps that do not
        need admin.

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
        [ValidateSet('Windows', 'Microsoft', 'PowerShell', 'PackageManager', 'Python', 'Node', 'DotNet', 'Rust', 'Go', 'Cloud', 'Git', 'Self', 'Inventory')]
        [string[]] $Tag = @(),
        [ValidateSet('Windows', 'Microsoft', 'PowerShell', 'PackageManager', 'Python', 'Node', 'DotNet', 'Rust', 'Go', 'Cloud', 'Git', 'Self', 'Inventory')]
        [string[]] $ExcludeTag = @(),
        [ValidateRange(0, 3650)]
        [int]    $LogRetentionDays       = 30,
        [switch] $UpdateSelf,
        [ValidateSet('Gallery', 'Main')]
        [string] $UpdateSelfSource = 'Gallery'
    )

    # State shared with the private helpers is assigned with $script:. Inside a
    # module a plain assignment is function-scoped, so Invoke-Step would read an
    # unset $script:logDir and fail on every step. TLS is left to the OS.
    $originalOutputEncoding = Initialize-ConsoleEncoding

    # ---------------------------------------------------------------------------
    # 1. Logging
    #
    # Set up before the elevation decision, so every way this run can decline to
    # start still leaves a log behind.
    # ---------------------------------------------------------------------------
    $script:logDir = Get-UpdateLogDirectory

    # One stamp shared by the transcript and every step log, so a single run's files
    # sort together and can be pruned as a unit.
    $script:runStamp = '{0:yyyyMMdd-HHmmss}' -f (Get-Date)
    $mainLog  = Join-Path $logDir "Update-Everything-$runStamp.log"

    # Asked before pruning and before the transcript starts: pruning can empty the
    # directory, and the transcript would find its own log.
    $isFirstRun = -not @(Get-ChildItem -LiteralPath $logDir -Filter 'Update-Everything-*.log' `
        -File -ErrorAction SilentlyContinue).Count

    # Step logs rotate per run rather than being appended to, so old ones are
    # pruned by age, as are stale Windows Terminal settings backups.
    if ($LogRetentionDays -gt 0) {
        $cutoff = (Get-Date).AddDays(-$LogRetentionDays)
        Get-ChildItem -LiteralPath $logDir -File -ErrorAction SilentlyContinue |
            Where-Object { ($_.Name -like '*.log' -or $_.Name -like '*.json.bak') -and $_.LastWriteTime -lt $cutoff } |
            Remove-Item -Force -ErrorAction SilentlyContinue
    }

    # A transcript is a nice-to-have: it fails if one is already running or the
    # path is not writable, and that must not kill the run.
    $transcriptRunning = $false
    try {
        Start-Transcript -Path $mainLog -Append -ErrorAction Stop | Out-Null
        $transcriptRunning = $true
    } catch {
        Write-Warning "Transcript unavailable ($($_.Exception.Message)); per-step logs are unaffected."
    }

    # -UpdateSelf is a shortcut: update this module and run nothing else. The
    # self step needs no elevation -- the gallery path is Install-Module -Scope
    # CurrentUser and the Main installer writes to the user's modules -- so the
    # run skips the UAC prompt and narrows the tag filter to Self.
    if ($UpdateSelf) {
        if ($Tag.Count -or $ExcludeTag.Count) {
            Write-Warning '-UpdateSelf updates only this module; -Tag and -ExcludeTag are ignored for this run.'
        }
        $Tag = @('Self')
        $ExcludeTag = @()
        $SkipElevation = $true
    }

    $script:isAdmin = Test-IsAdministrator
    if (-not $isAdmin -and -not $SkipElevation) {
        # Ask whether elevation is possible before asking for it, or a standard user
        # gets a UAC prompt they can never satisfy, reported as their refusal.
        $elevation = Test-ElevationCapability

        # Said before the attempt, so a refused prompt reads as the warned-about thing.
        if ($elevation.Caution) { Write-Warning $elevation.Caution }

        if (-not $elevation.CanElevate) {
            Write-Warning "Cannot run elevated: $($elevation.Reason)"
            Write-Warning 'Nothing has been changed. Re-run with -SkipElevation to run the steps that do not need administrator rights.'

            if ($transcriptRunning) { try { Stop-Transcript | Out-Null } catch { Write-Verbose "Transcript already stopped." } }
            try { [Console]::OutputEncoding = $originalOutputEncoding } catch { Write-Verbose "Could not restore the console encoding." }

            return (New-UpdateEverythingResult -Ran $false -Reason $elevation.Reason `
                -LogDirectory $logDir -MainLog $mainLog)
        }

        # Close the transcript before handing off and reopen it afterwards. The child
        # starts its own; stamps have one-second resolution, so two open on the same
        # path would have -Append report success and lose the child's content.
        #
        # The note is written before the close: if the child hangs, this transcript is
        # all there is, and it has to name the log the real work went to.
        $childNote = "Handing off to an elevated run. Its transcript is a separate Update-Everything-*.log in $logDir, stamped when it starts."
        Write-Host $childNote -ForegroundColor Yellow

        if ($transcriptRunning) {
            try { Stop-Transcript | Out-Null } catch { Write-Verbose "Transcript already stopped." }
            $transcriptRunning = $false
        }

        # A module function must not kill its caller's session, so the child's outcome
        # comes back as a result rather than an exit.
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

    # Offer a way out before anything is touched: after the transcript starts so the
    # decision is on record, before the install checks so skipping costs nothing.
    if ($PromptBeforeRun) {
        if (-not (Test-CanPrompt)) {
            # A hidden window or redirected input cannot answer, and starting
            # anyway beats blocking until the task time limit kills the run.
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

    # Resolved before any work starts, so a missing prerequisite is reported at the
    # top of the transcript and BurntToast is installed before it is needed.
    $script:NotificationsAvailable = $false
    $notificationStatus = $null
    if ($Notify) {
        $notificationStatus = Initialize-NotificationSupport -Approved $AllowInstall
        $script:NotificationsAvailable = $notificationStatus.Available
    }

    $script:Results = [System.Collections.Generic.List[object]]::new()

    # Read by Invoke-Step, which decides per step. Script scope for the same reason
    # as $script:isAdmin: a step action runs inside Invoke-Step, not here.
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

    # The version that produced this log, so a transcript can be read against the
    # code that made it. The running module, not the highest installed.
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

        # Aligned by hand to control the widths: the step pipeline renders
        # Format-Table records through Out-String -Stream, but with widths of its
        # own choosing.
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

        # Compared against the gallery here rather than in the banner: it costs a
        # network call a machine with no network should not pay before the run
        # starts, and -ExcludeTag Inventory turns it off.
        if ($script:RunningVersion) {
            Write-Output ''
            Write-Output (Format-SelfVersionStatus -Running $script:RunningVersion `
                -Status (Get-GalleryModuleStatus -Name 'UpdateEverything'))
        }

        # More than one executable of a name on PATH means the first on PATH runs
        # and the rest are updated by nobody, or by a manager that does not own
        # the copy in use. Places preserves that resolution order.
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
                    # PowerShellGet, so Update-Module refuses it. -UpdateSelfSource
                    # Main is the matching path.
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

            # Main. Reinstalls regardless of version: the module version does not move
            # with every commit, so a version check cannot decide this.
            $uri = 'https://raw.githubusercontent.com/briankronberg/UpdateEverything/main/Install.ps1'
            $installer = Join-Path ([System.IO.Path]::GetTempPath()) "Install-UpdateEverything-$script:runStamp.ps1"

            try {
                Write-Output "Fetching the installer from $uri"
                Invoke-WebRequest -Uri $uri -OutFile $installer -UseBasicParsing -ErrorAction Stop
                Unblock-File -LiteralPath $installer -ErrorAction SilentlyContinue

                # A child process, and powershell rather than the current host: the
                # installer imports the module when it finishes, which here would
                # re-import files replaced underneath it. powershell.exe is always
                # present; pwsh is not.
                & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $installer -Force
                if ($LASTEXITCODE -ne 0) {
                    throw "The installer exited with code $LASTEXITCODE."
                }

                # This module is already loaded, so the functions running now stay on
                # the code in memory however new the files on disk are.
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
        # Refresh the indexes first. A stale index makes upgrade --all quietly miss
        # packages rather than fail loudly.
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
        # Passed through in one pass rather than echoed afterwards, because a winget
        # upgrade runs for minutes and the console should show it happening. The
        # table winget prints first is the "before" list.
        $captured = [System.Collections.Generic.List[string]]::new()

        winget upgrade --all --include-unknown --silent `
            --accept-source-agreements --accept-package-agreements --disable-interactivity 2>&1 |
            ForEach-Object { $captured.Add("$_"); $_ }

        $code = $LASTEXITCODE
        $global:LASTEXITCODE = 0

        # upgrade --all returns non-zero for routine reasons: nothing applicable, or a
        # subset (pinned, Store-sourced, running) failing while the rest succeed.
        # Report the code rather than failing the run; Write-Error marks it Warning.
        if ($code -ne 0 -and $WingetNothingToDo -notcontains $code) {

            # Which ones, and whether anything can be done. The exit code says only
            # that something did not upgrade.
            $text = $captured -join "`n"
            $before = @(Get-WingetUpgradeTable -Text $text)
            $after = @(Get-WingetUpgradeTable -Text (
                winget upgrade --include-unknown --disable-interactivity 2>&1 | Out-String))
            $global:LASTEXITCODE = 0

            $leftover = @(Get-WingetLeftover -Before $before -After $after -Output $text)

            $attempted = @($leftover | Where-Object { $_.Attempted })
            $skipped   = @($leftover | Where-Object { -not $_.Attempted -and $_.Listed })
            $appeared  = @($leftover | Where-Object { -not $_.Attempted -and -not $_.Listed })

            if ($attempted.Count) {
                Write-Output ''
                Write-Output 'Still out of date after this run:'
                foreach ($package in $attempted) {
                    Write-Output ("  {0} {1} -> {2}  ({3})" -f $package.Id, $package.Version, $package.Available, $package.Reason)
                }
            }

            # Information, not a problem: these do not change until the vendor ships
            # something applicable, and a person who reads them as failures learns
            # to skim past the ones that are.
            if ($skipped.Count) {
                Write-Output ''
                Write-Output 'Not upgradable on this machine, and expected to stay that way:'
                foreach ($package in $skipped) {
                    Write-Output ("  {0} {1} -> {2}  ({3})" -f $package.Id, $package.Version, $package.Available, $package.Reason)
                }
            }

            # Listed for the first time by the closing table: nothing was tried
            # and nothing is known to block it, so the next run picks it up.
            if ($appeared.Count) {
                Write-Output ''
                Write-Output 'Newly listed during this run; the next run picks these up:'
                foreach ($package in $appeared) {
                    Write-Output ("  {0} {1} -> {2}" -f $package.Id, $package.Version, $package.Available)
                }
            }

            # Raised only for something actually tried. A package winget declined is
            # not a fault of this run.
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
    # A manager runs before the tools it may own. The uv step asks
    # Get-ToolInstallSource and skips a managed copy, so for it this order is
    # presentation rather than protection -- but the sequence should read the
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
        # Three phases independently: a failure in one should not hide the others.
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

            # By exit code, not text: winget localises output and truncates the Id
            # column to the console width. 0 = found.
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
                # --installer-type wix forces the MSI (the Microsoft.PowerShell winget
                # package defaults to MSIX from PowerShell 7.6) so it installs to
                # C:\Program Files\PowerShell\7 where Terminal expects it.
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
                # The upgrade branch cannot convert an already-packaged PowerShell, so
                # say what it costs. An MSIX pwsh works for everything except elevating
                # and being named in a scheduled task, which this module needs.
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
        # Indexed rather than Select-Object -First 1, which stops the upstream pipeline
        # and has *>&1 record "TerminatingError(): The pipeline has been stopped."
        $found = @($roots |
            ForEach-Object { Join-Path $_ 'Common Files\Microsoft Shared\ClickToRun\OfficeC2RClient.exe' } |
            Where-Object { Test-Path -LiteralPath $_ })
        $c2r = if ($found.Count) { $found[0] } else { $null }

        if (-not $c2r) {
            Stop-StepAsSkipped -Reason 'OfficeC2RClient.exe is not present, so there is no click-to-run Office install'
        }

        # The "Update Now" button without the prompts. C2R hands the work to its
        # background service and returns, so exit 0 means requested, not applied.
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
    # PSGallery ships Untrusted, so every module install or update stops on the
    # "You are installing the modules from an untrusted repository" prompt, which
    # -ErrorAction SilentlyContinue does not suppress. Trust is stored
    # per-user under LOCALAPPDATA, and UAC keeps the same profile, so setting it
    # once here covers both the elevated and non-elevated run.
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

        # Trust only. Moving PowerShellGet forward belongs to the Gallery tooling step,
        # which handles the 1.0.0.1 Windows ships as one case of a general rule.
    }

    # The tooling every other gallery step runs on. Bootstrapping covers absence;
    # this step is what brings a present copy forward, without which a machine
    # could carry a years-old NuGet provider or a PowerShellGet 2.1 for as long
    # as it lived. Runs before PowerShell modules, which depends on it.
    Invoke-Step -Name 'Gallery tooling' -Tag 'PowerShell' -Action {
        # Not admin-gated, and -Scope AllUsers fails without elevation, so the
        # scope follows what the run actually has.
        $scope = if ($isAdmin) { 'AllUsers' } else { 'CurrentUser' }

        # --- NuGet package provider ------------------------------------------
        #
        # There is no Update-PackageProvider; Install-PackageProvider is the only way
        # forward, so the refresh is an install command fetching a binary assembly. It
        # asks under the same NuGetProvider component as the bootstrap, so one consent
        # covers both. Declining is not fatal: the provider present keeps working.
        $nuget = @(Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue |
            Sort-Object Version -Descending)
        if (-not $nuget.Count) {
            Write-Output 'No NuGet package provider is present; the Trust PSGallery step reports why.'
        } else {
            $current = $nuget[0].Version

            # SilentlyContinue and a check, not Stop and a catch. PowerShell 7
            # registers no provider bootstrap source, so this cannot be answered
            # there at all. Start-Transcript records a terminating error whether or
            # not it is caught, which would put "TerminatingError(Find-PackageProvider)"
            # in a step that went on to report the right thing. Test-PendingReboot
            # uses SilentlyContinue with Get-ItemProperty for the same reason.
            $newest = $null
            try {
                $candidates = @(Find-PackageProvider -Name NuGet -ErrorAction SilentlyContinue |
                    Sort-Object Version -Descending)
                if ($candidates.Count) { $newest = $candidates[0].Version }
            } catch {
                # A backstop: SilentlyContinue returns nothing for the absent-provider
                # case, so reaching here means a hard failure.
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
        #   absent                  an install, and asks
        #   present but not ours    a shipped copy. Update-Module answers "Module
        #                           'X' was not installed by using Install-Module,
        #                           so it cannot be updated"; moving it forward is
        #                           a side-by-side install, and asks
        #   present and ours        an update, and does not ask
        #
        # Windows PowerShell ships PowerShellGet 1.0.0.1 under Program Files and
        # Update-Module refuses it, so the version alone is not the test.
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

                # The same trap as -UpdateSelf: the module is loaded, so the files on
                # disk are replaced and the cmdlets running now stay on the code in
                # memory.
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
        # Both update commands are silent on success; without this capture the step
        # would report only OK and a duration. Taken either side of the pass, this
        # says what moved.
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

            # PowerShellGet 1.0.0.1, which Windows PowerShell ships, has no
            # -AcceptLicense, and splatting a parameter that does not exist is a
            # terminating error that would fail this step on 5.1.
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
        # Skipped rather than OK: a step that did nothing because the tool is absent
        # is not a step that updated something.
        if (Get-Command pymanager -ErrorAction SilentlyContinue) {
            pymanager install --update
        } elseif (Get-Command py -ErrorAction SilentlyContinue) {
            # Two tools answer to py: the Install Manager's alias, which has an
            # install subcommand, and the classic launcher, which treats a bare
            # word as a script path and errors. "py help install" tells them
            # apart without changing anything: the alias exits 0, the launcher
            # cannot open a script named help and does not.
            $null = & py help install 2>&1
            if ($LASTEXITCODE -ne 0) {
                $global:LASTEXITCODE = 0
                Stop-StepAsSkipped -Reason 'py here is the classic launcher, which cannot update runtimes; the Python Install Manager replaces it'
            }
            py install --update
        } else {
            Stop-StepAsSkipped -Reason 'the Python Install Manager is not installed'
        }
    }

    Invoke-Step -Name 'uv' -RequiresCommand 'uv' -Tag 'Python' -Action {
        # Self-update only what nothing else manages. "uv self update" against a uv
        # that scoop or winget installed fights whichever owns it.
        $owner = Get-ToolInstallSource -Name 'uv'
        if ($owner -notin 'Standalone', 'Unknown') {
            Stop-StepAsSkipped -Reason "uv is managed by $owner, which updates it in its own step"
        }

        $output = uv self update 2>&1
        $output

        if ($LASTEXITCODE -ne 0) {
            # uv refuses to self-update when a package manager owns it and says so in
            # its output, which is correct rather than failed. Any other non-zero
            # exit is reported as a real failure.
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
        # Never inside an active virtual environment: its packages belong to whatever
        # project made it, and it is both the easiest interpreter to reach from here
        # and the worst one to change.
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

        # python -m pip, never the bare pip.exe. On Windows pip cannot replace its
        # own running executable, so run it through the interpreter instead.
        & $interpreter -m pip install --upgrade pip --disable-pip-version-check
        if ($LASTEXITCODE -ne 0) {
            Write-Error "Could not upgrade pip for $interpreter (exit $LASTEXITCODE). pip's own message is in this step's log."
            $global:LASTEXITCODE = 0
        } else {
            Write-Output ((& $interpreter -m pip --version 2>&1 | Out-String).Trim())
            $global:LASTEXITCODE = 0
        }

        # Only this interpreter's pip. Upgrading pip in every Python on a machine is
        # a larger claim than a maintenance run should make.
        $others = @(py --list 2>&1 | Out-String -Stream | Where-Object { $_ -match '^\s*-V:' -and $_ -notmatch '\*' })
        $global:LASTEXITCODE = 0
        if ($others.Count) {
            Write-Output ''
            Write-Output "$($others.Count) other interpreter(s) are installed and were not changed:"
            $others | ForEach-Object { Write-Output "  $($_.Trim())" }
        }

        # Installed packages are left alone; the README's Python section carries
        # the why.
    }

    Invoke-Step -Name 'pipx packages' -RequiresCommand 'pipx' -Tag 'Python' -Action {
        pipx upgrade-all
    }

    # ---------------------------------------------------------------------------
    # 5. Node / npm
    # ---------------------------------------------------------------------------
    # conda updates conda itself in the base environment and nothing else.
    # Environments hold project package sets, and "conda update --all" is the
    # operation the pip step's rule declines: upgrading one package can silently
    # downgrade another's dependency.
    Invoke-Step -Name 'conda' -RequiresCommand 'conda' -Tag 'Python' -Action {
        $output = conda update --name base conda --yes 2>&1
        $output
        if ($LASTEXITCODE -ne 0) {
            Write-Error "conda update failed with exit code $LASTEXITCODE. conda's own message is in this step's log."
            $global:LASTEXITCODE = 0
        }
    }

    Invoke-Step -Name 'npm' -RequiresCommand 'npm' -Tag 'Node' -Action {
        # npm writes progress and deprecation notices to stderr as a matter of
        # course, so judge it by exit code. Output is captured as well as passed
        # through, because the reason npm failed is usually in it.
        $npmOutput = npm install -g npm@latest 2>&1
        $npmOutput
        if ($LASTEXITCODE -ne 0) {
            $npmText = $npmOutput | Out-String

            # EBADENGINE means the newest npm does not support the installed Node,
            # which is a fact about this machine rather than a fault in the update.
            # Reported in full, because the bare exit code does not say which of
            # the two it is.
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

    # The three below follow the uv rule: self-update only what nothing else
    # manages, and treat the tool's own refusal as correct rather than failed.
    Invoke-Step -Name 'Deno' -RequiresCommand 'deno' -Tag 'Node' -Action {
        $owner = Get-ToolInstallSource -Name 'deno'
        if ($owner -notin 'Standalone', 'Unknown') {
            Stop-StepAsSkipped -Reason "Deno is managed by $owner, which updates it in its own step"
        }

        $output = deno upgrade 2>&1
        $output

        if ($LASTEXITCODE -ne 0) {
            if (($output | Out-String) -match 'package manager') {
                Write-Output 'Deno declined to upgrade because something else manages it.'
                $global:LASTEXITCODE = 0
            } else {
                Write-Error "deno upgrade failed with exit code $LASTEXITCODE. Deno's own message is in this step's log."
                $global:LASTEXITCODE = 0
            }
        }
    }

    Invoke-Step -Name 'Bun' -RequiresCommand 'bun' -Tag 'Node' -Action {
        $owner = Get-ToolInstallSource -Name 'bun'
        if ($owner -notin 'Standalone', 'Unknown') {
            Stop-StepAsSkipped -Reason "Bun is managed by $owner, which updates it in its own step"
        }

        $output = bun upgrade 2>&1
        $output

        if ($LASTEXITCODE -ne 0) {
            if (($output | Out-String) -match 'package manager') {
                Write-Output 'Bun declined to upgrade because something else manages it.'
                $global:LASTEXITCODE = 0
            } else {
                Write-Error "bun upgrade failed with exit code $LASTEXITCODE. Bun's own message is in this step's log."
                $global:LASTEXITCODE = 0
            }
        }
    }

    Invoke-Step -Name 'pnpm' -RequiresCommand 'pnpm' -Tag 'Node' -Action {
        $owner = Get-ToolInstallSource -Name 'pnpm'
        if ($owner -notin 'Standalone', 'Unknown') {
            Stop-StepAsSkipped -Reason "pnpm is managed by $owner, which updates it in its own step"
        }

        # self-update applies to the standalone install only; a Corepack-managed
        # pnpm is pinned per project and updated through Corepack.
        $output = pnpm self-update 2>&1
        $output

        if ($LASTEXITCODE -ne 0) {
            if (($output | Out-String) -match 'corepack|standalone') {
                Write-Output 'pnpm declined to self-update because Corepack or a package manager manages it.'
                $global:LASTEXITCODE = 0
            } else {
                Write-Error "pnpm self-update failed with exit code $LASTEXITCODE. pnpm's own message is in this step's log."
                $global:LASTEXITCODE = 0
            }
        }
    }

    # ---------------------------------------------------------------------------
    # 6. .NET global tools
    # ---------------------------------------------------------------------------
    Invoke-Step -Name '.NET global tools' -RequiresCommand 'dotnet' -Tag 'DotNet' -Action {
        # dotnet exists for runtime-only installs, and "dotnet --version" fails when
        # there is no SDK or a global.json pins a missing one, so validate the
        # string before casting it.
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

    # rustup moves the toolchains; nothing moves the binaries cargo install put
    # on the machine. The cargo-update crate adds the subcommand that does.
    Invoke-Step -Name 'cargo binaries' -RequiresCommand 'cargo' -Tag 'Rust' -Action {
        $null = cargo install-update --version 2>&1
        if ($LASTEXITCODE -ne 0) {
            $global:LASTEXITCODE = 0
            Stop-StepAsSkipped -Reason 'the cargo-update crate is not installed; "cargo install cargo-update" adds the subcommand this step runs'
        }

        # cargo writes progress to stderr as a matter of course; judge by exit code.
        $output = cargo install-update --all 2>&1
        $output
        if ($LASTEXITCODE -ne 0) {
            Write-Error "cargo install-update --all failed with exit code $LASTEXITCODE. cargo's own message is in this step's log."
            $global:LASTEXITCODE = 0
        }
    }

    # go install has no update-everything form; gup is the tool that adds one,
    # updating every binary under GOBIN.
    Invoke-Step -Name 'Go binaries' -RequiresCommand 'go' -Tag 'Go' -Action {
        if (-not (Get-Command gup -CommandType Application -ErrorAction SilentlyContinue)) {
            Stop-StepAsSkipped -Reason 'gup is not installed; "go install github.com/nao1215/gup@latest" adds it'
        }

        $output = gup update 2>&1
        $output
        if ($LASTEXITCODE -ne 0) {
            Write-Error "gup update failed with exit code $LASTEXITCODE. gup's own message is in this step's log."
            $global:LASTEXITCODE = 0
        }
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
    # 7b. Cloud CLIs
    # ---------------------------------------------------------------------------
    # Both talk to a vendor endpoint and can pull a large payload, which is what
    # the Cloud tag is for: -ExcludeTag Cloud drops the pair on a metered or
    # offline machine.

    # az upgrade reruns the MSI on the standard Windows install, so the step
    # needs the elevation it would otherwise stall asking for. It also updates
    # installed az extensions by default.
    Invoke-Step -Name 'Azure CLI' -RequiresCommand 'az' -RequiresAdmin -Tag 'Cloud' -Action {
        $output = az upgrade --yes --only-show-errors 2>&1
        $output
        if ($LASTEXITCODE -ne 0) {
            Write-Error "az upgrade failed with exit code $LASTEXITCODE. az's own message is in this step's log."
            $global:LASTEXITCODE = 0
        }
    }

    Invoke-Step -Name 'Google Cloud CLI' -RequiresCommand 'gcloud' -Tag 'Cloud' -Action {
        # A gcloud that Chocolatey or Scoop installed disables its own component
        # manager, so self-update is only right for the bundled install.
        $owner = Get-ToolInstallSource -Name 'gcloud'
        if ($owner -notin 'Standalone', 'Unknown') {
            Stop-StepAsSkipped -Reason "gcloud is managed by $owner, which updates it in its own step"
        }

        $output = gcloud components update --quiet 2>&1
        $output
        if ($LASTEXITCODE -ne 0) {
            if (($output | Out-String) -match 'component manager is disabled') {
                Write-Output 'gcloud declined to self-update because its component manager is disabled for this install.'
                $global:LASTEXITCODE = 0
            } else {
                Write-Error "gcloud components update failed with exit code $LASTEXITCODE. gcloud's own message is in this step's log."
                $global:LASTEXITCODE = 0
            }
        }
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
        # The Defender cmdlets exist even where a third-party AV has taken over and
        # the service is off, so probe before updating.
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

            # Windows Update alone offers the OS and drivers; registering Microsoft
            # Update widens the scan to Office and other Microsoft products. Managed
            # devices often block this by policy, so degrade rather than fail.
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
