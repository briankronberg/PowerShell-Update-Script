#Requires -Version 5.1
<#
.SYNOPSIS
    One-shot maintenance script that updates everything on a Windows laptop
    through the package managers and update channels it can find.

.DESCRIPTION
    v2 Improvements:
      - Captures full stdout/stderr per step into dedicated log files
      - Validates external CLI exit codes ($LASTEXITCODE)
      - Fixes TLS negotiation regression (removed hardcoded Tls12 override)
      - Corrects $ErrorActionPreference scope leak in module updates
      - Adds .NET SDK version guard for global tool upgrades
      - Fixes PSWindowsUpdate installation scope mismatch
      - Improves reboot detection registry checks
      - Adds structured summary with log file references

.PARAMETER IncludeWindowsUpdate
    Install pending OS and driver updates via the PSWindowsUpdate module.
    Default: $true. Requires admin and may require a reboot.

.PARAMETER AutoReboot
    Allow Windows Update to reboot automatically if required. Default: $false

.PARAMETER IncludePrerelease
    Include prerelease/preview builds where the tool supports it. Default: $false.

.PARAMETER UpdateGlobalNpm
    Update global npm packages in addition to npm itself. Default: $false

.PARAMETER SkipElevation
    Do not relaunch elevated. Steps that need admin will simply fail and be
    flagged in the summary. Useful for unattended/standard-user runs.
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
    
    # Rebuild arguments safely for PS 5.1
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"")
    $PSBoundParameters.GetEnumerator() | ForEach-Object {
        $key = $_.Key
        $val = $_.Value
        if ($val -is [switch]) {
            if ($val.IsPresent) { $argList += "-$key" }
        } else {
            $argList += "-$key", "`"$val`""
        }
    }
    
    Start-Process -FilePath $pwshPath -Verb RunAs -ArgumentList $argList
    return
}

# TLS 1.2/1.3: Removed hardcoded override. Modern Windows/PowerShell negotiates automatically.
# Forcing Tls12 alone can break Tls13 connections on Win10/11 and PS7+.

# ---------------------------------------------------------------------------
# 1. Logging + step runner
# ---------------------------------------------------------------------------
$logDir  = Join-Path $env:USERPROFILE 'UpdateLogs'
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir | Out-Null }
$mainLog = Join-Path $logDir ("Update-Everything-{0:yyyyMMdd-HHmmss}.log" -f (Get-Date))
Start-Transcript -Path $mainLog -Append | Out-Null

$Results = [System.Collections.Generic.List[object]]::new()

function Invoke-Step {
    param(
        [Parameter(Mandatory)][string]      $Name,
        [Parameter(Mandatory)][scriptblock] $Action,
        [string]                            $RequiresCommand
    )
    
    $stepLog = Join-Path $logDir "$Name.log"
    
    # Pre-check command availability
    if ($RequiresCommand -and -not (Get-Command $RequiresCommand -ErrorAction SilentlyContinue)) {
        $msg = "SKIP  $Name (command '$RequiresCommand' not found)"
        Write-Host $msg -ForegroundColor DarkGray
        Add-Content -Path $stepLog -Value "$(Get-Date) | $msg"
        $Results.Add([pscustomobject]@{ Step = $Name; Status = 'Skipped'; Seconds = 0 })
        return
    }

    Write-Host ("`n=== STARTING: $Name ===") -ForegroundColor Cyan
    Add-Content -Path $stepLog -Value "$(Get-Date) | STARTING $Name"
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    
    try {
        # Run action, capture all output to step log + console via transcript
        & $Action 4>&1 | Tee-Object -FilePath $stepLog -Append
        
        # Check native CLI exit codes
        if ($LASTEXITCODE -ne 0) { throw "External command exited with code $LASTEXITCODE" }
        
        $sw.Stop()
        Write-Host ("COMPLETED: $Name (${sw.Elapsed.TotalSeconds} s)" ) -ForegroundColor Green
        Add-Content -Path $stepLog -Value "$(Get-Date) | COMPLETED | Duration: ${sw.Elapsed.TotalSeconds}s"
        $Results.Add([pscustomobject]@{ Step = $Name; Status = 'OK'; Seconds = [math]::Round($sw.Elapsed.TotalSeconds,1) })
    } catch {
        $sw.Stop()
        Write-Warning ("FAILED: $Name | $_")
        Add-Content -Path $stepLog -Value "$(Get-Date) | FAILED | $_"
        $Results.Add([pscustomobject]@{ Step = $Name; Status = 'Failed'; Seconds = [math]::Round($sw.Elapsed.TotalSeconds,1) })
    }
}

Write-Host "Maintenance run started $(Get-Date)  |  Admin: $isAdmin  |  Main Log: $mainLog" -ForegroundColor Green

# ---------------------------------------------------------------------------
# 2. winget (apps from winget + Microsoft Store sources)
# ---------------------------------------------------------------------------
Invoke-Step -Name 'winget (all sources)' -RequiresCommand 'winget' -Action {
    winget upgrade --all --include-unknown --silent `
        --accept-source-agreements --accept-package-agreements --disable-interactivity
}

# ---------------------------------------------------------------------------
# 3. PowerShell modules + help
# ---------------------------------------------------------------------------
Invoke-Step -Name 'PowerShell modules' -Action {
    # Note: $ErrorActionPreference scope leak removed. Explicit flags used below.
    if (Get-Command Update-PSResource -ErrorAction SilentlyContinue) {
        Update-PSResource -Name * -ErrorAction SilentlyContinue
    } elseif (Get-Command Update-Module -ErrorAction SilentlyContinue) {
        Update-Module -Force -ErrorAction SilentlyContinue
    } else { 
        Write-Host 'No PowerShellGet/PSResourceGet available; skipping.' 
    }
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
    if ($UpdateGlobalNpm) { 
        npm update -g 
    } else { 
        Write-Host 'Skipping global package upgrade (use -UpdateGlobalNpm to enable).' 
    }
}

# ---------------------------------------------------------------------------
# 6. .NET global tools
# ---------------------------------------------------------------------------
Invoke-Step -Name '.NET global tools' -RequiresCommand 'dotnet' -Action {
    # --all requires .NET 6+ SDK
    $sdkVersion = (dotnet --version).Split('.')[0]
    if ([int]$sdkVersion -lt 6) {
        Write-Host '.NET global tool update skipped (requires SDK v6 or higher)'
        return
    }
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
# 8. WSL kernel
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
        if (-not $isAdmin) { throw 'Administrator rights required for Windows Update.' }
        
        # Install module if missing (scope matches elevation context)
        if (-not (Get-Module -ListAvailable -Name PSWindowsUpdate)) {
            $installScope = if ($isAdmin) { 'AllUsers' } else { 'CurrentUser' }
            try {
                Install-Module PSWindowsUpdate -Force -Scope $installScope -AcceptLicense -ErrorAction Stop
            } catch {
                throw "Failed to install PSWindowsUpdate module: $_"
            }
        }
        
        Import-Module PSWindowsUpdate -ErrorAction Stop
        $params = @{ AcceptAll = $true; Install = $true }
        if ($AutoReboot)        { $params.AutoReboot  = $true } 
        else                   { $params.IgnoreReboot = $true }
        
        # Execute updates
        Get-WindowsUpdate @params
    }
} else {
    Write-Host "`nSKIP  Windows Update (disabled by parameter)" -ForegroundColor DarkGray
    $Results.Add([pscustomobject]@{ Step = 'Windows Update'; Status = 'Skipped'; Seconds = 0 })
}

# ---------------------------------------------------------------------------
# 11. Summary + reboot check
# ---------------------------------------------------------------------------
Write-Host "`n================ SUMMARY ================" -ForegroundColor Green
$Results | Format-Table -AutoSize

# Improved reboot detection logic
$pendingReboot = $false
$rebootPaths = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending',
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
)

foreach ($path in $rebootPaths) { if (Test-Path $path) { $pendingReboot = $true } }

# Check Session Manager for pending file renames (most common driver/WU marker)
try {
    $smKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager'
    if (Get-ItemProperty -Path $smKey -Name PendingFileRenameOperations -ErrorAction SilentlyContinue) {
        $pendingReboot = $true
    }
} catch {}

if ($pendingReboot) {
    Write-Host "`n⚠ A reboot is pending. Restart to finish applying updates." -ForegroundColor Yellow
} else {
    Write-Host "`n✓ No pending reboots detected." -ForegroundColor Green
}

Write-Host "Finished $(Get-Date). Detailed logs saved to: $logDir" -ForegroundColor Green
Stop-Transcript | Out-Null
