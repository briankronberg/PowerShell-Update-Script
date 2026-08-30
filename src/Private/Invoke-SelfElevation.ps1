function Invoke-SelfElevation {
    <#
        .SYNOPSIS
        Re-runs Update-Everything elevated, in its own window, and returns the
        exit code that run finished with.

        .DESCRIPTION
        As a script this relaunched $PSCommandPath. A module has no script path,
        so the child imports the module by its own folder and calls the function.
        Importing by path rather than by name matters: the elevated session may
        resolve a different copy of the module, or none at all, if the module is
        installed for the current user only.

        It returns rather than exits. Killing the session someone called a
        function from would be a poor way to repay them for asking.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        # The caller's $PSBoundParameters. Inside a function $PSBoundParameters
        # describes that function, so the arguments have to be handed over or the
        # elevated run loses them.
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $BoundParameters
    )

    Write-Host 'Elevating to Administrator...' -ForegroundColor Yellow

    # Prefer the current host executable. Some hosts report no path, so fall back
    # to whatever PowerShell can be resolved.
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
        throw 'Cannot self-elevate: no PowerShell executable could be resolved to relaunch.'
    }

    # -Command, not -File. -File coerces every argument to a string, so a typed
    # [bool] such as -IncludeWindowsUpdate $false would arrive as $true.
    # The manifest, not the folder. Import-Module given a directory looks for a
    # manifest named after it, which a versioned path like \1.0.0 never has.
    $manifest = Join-Path $script:ModuleRoot 'UpdateEverything.psd1'
    $escModule = "'" + ($manifest -replace "'", "''") + "'"
    $invoke = "Import-Module $escModule -Force; Update-Everything"

    foreach ($entry in $BoundParameters.GetEnumerator()) {
        $key = $entry.Key
        $val = $entry.Value

        if ($val -is [switch]) {
            if ($val.IsPresent) { $invoke += " -$key" }
        } elseif ($val -is [bool]) {
            $invoke += " -${key}:`$$($val.ToString().ToLowerInvariant())"
        } elseif ($val -is [array]) {
            $quoted = ($val | ForEach-Object { "'" + ("$_" -replace "'", "''") + "'" }) -join ','
            $invoke += " -$key $quoted"
        } else {
            $invoke += " -$key '" + ("$val" -replace "'", "''") + "'"
        }
    }

    # The child turns the result into an exit code, which is the only thing that
    # can cross a process boundary.
    $invoke = "exit ($invoke).FailedCount"
    $argList = "-NoProfile -ExecutionPolicy Bypass -Command `"$invoke`""

    try {
        # -Wait so this console reports the real outcome rather than returning
        # immediately while the elevated window does the work and vanishes.
        $child = Start-Process -FilePath $hostPath -Verb RunAs -ArgumentList $argList `
            -PassThru -Wait -ErrorAction Stop

        Write-Host "Elevated run finished with exit code $($child.ExitCode)." -ForegroundColor Green
        return $child.ExitCode
    } catch {
        # Declining the UAC prompt throws here.
        throw "Elevation was declined or failed: $($_.Exception.Message). Re-run with -SkipElevation to proceed without admin."
    }
}
