#Requires -Version 5.1

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

.PARAMETER LogRetentionDays
    Delete logs and settings.json backups in the log directory older than this
    many days. Default: 30. Set to 0 to keep everything.

.OUTPUTS
    Exit code:
      0     every step succeeded or was skipped
      1-63  that many steps failed ('Warning' steps completed and do not count)
      64    nothing was attempted, because the run could not become
            Administrator -- the account is not in the local Administrators
            group, UAC is disabled, elevation was declined, or the script was
            not running from a file. Distinct from a step count so a wrapper can
            tell "did not run" from "ran and something failed".

.NOTES
    Elevation is checked before it is requested. A standard user gets a clear
    explanation and exit 64 rather than a UAC prompt that cannot succeed. Run
    with -SkipElevation to perform the steps that do not need admin.

    Execution policy: the elevated relaunch passes -ExecutionPolicy Bypass, but
    the first launch obeys whatever policy is in force. On a machine set to
    AllSigned or Restricted, start it with:
        powershell -ExecutionPolicy Bypass -File .\Update-Everything.ps1
#>

[CmdletBinding()]
param(
    [bool]   $IncludeWindowsUpdate   = $true,
    [bool]   $IncludePowerShell7     = $true,
    [bool]   $SetPwshTerminalDefault = $true,
    [switch] $AutoReboot,
    [switch] $IncludePrerelease,
    [switch] $UpdateGlobalNpm,
    [switch] $SkipElevation,
    [ValidateRange(0, 3650)]
    [int]    $LogRetentionDays       = 30
)

# ---------------------------------------------------------------------------
# Functions
#
# Everything below is a definition. The executable part of the script starts
# after the dot-source guard further down, so that
#
#     . .\Update-Everything.ps1
#
# defines these functions without updating anything. That is what makes the
# script testable: the test suite loads it this way and exercises the functions
# directly. Nothing above the guard may have a side effect.
# ---------------------------------------------------------------------------

function Test-IsAdministrator {
    # Split out so callers read as intent rather than as a WindowsPrincipal cast.
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    ([Security.Principal.WindowsPrincipal] `
        [Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-UacEnabled {
    # Whether Windows will offer a consent prompt at all. With UAC switched off,
    # a non-elevated session cannot ask for elevation -- no prompt appears and
    # Start-Process -Verb RunAs fails rather than escalating.
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    try {
        $value = (Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' `
            -Name EnableLUA -ErrorAction Stop).EnableLUA
        return [bool] $value
    } catch {
        # Absent or unreadable: assume UAC is on, which is the Windows default.
        # Guessing "off" here would refuse to run on a perfectly normal machine.
        return $true
    }
}

function Test-AdministratorGroupMember {
    # Whether this account could become an administrator, as opposed to already
    # being one. Returns $true, $false, or $null when it cannot be determined.
    #
    # The obvious implementation -- looking for S-1-5-32-544 in the current
    # token's groups -- does not work, and fails in the dangerous direction. On
    # a filtered (split) token Windows drops that SID entirely, so a genuine
    # administrator reports as a standard user and the script would refuse to
    # elevate someone who could have elevated perfectly well. Verified on a real
    # machine: 'net localgroup Administrators' listed the user while
    # WindowsIdentity.Groups did not contain the SID.
    #
    # So ask the group instead, by SID rather than by name, because
    # 'Administrators' is localised. Anything unresolvable returns $null, and the
    # caller treats unknown as "attempt it" rather than "refuse".
    [CmdletBinding()]
    param()

    try {
        $members = @(Get-LocalGroupMember -SID 'S-1-5-32-544' -ErrorAction Stop)
    } catch {
        # No LocalAccounts module, a domain controller, or an access denial.
        return $null
    }

    $me = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    foreach ($member in $members) {
        if ($member.SID.Value -eq $me) { return $true }
    }

    # A nested group could still grant membership, and resolving that needs a
    # domain round trip. Unknown beats a wrong "no".
    if ($members | Where-Object { $_.ObjectClass -eq 'Group' }) { return $null }

    return $false
}

function Test-ElevationCapability {
    # Decides, before anything is attempted, whether this run can become
    # Administrator -- so the script can explain itself instead of raising a UAC
    # prompt that cannot succeed, or hanging on one that never appears.
    [CmdletBinding()]
    param()

    if (Test-IsAdministrator) {
        return [pscustomobject]@{
            IsElevated = $true
            CanElevate = $true
            Reason     = 'Already running as Administrator.'
        }
    }

    # Only a definite $false blocks the run. $null means "could not tell", and
    # guessing wrong here would refuse to run for a legitimate administrator.
    if ((Test-AdministratorGroupMember) -eq $false) {
        return [pscustomobject]@{
            IsElevated = $false
            CanElevate = $false
            Reason     = 'This account is not a member of the local Administrators group, so Windows will not grant elevation. An administrator has to run the script, or use -SkipElevation to run the steps that do not need admin.'
        }
    }

    if (-not (Test-UacEnabled)) {
        return [pscustomobject]@{
            IsElevated = $false
            CanElevate = $false
            Reason     = 'UAC (EnableLUA) is disabled, so this session cannot request elevation. Sign in with an elevated session, or use -SkipElevation.'
        }
    }

    [pscustomobject]@{
        IsElevated = $false
        CanElevate = $true
        Reason     = 'Elevation can be requested.'
    }
}

function Invoke-SelfElevation {
    # Relaunches this script elevated and exits with the child's exit code.
    # Returns only if elevation could not be attempted.
    [CmdletBinding()]
    param(
        # The caller's $PSBoundParameters. Inside a function $PSBoundParameters
        # describes that function, so the script's own arguments have to be
        # passed in explicitly or the elevated run loses them.
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $BoundParameters
    )

    # $PSCommandPath is empty when the script was piped in or pasted rather than
    # run from a file, and there is then nothing to relaunch.
    if (-not $PSCommandPath) {
        Write-Error 'Cannot self-elevate: the script is not running from a file. Save it as a .ps1 and run it, or pass -SkipElevation.'
        exit 64
    }

    Write-Host "Elevating to Administrator..." -ForegroundColor Yellow

    # Prefer the current host executable. Some hosts report no path, so fall back
    # to whatever PowerShell we can resolve.
    $hostPath = (Get-Process -Id $PID).Path
    if (-not $hostPath -or -not (Test-Path -LiteralPath $hostPath)) {
        $hostPath = $null
        foreach ($candidate in 'pwsh', 'powershell') {
            $resolved = Get-Command $candidate -CommandType Application -ErrorAction SilentlyContinue |
                Select-Object -First 1
            if ($resolved) { $hostPath = $resolved.Source; break }
        }
    }
    if (-not $hostPath) {
        Write-Error 'Cannot self-elevate: no PowerShell executable could be resolved to relaunch.'
        exit 64
    }

    # Re-launch via -Command, not -File. -File coerces every argument to a string,
    # so a typed [bool] such as -IncludeWindowsUpdate $false would arrive as $true.
    # Building a "& 'script' -Param:$bool" command preserves real PowerShell literals.
    $escPath = "'" + ($PSCommandPath -replace "'", "''") + "'"
    $invoke  = "& $escPath"
    $BoundParameters.GetEnumerator() | ForEach-Object {
        $key = $_.Key
        $val = $_.Value
        if ($val -is [switch]) {
            if ($val.IsPresent) { $invoke += " -$key" }
        } elseif ($val -is [bool]) {
            $invoke += " -${key}:`$$($val.ToString().ToLowerInvariant())"
        } else {
            $invoke += " -$key '" + ("$val" -replace "'", "''") + "'"
        }
    }
    $argList = "-NoProfile -ExecutionPolicy Bypass -Command `"$invoke`""

    try {
        # -Wait so this console reports the real outcome instead of returning
        # instantly while the elevated window does the work and vanishes.
        $child = Start-Process -FilePath $hostPath -Verb RunAs -ArgumentList $argList `
            -PassThru -Wait -ErrorAction Stop
        Write-Host "Elevated run finished with exit code $($child.ExitCode)." -ForegroundColor Green
        exit $child.ExitCode
    } catch {
        # Declining the UAC prompt throws here; without this the script dies with
        # an unhandled exception and no explanation.
        Write-Warning "Elevation was declined or failed: $($_.Exception.Message)"
        Write-Warning 'Re-run with -SkipElevation to proceed without admin (admin-only steps will be flagged).'
        exit 64
    }
}

function Initialize-ConsoleEncoding {
    # Native CLIs emit UTF-8 (winget) or UTF-16LE (wsl); without this the console
    # codepage turns their output into mojibake in the logs. Returns the previous
    # encoding so the caller can put the host back the way it found it.
    [CmdletBinding()]
    param()

    $previous = [Console]::OutputEncoding
    try { [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false) } catch { }
    $env:WSL_UTF8 = '1'
    $previous
}

function Get-UpdateLogDirectory {
    # Resolves a writable directory for this run's logs, creating it if needed.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        # Preferred roots, most specific first. USERPROFILE is not guaranteed
        # (SYSTEM contexts, stripped environments), so the list is filtered for
        # non-empty entries rather than used to build a path from $null.
        [string[]] $Candidate = @($env:USERPROFILE, $env:LOCALAPPDATA, $env:TEMP, $PSScriptRoot)
    )

    $logRoot = $Candidate | Where-Object { $_ } | Select-Object -First 1
    if (-not $logRoot) { $logRoot = [System.IO.Path]::GetTempPath() }
    $logDir = Join-Path $logRoot 'UpdateLogs'

    try {
        if (-not (Test-Path -LiteralPath $logDir)) {
            $null = New-Item -ItemType Directory -Path $logDir -Force -ErrorAction Stop
        }
    } catch {
        $logDir = Join-Path ([System.IO.Path]::GetTempPath()) 'UpdateLogs'
        Write-Warning "Could not use the preferred log directory ($($_.Exception.Message)); falling back to $logDir."
        $null = New-Item -ItemType Directory -Path $logDir -Force -ErrorAction SilentlyContinue
    }

    $logDir
}

function Write-StepLog {
    # Logging must never be the thing that kills a run, so failures here degrade
    # to a warning rather than propagating.
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][string] $Message
    )
    try {
        Add-Content -LiteralPath $Path -Value ('{0:yyyy-MM-dd HH:mm:ss} | {1}' -f (Get-Date), $Message) -ErrorAction Stop
    } catch {
        Write-Warning "Could not write to step log '$Path': $($_.Exception.Message)"
    }
}

function Add-SkippedStep {
    param(
        [Parameter(Mandatory)][string] $Name,
        [string]                       $Reason = 'disabled by parameter'
    )
    Write-Host "`nSKIP  $Name ($Reason)" -ForegroundColor DarkGray
    $script:Results.Add([pscustomobject]@{ Step = $Name; Status = 'Skipped'; Seconds = 0; Log = '' })
}

function Invoke-Step {
    param(
        [Parameter(Mandatory)][string]      $Name,
        [Parameter(Mandatory)][scriptblock] $Action,
        [string]                            $RequiresCommand,
        # Steps that cannot work without administrator rights. Reported as
        # skipped with the reason rather than left to fail with a permissions
        # error that reads like a bug.
        [switch]                            $RequiresAdmin,
        # Native exit codes this step should treat as success.
        [int[]]                             $AllowedExitCodes = @()
    )

    # Step names carry spaces, parens and '=' -- legal on NTFS but awkward on
    # disk. The run stamp keeps each run's step logs together and stops any one
    # file growing without bound.
    $safeName = ($Name -replace '[^\w\-]+', '-').Trim('-')
    if (-not $safeName) { $safeName = 'step' }
    $stepLog = Join-Path $script:logDir "$safeName-$script:runStamp.log"

    # Pre-check administrator rights
    if ($RequiresAdmin -and -not $script:isAdmin) {
        $msg = "SKIP  $Name (requires Administrator; this run is not elevated)"
        Write-Host $msg -ForegroundColor DarkGray
        Write-StepLog -Path $stepLog -Message $msg
        $script:Results.Add([pscustomobject]@{ Step = $Name; Status = 'Skipped'; Seconds = 0; Log = '' })
        return
    }

    # Pre-check command availability
    if ($RequiresCommand -and -not (Get-Command $RequiresCommand -ErrorAction SilentlyContinue)) {
        $msg = "SKIP  $Name (command '$RequiresCommand' not found)"
        Write-Host $msg -ForegroundColor DarkGray
        Write-StepLog -Path $stepLog -Message $msg
        $script:Results.Add([pscustomobject]@{ Step = $Name; Status = 'Skipped'; Seconds = 0; Log = '' })
        return
    }

    Write-Host ("`n=== STARTING: $Name ===") -ForegroundColor Cyan
    Write-StepLog -Path $stepLog -Message "STARTING $Name"
    $sw = [System.Diagnostics.Stopwatch]::StartNew()

    try {
        # Reset so a cmdlet-only step can't inherit a stale exit code from an earlier native command
        $global:LASTEXITCODE = 0

        # *>&1 rather than 4>&1: Write-Host goes to the information stream and
        # native stderr to the error stream, so the old warning-only redirect put
        # almost nothing in the step log. The ForEach-Object both accumulates the
        # output for inspection and passes it through, so the console and the
        # transcript still see it live during long-running steps.
        $stepOutput = [System.Collections.Generic.List[object]]::new()
        & $Action *>&1 |
            ForEach-Object { $stepOutput.Add($_); $_ } |
            Tee-Object -FilePath $stepLog -Append

        $code = $LASTEXITCODE
        if ($null -ne $code -and $code -ne 0) {
            if ($AllowedExitCodes -contains $code) {
                Write-StepLog -Path $stepLog -Message ('Exit code {0} (0x{0:X8}) is expected for this step; treating as success.' -f $code)
            } else {
                throw ('External command exited with code {0} (0x{0:X8})' -f $code)
            }
        }

        # Merging streams means non-terminating errors land here as objects rather
        # than reaching catch. Native stderr arrives as error records too and is
        # usually just progress chatter, so only count errors raised by PowerShell.
        $errorRecords = @($stepOutput | Where-Object {
            $_ -is [System.Management.Automation.ErrorRecord] -and
            $_.FullyQualifiedErrorId -notmatch 'NativeCommand'
        })

        $sw.Stop()
        $secs = [math]::Round($sw.Elapsed.TotalSeconds, 1)

        if ($errorRecords.Count -gt 0) {
            Write-Warning "COMPLETED WITH ERRORS: $Name ($secs s, $($errorRecords.Count) error record(s))"
            Write-StepLog -Path $stepLog -Message "COMPLETED WITH ERRORS | $($errorRecords.Count) error record(s) | Duration: ${secs}s"
            $script:Results.Add([pscustomobject]@{ Step = $Name; Status = 'Warning'; Seconds = $secs; Log = $stepLog })
        } else {
            Write-Host "COMPLETED: $Name ($secs s)" -ForegroundColor Green
            Write-StepLog -Path $stepLog -Message "COMPLETED | Duration: ${secs}s"
            $script:Results.Add([pscustomobject]@{ Step = $Name; Status = 'OK'; Seconds = $secs; Log = $stepLog })
        }
    } catch {
        $sw.Stop()
        $secs = [math]::Round($sw.Elapsed.TotalSeconds, 1)
        Write-Warning ("FAILED: $Name | $_")
        Write-StepLog -Path $stepLog -Message "FAILED | $_"
        $script:Results.Add([pscustomobject]@{ Step = $Name; Status = 'Failed'; Seconds = $secs; Log = $stepLog })
    }
}

function Remove-JsonComment {
    # Windows Terminal's settings.json is JSONC. Windows PowerShell 5.1's parser
    # rejects comments outright, so strip them before parsing. The alternation
    # matches whole string literals first, so a "//" inside a path or URL value is
    # preserved rather than being mistaken for a comment.
    param([Parameter(Mandatory)][AllowEmptyString()][string] $Text)

    $evaluator = [System.Text.RegularExpressions.MatchEvaluator] {
        param($m)
        if ($m.Groups[1].Success) { $m.Groups[1].Value } else { '' }
    }
    [regex]::Replace($Text, '("(?:\\.|[^"\\])*")|/\*[\s\S]*?\*/|//[^\r\n]*', $evaluator)
}

function Set-PwshAsWindowsTerminalDefault {
    # Points Windows Terminal's defaultProfile at the PowerShell 7 (PowershellCore)
    # profile. Only the defaultProfile value is rewritten; nothing else is touched.
    param([Parameter(Mandatory)][string] $LogDir)

    $candidates = @(
        "$env:LOCALAPPDATA\Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json",
        "$env:LOCALAPPDATA\Packages\Microsoft.WindowsTerminalPreview_8wekyb3d8bbwe\LocalState\settings.json",
        "$env:LOCALAPPDATA\Microsoft\Windows Terminal\settings.json"
    )
    $settingsPath = $candidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    if (-not $settingsPath) {
        Write-Host 'Windows Terminal settings.json not found; Terminal not installed for this user. Skipping.'
        return
    }
    Write-Host "Windows Terminal settings: $settingsPath"

    # Terminal rewrites settings.json from memory when it exits, which silently
    # reverts an edit made while it is running.
    if (Get-Process -Name 'WindowsTerminal', 'WindowsTerminalPreview' -ErrorAction SilentlyContinue) {
        Write-Warning 'Windows Terminal is running. It rewrites settings.json on exit and may revert this change; close it and re-run if the default does not stick.'
    }

    $raw = Get-Content -Raw -LiteralPath $settingsPath -ErrorAction Stop
    if ([string]::IsNullOrWhiteSpace($raw)) {
        throw "settings.json at $settingsPath is empty; refusing to edit it."
    }

    $cfg = $null
    try {
        $cfg = Remove-JsonComment -Text $raw | ConvertFrom-Json -ErrorAction Stop
    } catch {
        Write-Warning "settings.json did not parse even after stripping comments: $($_.Exception.Message)"
    }

    # Stable V5 UUID the PowershellCore generator assigns to the primary pwsh
    # install; used as a fallback if the profile is not yet materialized in the file.
    $wellKnownPwsh = '{574e775e-4f2a-5b96-ac1e-a2962a402336}'
    $ps7Guid = $null
    if ($cfg -and $cfg.profiles -and $cfg.profiles.list) {
        $p = $cfg.profiles.list | Where-Object { $_.source -eq 'Windows.Terminal.PowershellCore' } | Select-Object -First 1
        if (-not $p) { $p = $cfg.profiles.list | Where-Object { $_.commandline -match 'pwsh' } | Select-Object -First 1 }
        if ($p -and $p.guid) { $ps7Guid = $p.guid }
    }
    if (-not $ps7Guid) {
        $ps7Guid = $wellKnownPwsh
        Write-Host "No PowerShell Core profile present yet; using well-known GUID $ps7Guid (Terminal generates it on next launch)."
    } else {
        Write-Host "PowerShell 7 profile GUID: $ps7Guid"
    }

    # Read the current value from the parsed object when possible, and from the
    # raw text otherwise, so a parse failure cannot turn a no-op into a rewrite.
    $current = ''
    if ($cfg -and ($cfg.PSObject.Properties.Name -contains 'defaultProfile')) {
        $current = [string]$cfg.defaultProfile
    } elseif ($raw -match '"defaultProfile"\s*:\s*"([^"]*)"') {
        $current = $Matches[1]
    }

    if ($current -eq $ps7Guid) {
        Write-Host "Default profile is already PowerShell 7 ($ps7Guid). No change needed."
        return
    }
    Write-Host "Current default profile: $current"

    $backup = Join-Path $LogDir ("WindowsTerminal-settings-{0:yyyyMMdd-HHmmss}.json.bak" -f (Get-Date))
    try {
        Copy-Item -LiteralPath $settingsPath -Destination $backup -Force -ErrorAction Stop
    } catch {
        throw "Could not back up settings.json to $backup; refusing to edit without a backup. $($_.Exception.Message)"
    }
    Write-Host "Backed up settings.json -> $backup"

    $newKv = '"defaultProfile": "' + $ps7Guid + '"'
    # Match any string value, not just a GUID. Terminal also accepts a profile
    # name here, and the old GUID-only pattern missed that case and fell through
    # to the insert branch, producing a second defaultProfile key.
    $pattern = '"defaultProfile"\s*:\s*"[^"]*"'
    if ($raw -match $pattern) {
        $updated = [regex]::Replace($raw, $pattern, [System.Text.RegularExpressions.MatchEvaluator]{ param($m) $newKv })
    } else {
        # No defaultProfile key present: insert it right after the opening brace
        $updated = [regex]::Replace($raw, '\A(\s*\{)', [System.Text.RegularExpressions.MatchEvaluator]{ param($m) $m.Groups[1].Value + "`r`n    $newKv," })
    }

    # Guard against the duplicate-key failure mode: Terminal takes the last one,
    # so two keys would make the edit look applied while doing nothing.
    $keyCount = ([regex]::Matches($updated, '"defaultProfile"\s*:')).Count
    if ($keyCount -ne 1) {
        throw "Refusing to write: the edit produced $keyCount 'defaultProfile' keys, expected exactly 1."
    }

    # Only trust the edit if the result is still valid JSON (when the original was)
    if ($cfg) {
        try { $null = Remove-JsonComment -Text $updated | ConvertFrom-Json -ErrorAction Stop }
        catch { throw "Refusing to write: edited settings.json is not valid JSON ($($_.Exception.Message))." }
    }

    try {
        [System.IO.File]::WriteAllText($settingsPath, $updated, [System.Text.UTF8Encoding]::new($false))
    } catch {
        throw "Could not write settings.json (is Windows Terminal holding the file?): $($_.Exception.Message)"
    }
    Write-Host "Set Windows Terminal default profile to PowerShell 7 ($ps7Guid). Restart Windows Terminal to apply."
}


function Test-PendingReboot {
    # Reports whether Windows is waiting on a restart, and why. Every probe is a
    # Test-Path or Get-ItemProperty call, so a test can mock the registry instead
    # of needing a machine that genuinely owes a reboot.
    [CmdletBinding()]
    param()

    $pendingReboot  = $false
    $rebootReasons  = [System.Collections.Generic.List[string]]::new()

$pendingReboot  = $false
$rebootReasons  = [System.Collections.Generic.List[string]]::new()

$rebootKeys = [ordered]@{
    'Component Based Servicing'  = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'
    'CBS reboot in progress'     = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootInProgress'
    'Windows Update'             = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
    'Windows Update post-reboot' = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\PostRebootReporting'
}
foreach ($entry in $rebootKeys.GetEnumerator()) {
    if (Test-Path -LiteralPath $entry.Value) {
        $pendingReboot = $true
        $rebootReasons.Add($entry.Key)
    }
}

# PendingFileRenameOperations exists as an empty value on plenty of healthy
# machines, so test the value rather than the presence of the property.
try {
    $sm = Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' `
        -Name PendingFileRenameOperations -ErrorAction Stop
    $pendingRenames = @($sm.PendingFileRenameOperations | Where-Object { $_ })
    if ($pendingRenames.Count -gt 0) {
        $pendingReboot = $true
        $rebootReasons.Add("Pending file renames ($($pendingRenames.Count))")
    }
} catch { }

# A queued computer rename also needs a restart to take effect.
try {
    $activeName = (Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ActiveComputerName' -Name ComputerName -ErrorAction Stop).ComputerName
    $targetName = (Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ComputerName'       -Name ComputerName -ErrorAction Stop).ComputerName
    if ($activeName -ne $targetName) {
        $pendingReboot = $true
        $rebootReasons.Add("Computer rename pending ($activeName -> $targetName)")
    }
} catch { }

    [pscustomobject]@{
        IsPending = $pendingReboot
        Reasons   = $rebootReasons.ToArray()
    }
}

# ---------------------------------------------------------------------------
# Dot-source guard
#
# Definitions above, work below. Dot-sourcing stops here with the functions
# loaded and nothing updated.
# ---------------------------------------------------------------------------
if ($MyInvocation.InvocationName -eq '.') { return }

# ---------------------------------------------------------------------------
# 0. Elevation
# ---------------------------------------------------------------------------
$isAdmin = Test-IsAdministrator
if (-not $isAdmin -and -not $SkipElevation) {
    # Ask whether elevation is possible before asking for it. Without this the
    # script raises a UAC prompt a standard user can never satisfy, and reports
    # the refusal as though the user had declined it.
    $elevation = Test-ElevationCapability
    if (-not $elevation.CanElevate) {
        Write-Warning "Cannot run elevated: $($elevation.Reason)"
        Write-Warning 'Nothing has been changed. Re-run with -SkipElevation to run the steps that do not need administrator rights.'
        exit 64
    }
    Invoke-SelfElevation -BoundParameters $PSBoundParameters
}

if (-not $isAdmin) {
    Write-Warning 'Running without administrator rights. Steps that require admin will be skipped and listed in the summary.'
}

# TLS: no hardcoded override. Modern Windows/PowerShell negotiates TLS 1.2/1.3 automatically.
$originalOutputEncoding = Initialize-ConsoleEncoding

# ---------------------------------------------------------------------------
# 1. Logging
# ---------------------------------------------------------------------------
$logDir = Get-UpdateLogDirectory

# One stamp shared by the transcript and every step log, so a single run's files
# sort together and can be pruned as a unit.
$runStamp = '{0:yyyyMMdd-HHmmss}' -f (Get-Date)
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

$Results = [System.Collections.Generic.List[object]]::new()

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
        Write-Host "winget source update returned $LASTEXITCODE; continuing (a stale index is not fatal)."
        $global:LASTEXITCODE = 0
    }

    # 'upgrade --all' does not reliably update App Installer (winget itself),
    # so ask for it by ID.
    winget upgrade --id Microsoft.AppInstaller --exact --source winget --silent `
        --accept-source-agreements --accept-package-agreements --disable-interactivity
    if ($WingetNothingToDo -contains $LASTEXITCODE) {
        Write-Host 'App Installer (winget) is already at the latest version.'
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
        Write-Host 'winget reports nothing left to upgrade.'
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
            Write-Host 'winget does not list PowerShell 7, but pwsh.exe is present; treating as installed.'
            $isInstalled = $true
        }

        if (-not $isInstalled) {
            Write-Host 'PowerShell 7 not detected; installing the MSI package via winget...'
            # --installer-type wix forces the MSI (winget 7.6+ defaults to MSIX) so it
            # installs to C:\Program Files\PowerShell\7 where Terminal expects it.
            winget install --id $id --exact --source winget --installer-type wix `
                --accept-source-agreements --accept-package-agreements --disable-interactivity
            if ($LASTEXITCODE -ne 0) { throw "winget install returned $LASTEXITCODE" }
        } else {
            Write-Host 'PowerShell 7 present; checking for an upgrade...'
            winget upgrade --id $id --exact --include-unknown `
                --accept-source-agreements --accept-package-agreements --disable-interactivity
            if ($WingetNothingToDo -contains $LASTEXITCODE) {
                Write-Host 'PowerShell 7 is already at the latest version.'
                $global:LASTEXITCODE = 0
            } elseif ($LASTEXITCODE -ne 0) {
                throw "winget upgrade returned $LASTEXITCODE"
            }
        }

        if (Test-Path -LiteralPath $exe) {
            $reported = & $exe -NoProfile -Command '$PSVersionTable.PSVersion.ToString()'
            if ($LASTEXITCODE -ne 0) { $global:LASTEXITCODE = 0 }
            Write-Host "Installed pwsh version: $reported"
        } else {
            Write-Host "Note: $exe not found after the winget step (an MSIX install lands elsewhere)."
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
    $c2r   = $roots |
        ForEach-Object { Join-Path $_ 'Common Files\Microsoft Shared\ClickToRun\OfficeC2RClient.exe' } |
        Where-Object { Test-Path -LiteralPath $_ } |
        Select-Object -First 1

    if (-not $c2r) {
        Write-Host 'OfficeC2RClient.exe not found; no click-to-run Office install. Skipping.'
        return
    }

    # The same action as the "Update Now" button, minus the prompts. C2R hands
    # the work to its background service and returns immediately, so exit 0 here
    # means "update requested", not "update applied".
    & $c2r /update user updatepromptuser=false displaylevel=false
    if ($LASTEXITCODE -ne 0) {
        Write-Host "OfficeC2RClient returned $LASTEXITCODE; the update request may not have been accepted."
        $global:LASTEXITCODE = 0
    }
    Write-Host "Requested a Microsoft 365 Apps update via $c2r (applied in the background)."
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
        Write-Host 'No PowerShellGet/PSResourceGet available; skipping.'
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
    if     (Get-Command pymanager -ErrorAction SilentlyContinue) { pymanager install --update }
    elseif (Get-Command py        -ErrorAction SilentlyContinue) { py install --update }
    else   { Write-Host 'Python Install Manager not found; skipping.' }
}

Invoke-Step -Name 'uv' -RequiresCommand 'uv' -Action {
    uv self update
    # uv installed by a package manager refuses to self-update, which is correct
    # behaviour rather than a run failure.
    if ($LASTEXITCODE -ne 0) {
        Write-Host "uv self update returned $LASTEXITCODE (expected when uv was installed via a package manager)."
        $global:LASTEXITCODE = 0
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
    npm install -g npm@latest
    if ($LASTEXITCODE -ne 0) {
        Write-Error "npm self-update failed with exit code $LASTEXITCODE."
        $global:LASTEXITCODE = 0
    }

    if ($UpdateGlobalNpm) {
        npm update -g
        if ($LASTEXITCODE -ne 0) {
            Write-Error "npm update -g failed with exit code $LASTEXITCODE."
            $global:LASTEXITCODE = 0
        }
    } else {
        Write-Host 'Skipping global package upgrade (use -UpdateGlobalNpm to enable).'
    }
}

# ---------------------------------------------------------------------------
# 6. .NET global tools
# ---------------------------------------------------------------------------
Invoke-Step -Name '.NET global tools' -RequiresCommand 'dotnet' -Action {
    # 'dotnet' exists for runtime-only installs too, and 'dotnet --version' fails
    # outright when there is no SDK or when a global.json pins a missing one.
    # Validate the string before casting it to an int.
    $verRaw = (dotnet --version 2>&1 | Select-Object -First 1 | Out-String).Trim()
    $verOk  = ($LASTEXITCODE -eq 0)
    $global:LASTEXITCODE = 0

    # Evaluate the match on its own: with a short-circuited -or, $Matches could
    # still be holding results from an earlier, unrelated match.
    if (-not $verOk) {
        Write-Host "'dotnet --version' failed ('$verRaw'); no usable SDK, skipping global tools."
        return
    }
    if ($verRaw -notmatch '^(\d+)\.') {
        Write-Host "Could not parse an SDK version from '$verRaw'; skipping global tools."
        return
    }

    $major = [int]$Matches[1]
    if ($major -lt 6) {
        Write-Host ".NET global tool update skipped (SDK $verRaw; requires 6 or higher)."
        return
    }

    dotnet tool update --all --global
    if ($LASTEXITCODE -ne 0) {
        # '--all' is not accepted by every SDK that reports 6+. Fall back to
        # enumerating the installed tools and updating them one at a time.
        $global:LASTEXITCODE = 0
        Write-Host "'dotnet tool update --all' was rejected; updating tools individually."

        $tools = @(dotnet tool list --global |
            Select-Object -Skip 2 |
            ForEach-Object { ($_ -split '\s+')[0] } |
            Where-Object { $_ -and $_ -notmatch '^-+$' })
        $global:LASTEXITCODE = 0

        if (-not $tools) {
            Write-Host 'No global .NET tools installed.'
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
        Write-Host "dotnet workload update returned $LASTEXITCODE (no SDK, or no workloads to update)."
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
        Write-Host "-> $($phase.Label)"
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
        Write-Host 'No gh extensions installed; nothing to upgrade.'
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
        Write-Host 'wsl.exe is present but WSL is not installed or enabled; skipping.'
        return
    }
    $global:LASTEXITCODE = 0

    wsl --update
    if ($LASTEXITCODE -ne 0) {
        Write-Host "wsl --update returned $LASTEXITCODE (commonly 'no updates available')."
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
        Write-Host "Defender status unavailable ($($_.Exception.Message)); skipping signature update."
        return
    }
    if (-not $mp.AMServiceEnabled) {
        Write-Host 'Defender antimalware service is disabled (third-party AV in use?); skipping.'
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
                Write-Host 'Registered the Microsoft Update service.'
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
$Results | Format-Table -AutoSize -Property Step, Status, Seconds

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

Write-Host "Finished $(Get-Date). Detailed logs saved to: $logDir" -ForegroundColor Green
if ($failedSteps.Count) {
    Write-Host "$($failedSteps.Count) step(s) failed." -ForegroundColor Red
}

if ($transcriptRunning) { try { Stop-Transcript | Out-Null } catch { } }
try { [Console]::OutputEncoding = $originalOutputEncoding } catch { }

# Exit code = number of failed steps, so a scheduled task or wrapper can detect
# a bad run. 'Warning' steps completed and do not count.
exit $failedSteps.Count