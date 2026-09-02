#Requires -Version 5.1

<#
.SYNOPSIS
    Moves this machine's PowerShell 7 from the Store (MSIX) package to the MSI
    install, from Windows PowerShell.

.DESCRIPTION
    The Store package is the install everything else has to work around: a
    packaged pwsh cannot run elevated at all, its install path carries the
    version and stops existing at the next update, and its execution alias is
    a zero-byte reparse point Task Scheduler cannot launch. The MSI has none
    of those problems, and winget has defaulted new PowerShell installs to the
    MSIX package since 7.6, so machines arrive in this state without anyone
    choosing it.

    Run it from Windows PowerShell, which is never packaged:

        $mover = Join-Path $env:TEMP 'Convert-PowerShell7ToMsi.ps1'
        Invoke-WebRequest https://raw.githubusercontent.com/briankronberg/UpdateEverything/main/Convert-PowerShell7ToMsi.ps1 -OutFile $mover -UseBasicParsing
        Unblock-File $mover
        powershell -NoProfile -ExecutionPolicy Bypass -File $mover

    What it does, in order:

      1. Installs the current MSI release straight from
         github.com/PowerShell/PowerShell when no MSI install is present --
         not through winget, whose Microsoft.PowerShell package is the MSIX
         being removed -- and verifies the installed pwsh answers.
      2. Removes the Store package, and its provisioning where one exists, so
         Windows does not hand the package back to the next new user. This
         happens only after the MSI answered.
      3. Points the Windows Terminal default profile at the MSI install's
         profile when the previous default is about to disappear with the
         package. A default that was already Windows PowerShell, cmd, or a
         profile that survives is left alone.
      4. Reports what carries over on its own: profiles, per-user modules and
         PSReadLine history live under Documents\PowerShell and APPDATA, which
         both installs share, so there is nothing to move. The one thing that
         cannot carry is an all-users profile inside the package, which the
         package's read-only install directory prevented anyone from writing.
      5. Lists scheduled tasks whose actions run a WindowsApps pwsh. They break
         whenever the Store package updates or leaves, so they need
         re-registering against the MSI path -- listed, never edited.

    Everything destructive happens after one summary and one question.
    -ReportOnly stops before it; -Force skips the question.

.PARAMETER ReportOnly
    Discover and report, change nothing. Needs no elevation.

.PARAMETER Force
    Skip the confirmation question. The summary still prints.

.PARAMETER SkipTerminalDefault
    Leave Windows Terminal's settings.json untouched whatever the default
    profile points at.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\Convert-PowerShell7ToMsi.ps1 -ReportOnly

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\Convert-PowerShell7ToMsi.ps1

.OUTPUTS
    Progress and a report. Exits 1 when a step it committed to fails.
#>

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Write-Host is the user interface of an attended console migration. Its output is a plan and a report a person reads and answers, not data a caller consumes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'The script prints its plan and asks once before changing anything; -ReportOnly is the dry run, and the internal functions run only after that gate.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'False positive on the [MatchEvaluator] { param($m) ... } delegate, whose signature requires the parameter whether or not it is read.')]
[CmdletBinding()]
param(
    [switch] $ReportOnly,
    [switch] $Force,
    [switch] $SkipTerminalDefault
)

$ErrorActionPreference = 'Stop'

# Well-known Windows Terminal profile GUIDs: the V5 UUIDs its generators assign.
# MsiPwsh is the profile for a %ProgramFiles%\PowerShell install; the other two
# are defaults a person may have chosen on purpose, which removal cannot break.
$script:MsiPwshProfile   = '{574e775e-4f2a-5b96-ac1e-a2962a402336}'
$script:SurvivingDefault = @(
    $script:MsiPwshProfile
    '{61c54bbd-c2c6-5271-96e7-009a87ff44bf}'   # Windows PowerShell
    '{0caa0dad-35be-5f56-a8ff-afceeeaa6101}'   # cmd
)

function Test-PackagedHost {
    # The Store package cannot remove the process it is hosting, and a packaged
    # pwsh cannot elevate. Windows PowerShell is never packaged, so it is the
    # host this script asks for.
    $processPath = (Get-Process -Id $PID).Path
    if (-not $processPath) { return $false }
    foreach ($root in @("$env:ProgramFiles\WindowsApps", "$env:LOCALAPPDATA\Microsoft\WindowsApps")) {
        if ($processPath -like (Join-Path $root '*')) { return $true }
    }
    $false
}

function Get-MsiPwsh {
    $path = Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe'
    if (Test-Path -LiteralPath $path) { return $path }
    $null
}

function Get-StorePackage {
    # Stable only. The Preview package is a deliberate side-by-side install and
    # is reported, not migrated.
    @(Get-AppxPackage -Name 'Microsoft.PowerShell' -ErrorAction SilentlyContinue)
}

function Get-WindowsAppsTask {
    # Read-only: a task that runs a WindowsApps pwsh breaks when the package
    # moves or leaves, and the fix is re-registering it, not editing XML behind
    # Task Scheduler's back.
    $found = @()
    try {
        foreach ($task in @(Get-ScheduledTask -ErrorAction Stop)) {
            foreach ($action in @($task.Actions)) {
                $command = "$($action.Execute) $($action.Arguments)"
                if ($command -match 'WindowsApps\\.*pwsh' -or $command -match 'WindowsApps\\Microsoft\.PowerShell') {
                    $found += ('{0}{1}' -f $task.TaskPath, $task.TaskName)
                    break
                }
            }
        }
    } catch {
        Write-Verbose "Could not enumerate scheduled tasks: $($_.Exception.Message)"
    }
    $found
}

function Install-MsiPwsh {
    # Straight from the PowerShell release, not winget: winget's
    # Microsoft.PowerShell has installed the MSIX package by default since 7.6,
    # which is the install this script exists to remove.
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

    $arch = switch ($env:PROCESSOR_ARCHITECTURE) {
        'ARM64' { 'arm64' }
        'x86'   { 'x86' }
        default { 'x64' }
    }

    Write-Host "Asking github.com/PowerShell/PowerShell for the current release..."
    $release = Invoke-RestMethod -Uri 'https://api.github.com/repos/PowerShell/PowerShell/releases/latest' -UseBasicParsing
    $asset = @($release.assets | Where-Object { $_.name -like "PowerShell-*-win-$arch.msi" })[0]
    if (-not $asset) {
        throw "The current release ($($release.tag_name)) carries no win-$arch MSI."
    }

    $msi = Join-Path $env:TEMP $asset.name
    Write-Host "Downloading $($asset.name)..."
    Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $msi -UseBasicParsing

    try {
        Write-Host 'Installing (msiexec, quiet)...'
        $process = Start-Process msiexec.exe -ArgumentList '/i', "`"$msi`"", '/qn', '/norestart' -Wait -PassThru
        # 3010 is success with a reboot pending, which the MSI can report when a
        # file it carries was in use.
        if ($process.ExitCode -notin 0, 3010) {
            throw "msiexec exited with $($process.ExitCode)."
        }
        if ($process.ExitCode -eq 3010) {
            Write-Host 'The installer asked for a restart to finish replacing a file in use.' -ForegroundColor DarkYellow
        }
    } finally {
        Remove-Item -LiteralPath $msi -Force -ErrorAction SilentlyContinue
    }
}

function Set-TerminalDefaultToMsi {
    # The same care Set-PwshAsWindowsTerminalDefault in the UpdateEverything
    # module takes, reduced to this one edit: back the file up, make exactly
    # one defaultProfile change, refuse anything surprising.
    $settingsPath = Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json'
    if (-not (Test-Path -LiteralPath $settingsPath)) {
        Write-Host 'Windows Terminal settings.json not found; nothing to point at the MSI profile.'
        return
    }

    $raw = Get-Content -Raw -LiteralPath $settingsPath
    if ([string]::IsNullOrWhiteSpace($raw)) {
        Write-Warning 'settings.json is empty; leaving it alone.'
        return
    }

    $current = ''
    if ($raw -match '"defaultProfile"\s*:\s*"([^"]*)"') { $current = $Matches[1] }

    if ($script:SurvivingDefault -contains $current) {
        Write-Host "Windows Terminal default profile survives the migration ($current); leaving it."
        return
    }
    # A default declared with its own block in the file is a profile the person
    # made or pinned. If its command line is not a WindowsApps pwsh it survives
    # too, and the choice stands.
    if ($current -and $raw -match ('"guid"\s*:\s*"' + [regex]::Escape($current) + '"') -and
        $raw -notmatch 'WindowsApps[^"]*pwsh') {
        Write-Host "Windows Terminal default profile is one declared in settings.json ($current); leaving it."
        return
    }

    if (Get-Process -Name 'WindowsTerminal', 'WindowsTerminalPreview' -ErrorAction SilentlyContinue) {
        Write-Warning 'Windows Terminal is running. It rewrites settings.json on exit and may revert this change; close it and re-run if the default does not stick.'
    }

    $backup = Join-Path $env:TEMP ("WindowsTerminal-settings-{0:yyyyMMdd-HHmmss}.json.bak" -f (Get-Date))
    Copy-Item -LiteralPath $settingsPath -Destination $backup -Force
    Write-Host "Backed up settings.json -> $backup"

    $newKv = '"defaultProfile": "' + $script:MsiPwshProfile + '"'
    $pattern = '"defaultProfile"\s*:\s*"[^"]*"'
    if ($raw -match $pattern) {
        $updated = [regex]::Replace($raw, $pattern, [System.Text.RegularExpressions.MatchEvaluator]{ param($m) $newKv })
    } else {
        $updated = [regex]::Replace($raw, '\A(\s*\{)', [System.Text.RegularExpressions.MatchEvaluator]{ param($m) $m.Groups[1].Value + "`r`n    $newKv," })
    }

    $keyCount = ([regex]::Matches($updated, '"defaultProfile"\s*:')).Count
    if ($keyCount -ne 1) {
        Write-Warning "The edit would leave $keyCount defaultProfile keys; leaving settings.json alone. The backup is at $backup."
        return
    }

    [System.IO.File]::WriteAllText($settingsPath, $updated, [System.Text.UTF8Encoding]::new($false))
    Write-Host "Windows Terminal default profile now names the MSI install ($script:MsiPwshProfile)."
}

try {
    if ($PSVersionTable.PSEdition -ne 'Desktop' -or (Test-PackagedHost)) {
        throw ('Run this from Windows PowerShell (powershell.exe), which is never packaged: ' +
            'a packaged host cannot elevate, and the Store pwsh cannot remove the package running it.')
    }

    # ------------------------------------------------------------------ state
    $msiPwsh  = Get-MsiPwsh
    $store    = Get-StorePackage
    $preview  = @(Get-AppxPackage -Name 'Microsoft.PowerShellPreview' -ErrorAction SilentlyContinue)
    $tasks    = Get-WindowsAppsTask
    $profiles = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'PowerShell'

    Write-Host ''
    Write-Host 'PowerShell 7: Store package -> MSI install' -ForegroundColor Cyan
    Write-Host ''
    if ($msiPwsh) {
        $msiVersion = & $msiPwsh -NoProfile -NoLogo -Command '$PSVersionTable.PSVersion.ToString()'
        Write-Host "  MSI install       : present, $msiVersion ($msiPwsh)"
    } else {
        Write-Host '  MSI install       : absent -- will be installed from the PowerShell release'
    }
    if ($store.Count) {
        Write-Host "  Store package     : $($store[0].Version) -- will be removed"
    } else {
        Write-Host '  Store package     : absent'
    }
    if ($preview.Count) {
        Write-Host "  Preview package   : $($preview[0].Version) -- a side-by-side install; left alone" -ForegroundColor DarkYellow
    }
    if (Test-Path -LiteralPath $profiles) {
        Write-Host "  Profiles, modules : $profiles -- shared by both installs; nothing to move"
    } else {
        Write-Host '  Profiles, modules : none found under Documents\PowerShell; nothing to move'
    }
    Write-Host '  Command history   : APPDATA\Microsoft\Windows\PowerShell\PSReadLine -- shared; nothing to move'
    if ($tasks.Count) {
        Write-Host ''
        Write-Host '  Scheduled tasks running a WindowsApps pwsh (re-register these against the MSI path):' -ForegroundColor Yellow
        foreach ($task in $tasks) { Write-Host "    $task" }
    }
    Write-Host ''

    if (-not $msiPwsh -and -not $store.Count) {
        Write-Host 'No PowerShell 7 found at all. Install the MSI with this script or from aka.ms/powershell; there is nothing to migrate.'
        return
    }
    if ($msiPwsh -and -not $store.Count) {
        Write-Host 'Already on the MSI install with no Store package. Nothing to do.' -ForegroundColor Green
        return
    }

    if ($ReportOnly) {
        Write-Host 'Report only; nothing was changed.' -ForegroundColor DarkGray
        return
    }

    # ------------------------------------------------------------- elevation
    $identity = [Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()
    if (-not $identity.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Write-Host 'Elevation is needed to install the MSI and remove the package provisioning. Asking...' -ForegroundColor DarkGray
        $forward = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"")
        if ($Force)               { $forward += '-Force' }
        if ($SkipTerminalDefault) { $forward += '-SkipTerminalDefault' }
        $child = Start-Process powershell.exe -Verb RunAs -ArgumentList $forward -Wait -PassThru
        exit $child.ExitCode
    }

    if (-not $Force) {
        $answer = (Read-Host 'Proceed? [y/N]').Trim()
        if ($answer -notmatch '^(y|yes)$') {
            Write-Host 'Nothing was changed.'
            return
        }
    }

    # ------------------------------------------------------------------ MSI
    if (-not $msiPwsh) {
        Install-MsiPwsh
        $msiPwsh = Get-MsiPwsh
        if (-not $msiPwsh) { throw 'The MSI installed without error but pwsh.exe is not at the expected path.' }
    }

    # The verification the removal waits for: the MSI pwsh answers.
    $msiVersion = & $msiPwsh -NoProfile -NoLogo -Command '$PSVersionTable.PSVersion.ToString()'
    if ($LASTEXITCODE -ne 0 -or -not $msiVersion) {
        throw 'The MSI pwsh did not answer; the Store package stays until it does.'
    }
    Write-Host "MSI PowerShell $msiVersion answers." -ForegroundColor Green

    # ---------------------------------------------------------- Store removal
    if ($store.Count) {
        Write-Host 'Removing the Store package...'
        $store | Remove-AppxPackage
        try {
            $provisioned = @(Get-AppxProvisionedPackage -Online -ErrorAction Stop |
                Where-Object { $_.DisplayName -eq 'Microsoft.PowerShell' })
            foreach ($package in $provisioned) {
                $null = Remove-AppxProvisionedPackage -Online -PackageName $package.PackageName -ErrorAction Stop
                Write-Host 'Removed the provisioning too, so new user accounts do not get the package back.'
            }
        } catch {
            Write-Verbose "Provisioning check: $($_.Exception.Message)"
        }
        if (@(Get-StorePackage).Count) {
            throw 'The Store package is still present after removal.'
        }
        Write-Host 'Store package removed.' -ForegroundColor Green
    }

    # ------------------------------------------------------ Terminal default
    if (-not $SkipTerminalDefault) {
        Set-TerminalDefaultToMsi
    }

    Write-Host ''
    Write-Host 'Done. Open a new console for PATH to pick up the MSI install;' -ForegroundColor Green
    Write-Host 'profiles, modules and history are where both installs read them.' -ForegroundColor Green
    if ($tasks.Count) {
        Write-Host "Re-register the $($tasks.Count) scheduled task(s) listed above against $msiPwsh." -ForegroundColor Yellow
    }
} catch {
    # An explicit exit code, because what an uncaught throw returns under -File
    # has differed between hosts.
    Write-Error -ErrorAction Continue -Message "$_"
    exit 1
}
