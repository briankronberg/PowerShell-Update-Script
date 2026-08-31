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
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Write-Host is the user interface of a console maintenance tool. Its output is progress a person watches, not data a caller consumes, and the summary uses colour to separate failures from noise.')]
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

    # ...unless this host is the MSIX package, which Windows will not run
    # elevated. The MSI build sits alongside it and can, so prefer that over
    # failing. Test-ElevationCapability refuses the run outright when neither is
    # available, so reaching here with no MSI means it was called directly.
    if (Test-PackagedProcess -Path $hostPath) {
        $msi = Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe'
        if (Test-Path -LiteralPath $msi) {
            Write-Warning 'This PowerShell is the MSIX package, which Windows will not run elevated. Relaunching with the MSI build.'
            $hostPath = $msi
        } else {
            throw 'Cannot self-elevate: this PowerShell is the MSIX build (the Store and winget default), and Windows does not run packaged apps elevated. Install the MSI build with "winget install --id Microsoft.PowerShell --exact --source winget --installer-type wix", or re-run with -SkipElevation.'
        }
    }

    if (-not $hostPath -or -not (Test-Path -LiteralPath $hostPath)) {
        $hostPath = $null
        foreach ($candidate in 'pwsh', 'powershell') {
            # A packaged candidate is no better than a packaged host, and the
            # alias in WindowsApps is a zero-byte reparse point Start-Process
            # cannot launch at all.
            $resolved = Get-Command $candidate -CommandType Application -ErrorAction SilentlyContinue |
                Where-Object { -not (Test-PackagedProcess -Path $_.Source) } |
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

    # The call is built on its own, separately from the import. Parentheses in
    # PowerShell hold an expression, not a statement list, so wrapping both
    # together --
    #
    #     exit (Import-Module '...' -Force; Update-Everything).FailedCount
    #
    # -- is a parse error: "Missing closing ')' in expression". The elevated
    # window opened, pwsh exited 1 before running a line of it, and it closed
    # again too fast to read, leaving no transcript and no clue. Import first,
    # then exit on the call alone, which is what Get-UpdateTaskArgument has
    # always done for the scheduled task.
    $call = 'Update-Everything'

    foreach ($entry in $BoundParameters.GetEnumerator()) {
        $key = $entry.Key
        $val = $entry.Value

        if ($val -is [switch]) {
            if ($val.IsPresent) { $call += " -$key" }
        } elseif ($val -is [bool]) {
            $call += " -${key}:`$$($val.ToString().ToLowerInvariant())"
        } elseif ($val -is [array]) {
            $quoted = ($val | ForEach-Object { "'" + ("$_" -replace "'", "''") + "'" }) -join ','
            $call += " -$key $quoted"
        } else {
            $call += " -$key '" + ("$val" -replace "'", "''") + "'"
        }
    }

    # The child turns the result into an exit code, which is the only thing that
    # can cross a process boundary.
    $invoke = "Import-Module $escModule -Force; exit ($call).FailedCount"
    $argList = "-NoProfile -ExecutionPolicy Bypass -Command `"$invoke`""

    try {
        # -Wait so this console reports the real outcome rather than returning
        # immediately while the elevated window does the work and vanishes.
        $child = Start-Process -FilePath $hostPath -Verb RunAs -ArgumentList $argList `
            -PassThru -Wait -ErrorAction Stop

        # The caller reports the outcome, not this function. It reopens its
        # transcript first, so the line lands in the log rather than only on a
        # console nobody is reading after an unattended run.
        return $child.ExitCode
    } catch {
        # Declining the UAC prompt throws here, and so does a policy that
        # refuses the request before anyone sees one. Those look identical from
        # here, so the message says which values are set rather than guessing
        # between them. Nothing is added on a machine where none of them is.
        $message = "Elevation was declined or failed: $($_.Exception.Message)."

        $policyNote = Get-ElevationPolicyNote
        if ($policyNote) { $message += " $policyNote" }

        throw "$message Re-run with -SkipElevation to proceed without admin."
    }
}
