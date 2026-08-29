#Requires -Version 5.1
<#
.SYNOPSIS
    One-shot maintenance script that updates everything on a Windows laptop
    through the package managers and update channels it can find.

.DESCRIPTION
    Replaces a flat list of update commands with a guarded runner that:
      - Self-elevates to Administrator (needed for Windows Update / Defender).
      - Detects which tools are installed and skips the ones that are not.
      - Isolates each step so one failure does not stop the rest.
      - Writes a timestamped transcript and prints a summary table at the end.

    Covered channels (each runs only if the tool is present):
      winget, Microsoft Store apps, PowerShell modules, PowerShell help,
      Python (Python Install Manager), uv, pipx, npm (global), .NET global
      tools, Chocolatey, Scoop, rustup, WSL kernel, Microsoft Defender
      signatures, and Windows Update.

.PARAMETER IncludeWindowsUpdate
    Install pending OS and driver updates via the PSWindowsUpdate module.
    Default: $true. Requires admin and may require a reboot.

.PARAMETER AutoReboot
    Allow Windows Update to reboot automatically if required. Default: $false
    (the script reports a pending reboot instead of forcing one).

.PARAMETER IncludePrerelease
    Include prerelease/preview builds where the tool supports it. Default: $false.

.PARAMETER UpdateGlobalNpm
    Update global npm packages in addition to npm itself. Default: $false
    (global package upgrades occasionally break pinned toolchains).

.PARAMETER SkipElevation
    Do not relaunch elevated. Steps that need admin will simply fail and be
    flagged in the summary. Useful for unattended/standard-user runs.

.EXAMPLE
    .\Update-Everything.ps1
    Runs every detected channel, including Windows Update, with no auto-reboot.

.EXAMPLE
    .\Update-Everything.ps1 -IncludeWindowsUpdate:$false
    Updates apps and tools but leaves the OS alone.

.NOTES
    Run from an elevated PowerShell 7 prompt for best results:
        pwsh -NoProfile -ExecutionPolicy Bypass -File .\Update-Everything.ps1
#>

[CmdletBinding()]
param(
    [bool]   $IncludeWindowsUpdate = $true,
    [switch] $AutoReboot,
    [switch] $IncludePrerelease,
    [switch] $UpdateGlobalNpm,
    [switch] $SkipElevation
)

# ---------------------------------------------------------------------------
# 0. Elevation
# ---------------------------------------------------------------------------
$isAdmin = ([Security.Principal.WindowsPrincipal] `
    [Security.Principal.WindowsIdentity]::GetCurrent()
).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin -and -not $SkipElevation) {
    Write-Host "Elevating to Administrator..." -ForegroundColor Yellow
    $pwshPath = (Get-Process -Id $PID).Path
    $argList  = @(
        '-NoProfile'
        '-ExecutionPolicy','Bypass'
        '-File', "`"$PSCommandPath`""
    ) + $PSBoundParameters.GetEnumerator().ForEach({
            if ($_.Value -is [switch]) { if ($_.Value.IsPresent) { "-$($_.Key)" } }
            else { "-$($_.Key)", $_.Value }
        })
    Start-Process -FilePath $pwshPath -Verb RunAs -ArgumentList $argList
    return
}

# TLS 1.2 for older hosts (PowerShell 5.1 / PSGallery)
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

# ---------------------------------------------------------------------------
# 1. Logging + step runner
# ---------------------------------------------------------------------------
$logDir  = Join-Path $env:USERPROFILE 'UpdateLogs'
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir | Out-Null }
$logFile = Join-Path $logDir ("Update-Everything-{0:yyyyMMdd-HHmmss}.log" -f (Get-Date))
Start-Transcript -Path $logFile -Append | Out-Null

$Results = [System.Collections.Generic.List[object]]::new()

function Invoke-Step {
    param(
        [Parameter(Mandatory)][string]      $Name,
        [Parameter(Mandatory)][scriptblock] $Action,
        [string]                            $RequiresCommand
    )
    if ($RequiresCommand -and -not (Get-Command $RequiresCommand -ErrorAction SilentlyContinue)) {
        Write-Host ("SKIP  {0} (not installed)" -f $Name) -ForegroundColor DarkGray
        $Results.Add([pscustomobject]@{ Step = $Name; Status = 'Skipped'; Seconds = 0 })
        return
    }
    Write-Host ("`n=== {0} ===" -f $Name) -ForegroundColor Cyan
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        & $Action
        $sw.Stop()
        $Results.Add([pscustomobject]@{ Step = $Name; Status = 'OK'; Seconds = [math]::Round($sw.Elapsed.TotalSeconds,1) })
    }
    catch {
        $sw.Stop()
        Write-Warning ("{0} failed: {1}" -f $Name, $_.Exception.Message)
        $Results.Add([pscustomobject]@{ Step = $Name; Status = 'Failed'; Seconds = [math]::Round($sw.Elapsed.TotalSeconds,1) })
    }
}

Write-Host "Maintenance run started $(Get-Date)  |  Admin: $isAdmin  |  Log: $logFile" -ForegroundColor Green

# ---------------------------------------------------------------------------
# 2. winget  (apps from winget + Microsoft Store sources)
# ---------------------------------------------------------------------------
Invoke-Step -Name 'winget (all sources)' -RequiresCommand 'winget' -Action {
    winget upgrade --all --include-unknown --silent `
        --accept-source-agreements --accept-package-agreements --disable-interactivity
}

# ---------------------------------------------------------------------------
# 3. PowerShell modules + help
# ---------------------------------------------------------------------------
Invoke-Step -Name 'PowerShell modules' -Action {
    $ErrorActionPreference = 'Stop'
    if (Get-Command Update-PSResource -ErrorAction SilentlyContinue) {
        Update-PSResource -Name * -ErrorAction SilentlyContinue
    }
    elseif (Get-Command Update-Module -ErrorAction SilentlyContinue) {
        Update-Module -Force -ErrorAction SilentlyContinue
    }
    else { Write-Host 'No PowerShellGet/PSResourceGet available; skipping.' }
}

Invoke-Step -Name 'PowerShell help' -Action {
    Update-Help -Force -ErrorAction SilentlyContinue
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
}

Invoke-Step -Name 'pipx packages' -RequiresCommand 'pipx' -Action {
    pipx upgrade-all
}

# ---------------------------------------------------------------------------
# 5. Node / npm
# ---------------------------------------------------------------------------
Invoke-Step -Name 'npm' -RequiresCommand 'npm' -Action {
    npm install -g npm@latest
    if ($UpdateGlobalNpm) { npm update -g }
    else { Write-Host 'Skipping global package upgrade (use -UpdateGlobalNpm to enable).' }
}

# ---------------------------------------------------------------------------
# 6. .NET global tools
# ---------------------------------------------------------------------------
Invoke-Step -Name '.NET global tools' -RequiresCommand 'dotnet' -Action {
    # --all requires .NET 6 SDK or later
    dotnet tool update --all --global
}

# ---------------------------------------------------------------------------
# 7. Other package managers (run only if installed)
# ---------------------------------------------------------------------------
Invoke-Step -Name 'Chocolatey' -RequiresCommand 'choco' -Action {
    choco upgrade all -y
}

Invoke-Step -Name 'Scoop' -RequiresCommand 'scoop' -Action {
    scoop update      # update scoop itself + buckets
    scoop update *    # update all installed apps
    scoop cleanup *   # remove old versions
}

Invoke-Step -Name 'rustup' -RequiresCommand 'rustup' -Action {
    rustup update
}

# ---------------------------------------------------------------------------
# 8. WSL kernel  (distro packages such as apt are updated inside each distro)
# ---------------------------------------------------------------------------
Invoke-Step -Name 'WSL kernel' -RequiresCommand 'wsl' -Action {
    wsl --update
}

# ---------------------------------------------------------------------------
# 9. Microsoft Defender signatures
# ---------------------------------------------------------------------------
Invoke-Step -Name 'Defender signatures' -RequiresCommand 'Update-MpSignature' -Action {
    Update-MpSignature -ErrorAction Stop
}

# ---------------------------------------------------------------------------
# 10. Windows Update (OS + drivers) via PSWindowsUpdate
# ---------------------------------------------------------------------------
if ($IncludeWindowsUpdate) {
    Invoke-Step -Name 'Windows Update' -Action {
        $ErrorActionPreference = 'Stop'
        if (-not $isAdmin) { throw 'Administrator rights required.' }
        if (-not (Get-Module -ListAvailable -Name PSWindowsUpdate)) {
            # PSWindowsUpdate is a community module published to the PowerShell Gallery.
            Install-Module PSWindowsUpdate -Force -Scope CurrentUser -AcceptLicense -ErrorAction Stop
        }
        Import-Module PSWindowsUpdate -ErrorAction Stop
        $params = @{ AcceptAll = $true; Install = $true }
        if ($AutoReboot)        { $params.AutoReboot  = $true } else { $params.IgnoreReboot = $true }
        if ($IncludePrerelease) { }  # WU has no prerelease toggle; placeholder for symmetry
        Get-WindowsUpdate @params
    }
}
else {
    Write-Host "`nSKIP  Windows Update (disabled by parameter)" -ForegroundColor DarkGray
    $Results.Add([pscustomobject]@{ Step = 'Windows Update'; Status = 'Skipped'; Seconds = 0 })
}

# ---------------------------------------------------------------------------
# 11. Summary + reboot check
# ---------------------------------------------------------------------------
Write-Host "`n================ SUMMARY ================" -ForegroundColor Green
$Results | Format-Table -AutoSize

$pendingReboot = $false
$rebootKeys = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
)
foreach ($k in $rebootKeys) { if (Test-Path $k) { $pendingReboot = $true } }
if ($pendingReboot) {
    Write-Host "`nA reboot is pending. Restart to finish applying updates." -ForegroundColor Yellow
}

Write-Host "`nFinished $(Get-Date). Full log: $logFile" -ForegroundColor Green
Stop-Transcript | Out-Null
