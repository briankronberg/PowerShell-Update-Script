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

        # Stop-StepAsSkipped throws this prefix to end a step deliberately --
        # a declined install, for instance. That is a decision, not a fault, and
        # reporting it as Failed would put it in the exit code.
        $message = "$_"
        if ($message -like 'STEP-SKIPPED:*') {
            $reason = $message -replace '^STEP-SKIPPED:\s*', ''
            Write-Host "SKIP  $Name ($reason)" -ForegroundColor DarkGray
            Write-StepLog -Path $stepLog -Message "SKIPPED | $reason"
            $script:Results.Add([pscustomobject]@{ Step = $Name; Status = 'Skipped'; Seconds = $secs; Log = '' })
            return
        }

        Write-Warning ("FAILED: $Name | $_")
        Write-StepLog -Path $stepLog -Message "FAILED | $_"
        $script:Results.Add([pscustomobject]@{ Step = $Name; Status = 'Failed'; Seconds = $secs; Log = $stepLog })
    }
}
