function Invoke-Step {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Write-Host is the user interface of a console maintenance tool. Its output is progress a person watches, not data a caller consumes, and the summary uses colour to separate failures from noise.')]
    param(
        [Parameter(Mandatory)][string]      $Name,
        [Parameter(Mandatory)][scriptblock] $Action,
        [string]                            $RequiresCommand,
        # Steps that cannot work without administrator rights. Reported as
        # skipped with the reason rather than left to fail with a permissions
        # error that reads like a bug.
        [switch]                            $RequiresAdmin,
        # What this step is about, for -Tag and -ExcludeTag. Declared on the call
        # rather than in a table elsewhere, so a tag and its step cannot drift.
        [string[]]                          $Tag = @(),
        # Native exit codes this step should treat as success.
        [int[]]                             $AllowedExitCodes = @()
    )

    # Tag filter first: a step the caller excluded should not even be checked for
    # administrator rights or for its tool, because neither is why it is skipped.
    if (-not (Test-StepTagMatch -StepTag $Tag -Tag $script:TagFilter -ExcludeTag $script:ExcludeTagFilter)) {
        # Which filter actually refused it. Exclusion wins when both are given,
        # so asking "was -Tag set" first would blame -Tag for an exclusion and
        # send someone looking at the wrong parameter.
        $refused = @($Tag | Where-Object { $_ -and $_ -in @($script:ExcludeTagFilter | Where-Object { $_ }) })
        $reason = if ($refused.Count) {
            "excluded by -ExcludeTag $($refused -join ',')"
        } else {
            "does not match -Tag $(@($script:TagFilter | Where-Object { $_ }) -join ',')"
        }
        Add-SkippedStep -Name $Name -Reason $reason
        return
    }

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

    # Function-local, so the caller's session is untouched -- which is the point
    # of the rule against setting this in a module, and is not what this does.
    #
    # A caller that prefers Stop makes a native command's stderr terminating, and
    # most of these steps drive tools that write to stderr as a matter of course:
    # npm its deprecation notices, winget its progress, wsl its "not installed"
    # message. Every one of those steps then throws before reaching the exit-code
    # check written to handle exactly that case, so the run's result depends on a
    # preference set outside it.
    #
    # Non-terminating errors still reach $stepOutput and are still counted below.
    $ErrorActionPreference = 'Continue'

    try {
        # Reset so a cmdlet-only step can't inherit a stale exit code from an earlier native command
        $global:LASTEXITCODE = 0

        # *>&1 captures every stream, not just warnings: Write-Host writes to the
        # information stream and native stderr to the error stream. The first
        # ForEach-Object accumulates output for the error-record check below and
        # passes each object through, so the console and the transcript see it
        # live during long-running steps.
        #
        # Out-String -Stream renders the Format* records a table arrives as into
        # the table itself, and leaves Write-StepLog as the file's only writer.
        # Tee-Object is not usable here: it writes UTF-16LE in Windows PowerShell
        # and has no -Encoding parameter there.
        #
        # Where-Object drops progress repaints. PowerShell splits captured native
        # output on carriage returns, so a tool that redraws a progress bar in
        # place -- winget above all -- arrives as one line per repaint. Nothing
        # upstream prevents it: --disable-interactivity governs prompts, not
        # rendering.
        #
        # Out-Host displays the output rather than returning it. Inside a
        # function, unassigned pipeline output is the return value, so without it
        # every line a step produced would reach the caller alongside the result
        # object and the transcript would record none of it.
        #
        # $stepOutput is filled before the filter, so the error-record check
        # below still sees everything the step produced.
        $stepOutput = [System.Collections.Generic.List[object]]::new()
        & $Action *>&1 |
            ForEach-Object { $stepOutput.Add($_); $_ } |
            Out-String -Stream |
            Where-Object { -not (Test-ProgressRepaint -Line $_) } |
            ForEach-Object { Write-StepLog -Path $stepLog -Raw $_; $_ } |
            Out-Host

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
