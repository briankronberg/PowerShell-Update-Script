function Update-Everything {

    <#
    .SYNOPSIS
        One-shot maintenance script that updates everything on a Windows laptop
        through the package managers and update channels it can find.

    .DESCRIPTION
        v3 adds:
          - Installs PowerShell 7 if missing, or upgrades it to the latest release,
            via winget. Keeps the MSI package format so it lands in
            C:\Program Files\PowerShell\7 (the path Windows Terminal looks for).
          - Makes PowerShell 7 the default Windows Terminal profile by pointing
            settings.json "defaultProfile" at the PowerShell Core profile GUID.
            Only that one value is changed; the rest of settings.json is preserved.

        Inherited from v2:
          - Captures full stdout/stderr per step into dedicated log files
          - Validates external CLI exit codes ($LASTEXITCODE), reset per step so a
            cmdlet-only step cannot inherit a stale code from an earlier native command
          - Relaunches elevated via -Command (not -File) so typed [bool] parameters
            survive the elevation
          - Structured summary with log file references and reboot detection

        Also in this revision:
          - Trusts PSGallery once (PowerShellGet v2 + PSResourceGet v3) so module
            and help updates never stop on the untrusted-repository prompt
          - Refreshes the winget source indexes and updates App Installer (winget
            itself), which "winget upgrade --all" does not reliably cover
          - Updates Microsoft 365 Apps via OfficeC2RClient, .NET workloads, and
            GitHub CLI extensions
          - Scans Microsoft Update rather than Windows Update alone, so Office and
            other Microsoft products are included
          - Stamps step logs per run and prunes old ones via -LogRetentionDays

        Robustness notes (why this script is shaped the way it is):
          - Steps capture every stream (*>&1), not just warnings, so the step log is
            a complete record. Native stderr surfaces as error records too, and many
            CLIs write ordinary progress there, so only errors raised by PowerShell
            itself are counted -- those mark a step 'Warning' rather than 'OK'.
          - Package managers routinely return non-zero for "nothing to do" or for a
            partial success. Those codes are enumerated per step rather than being
            treated as run failures.
          - Presence of an .exe is not proof a feature is installed. wsl.exe ships in
            System32 on every Windows 11 machine; Defender cmdlets exist even where a
            third-party AV has taken over. Both are probed before use.
          - winget output is localised and its Id column is truncated to the console
            width, so package presence is decided by exit code, never by text match.
          - The script exits with the number of failed steps, so a scheduled task or
            monitoring wrapper can detect a bad run.

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
        [ValidateSet('All', 'PowerShell7', 'PSWindowsUpdate', 'NuGetProvider', 'BurntToast')]
        [string[]] $AllowInstall = @(),
        [ValidateRange(0, 3650)]
        [int]    $LogRetentionDays       = 30
    )

    # $script:, not a plain local. As a script these lived at script scope and
    # the private helpers read them as $script:. Inside a module a plain
    # assignment is function-scoped, so Invoke-Step would read an unset
    # $script:logDir and fail on every single step.
    $script:isAdmin = Test-IsAdministrator
    if (-not $isAdmin -and -not $SkipElevation) {
        # Ask whether elevation is possible before asking for it. Without this the
        # script raises a UAC prompt a standard user can never satisfy, and reports
        # the refusal as though the user had declined it.
        $elevation = Test-ElevationCapability
        if (-not $elevation.CanElevate) {
            Write-Warning "Cannot run elevated: $($elevation.Reason)"
            Write-Warning 'Nothing has been changed. Re-run with -SkipElevation to run the steps that do not need administrator rights.'
            return (New-UpdateEverythingResult -Ran $false -Reason $elevation.Reason)
        }

        # A module function must not kill the session it was called from, so the
        # elevated child's outcome comes back as a result rather than an exit.
        $child = Invoke-SelfElevation -BoundParameters $PSBoundParameters
        return (New-UpdateEverythingResult -Ran $false -Elevated `
            -Reason "Re-ran elevated in a separate window, which finished with exit code $child." `
            -FailedCount ([int] $child))
    }

    if (-not $isAdmin) {
        Write-Warning 'Running without administrator rights. Steps that require admin will be skipped and listed in the summary.'
    }

    # TLS: no hardcoded override. Modern Windows/PowerShell negotiates TLS 1.2/1.3 automatically.
    $originalOutputEncoding = Initialize-ConsoleEncoding

    # ---------------------------------------------------------------------------
    # 1. Logging
    # ---------------------------------------------------------------------------
    $script:logDir = Get-UpdateLogDirectory

    # One stamp shared by the transcript and every step log, so a single run's files
    # sort together and can be pruned as a unit.
    $script:runStamp = '{0:yyyyMMdd-HHmmss}' -f (Get-Date)
    $mainLog  = Join-Path $logDir "Update-Everything-$runStamp.log"

    # Step logs used to be a fixed name appended to forever. They now rotate per run,
    # so prune the old ones (and stale Terminal settings backups) instead.
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

    # Notifications are resolved before any work starts, not after it. A warning
    # raised at the end has scrolled past on an interactive run, and on a scheduled
    # run there is no console reading it at all -- here it lands near the top of the
    # transcript, where someone looking for "why did I not get a toast" will find it.
    # It also means -InstallNotificationModule installs before the run rather than
    # after everything it was meant to report on.
    # Offer a way out before anything is touched. This sits after the transcript
    # starts, so the decision is on record, and before the notification and install
    # checks, so skipping costs nothing.
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
                    # Not a failure. You decided, and the next scheduled run stands.
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

    $script:NotificationsAvailable = $false
    $notificationStatus = $null
    if ($Notify) {
        $notificationStatus = Initialize-NotificationSupport -Approved $AllowInstall
        $script:NotificationsAvailable = $notificationStatus.Available
    }

    $script:Results = [System.Collections.Generic.List[object]]::new()

    # winget exit codes that mean "nothing to do" rather than "failed".
    #   0x8A15002B (-1978335189) APPINSTALLER_CLI_ERROR_UPDATE_NOT_APPLICABLE
    #   0x8A150014 (-1978335212) APPINSTALLER_CLI_ERROR_NO_APPLICATIONS_FOUND
    $WingetNothingToDo = @(-1978335189, -1978335212)

    Write-Host "Maintenance run started $(Get-Date)  |  Admin: $isAdmin  |  Main Log: $mainLog" -ForegroundColor Green

    # ---------------------------------------------------------------------------
    # 2. winget (apps from winget + Microsoft Store sources)
    # ---------------------------------------------------------------------------
    Invoke-Step -Name 'winget self-update' -RequiresCommand 'winget' -Action {
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

    Invoke-Step -Name 'winget (all sources)' -RequiresCommand 'winget' -Action {
        winget upgrade --all --include-unknown --silent `
            --accept-source-agreements --accept-package-agreements --disable-interactivity
        $code = $LASTEXITCODE
        $global:LASTEXITCODE = 0

        # 'upgrade --all' returns non-zero for entirely routine reasons: nothing
        # applicable, or a subset of packages (pinned, Store-sourced, or currently
        # running) failing while the rest upgrade fine. Report the code instead of
        # failing the run over it; Write-Error marks the step 'Warning'.
        if ($code -ne 0 -and $WingetNothingToDo -notcontains $code) {
            Write-Error ('winget upgrade --all returned {0} (0x{0:X8}); one or more packages may not have upgraded.' -f $code)
        } elseif ($code -ne 0) {
            Write-Output 'winget reports nothing left to upgrade.'
        }
    }

    # ---------------------------------------------------------------------------
    # 2b. PowerShell 7 (install if missing, else upgrade to the latest release)
    # ---------------------------------------------------------------------------
    if ($IncludePowerShell7) {
        Invoke-Step -Name 'PowerShell 7 (latest)' -RequiresCommand 'winget' -RequiresAdmin -Action {
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
                Write-Output "Note: $exe not found after the winget step (an MSIX install lands elsewhere)."
            }
        }
    } else {
        Add-SkippedStep -Name 'PowerShell 7 (latest)'
    }

    # ---------------------------------------------------------------------------
    # 2c. Microsoft 365 Apps (click-to-run)
    # ---------------------------------------------------------------------------
    Invoke-Step -Name 'Microsoft 365 Apps' -Action {
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
    Invoke-Step -Name 'Trust PSGallery' -Action {
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
    }

    Invoke-Step -Name 'PowerShell modules' -Action {
        if (Get-Command Update-PSResource -ErrorAction SilentlyContinue) {
            # -TrustRepository is the belt to the trust step's braces: it suppresses
            # the prompt even if the persisted trust could not be written.
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
                Force         = $true
                AcceptLicense = $true
                Confirm       = $false
                ErrorAction   = 'SilentlyContinue'
            }
            if ($IncludePrerelease) { $p.AllowPrerelease = $true }
            Update-Module @p
        } else {
            Write-Output 'No PowerShellGet/PSResourceGet available; skipping.'
        }
    }

    Invoke-Step -Name 'PowerShell help' -Action {
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
    Invoke-Step -Name 'Python (Install Manager)' -Action {
        # Reported as skipped rather than OK. A step that did nothing because
        # the tool is absent is not the same as a step that updated something,
        # and the summary should not read as though Python were handled.
        if     (Get-Command pymanager -ErrorAction SilentlyContinue) { pymanager install --update }
        elseif (Get-Command py        -ErrorAction SilentlyContinue) { py install --update }
        else   { Stop-StepAsSkipped -Reason 'the Python Install Manager is not installed' }
    }

    Invoke-Step -Name 'uv' -RequiresCommand 'uv' -Action {
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
            # so. That is correct behaviour rather than a failed run. Anything
            # else is a real failure and gets reported as one, rather than
            # excused with a guess about why it might have happened.
            if (($output | Out-String) -match 'package manager|self-update.*(disabled|unavailable)') {
                Write-Output 'uv declined to self-update because something else manages it.'
                $global:LASTEXITCODE = 0
            } else {
                Write-Error "uv self update failed with exit code $LASTEXITCODE. uv's own message is in this step's log."
                $global:LASTEXITCODE = 0
            }
        }
    }

    Invoke-Step -Name 'pipx packages' -RequiresCommand 'pipx' -Action {
        pipx upgrade-all
    }

    # ---------------------------------------------------------------------------
    # 5. Node / npm
    # ---------------------------------------------------------------------------
    Invoke-Step -Name 'npm' -RequiresCommand 'npm' -Action {
        # npm writes progress and deprecation notices to stderr as a matter of course,
        # so judge it by exit code only.
        # Output is captured as well as passed through, because the reason npm failed
        # is usually in it.
        $npmOutput = npm install -g npm@latest 2>&1
        $npmOutput
        if ($LASTEXITCODE -ne 0) {
            $npmText = $npmOutput | Out-String

            # EBADENGINE means the newest npm does not support the installed Node,
            # which is a fact about this machine rather than a fault in the update.
            # Said plainly, because "exit code 1" sends people looking in the wrong
            # place.
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
    Invoke-Step -Name '.NET global tools' -RequiresCommand 'dotnet' -Action {
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

    Invoke-Step -Name '.NET workloads' -RequiresCommand 'dotnet' -Action {
        # No-ops cleanly ("No workloads to update") when none are installed, but a
        # runtime-only install has no workload command at all.
        dotnet workload update
        if ($LASTEXITCODE -ne 0) {
            Write-Output "dotnet workload update returned $LASTEXITCODE (no SDK, or no workloads to update)."
            $global:LASTEXITCODE = 0
        }
    }

    # ---------------------------------------------------------------------------
    # 7. Other package managers (run only if installed)
    # ---------------------------------------------------------------------------
    # 1641 and 3010 are the MSI "reboot initiated" / "reboot required" codes, which
    # Chocolatey passes straight through on an otherwise successful upgrade.
    Invoke-Step -Name 'Chocolatey' -RequiresCommand 'choco' -AllowedExitCodes 1641, 3010 -Action {
        choco upgrade all -y
    }

    Invoke-Step -Name 'Scoop' -RequiresCommand 'scoop' -Action {
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

    Invoke-Step -Name 'rustup' -RequiresCommand 'rustup' -Action {
        rustup update
    }

    Invoke-Step -Name 'GitHub CLI extensions' -RequiresCommand 'gh' -Action {
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
    Invoke-Step -Name 'WSL kernel' -RequiresCommand 'wsl' -Action {
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
    Invoke-Step -Name 'Defender signatures' -RequiresCommand 'Update-MpSignature' -RequiresAdmin -Action {
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
        Invoke-Step -Name 'Windows Terminal default = PowerShell 7' -Action {
            Set-PwshAsWindowsTerminalDefault -LogDir $logDir
        }
    } else {
        Add-SkippedStep -Name 'Windows Terminal default = PowerShell 7'
    }

    # ---------------------------------------------------------------------------
    # 10. Windows Update (OS + drivers) via PSWindowsUpdate
    # ---------------------------------------------------------------------------
    if ($IncludeWindowsUpdate) {
        Invoke-Step -Name 'Windows Update' -RequiresAdmin -Action {
            if (-not $isAdmin) { throw 'Administrator rights required for Windows Update.' }

            if (-not (Get-Module -ListAvailable -Name PSWindowsUpdate)) {
                if (-not (Approve-Install -Component 'PSWindowsUpdate' -Approved $AllowInstall `
                        -Description 'The PSWindowsUpdate module is not installed. Windows Update cannot be driven without it. This would install it from the PowerShell Gallery for all users on this machine.')) {
                    Stop-StepAsSkipped -Reason 'installing PSWindowsUpdate was not approved'
                }

                try {
                    Install-Module PSWindowsUpdate -Force -Scope AllUsers -AcceptLicense `
                        -AllowClobber -Confirm:$false -ErrorAction Stop
                } catch {
                    throw "Failed to install PSWindowsUpdate module: $_"
                }
            }

            Import-Module PSWindowsUpdate -ErrorAction Stop

            # Windows Update alone offers the OS and drivers. Registering the
            # Microsoft Update service widens the scan to Office and other Microsoft
            # products, which is what the synopsis has always claimed to do.
            # Managed devices often block this by policy, so degrade to a
            # Windows-Update-only scan rather than failing the whole step.
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
    # output is the return value, so this table stopped being displayed and
    # started being returned: the caller got an array of formatting objects with
    # the result buried among them, and the summary vanished from the run log.
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
