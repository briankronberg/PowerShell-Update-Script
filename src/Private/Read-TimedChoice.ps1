function Read-TimedChoice {
    # A choice prompt that gives up and takes the default after a while.
    #
    # $Host.UI.PromptForChoice has no timeout, and a scheduled run blocked on a
    # question nobody is there to answer would sit until the task's execution
    # time limit killed it -- turning "ask politely" into "never update again".
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'The prompt is drawn for a person to read and answer. Sending it down the pipeline would make it the return value instead.')]
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)][string]   $Caption,
        [Parameter(Mandatory)][string[]] $Choice,
        [Parameter(Mandatory)][int]      $TimeoutSeconds,
        [int] $DefaultIndex = 0
    )

    Write-Host ''
    Write-Host $Caption -ForegroundColor Cyan
    for ($i = 0; $i -lt $Choice.Count; $i++) {
        $marker = if ($i -eq $DefaultIndex) { '*' } else { ' ' }
        Write-Host ("  [{0}]{1} {2}" -f ($i + 1), $marker, $Choice[$i])
    }
    Write-Host ''

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $lastShown = -1

    try {
        while ((Get-Date) -lt $deadline) {
            $remaining = [int][Math]::Ceiling(($deadline - (Get-Date)).TotalSeconds)
            if ($remaining -ne $lastShown) {
                # [Console]::Write, not Write-Host: transcription does not see a
                # raw console write, so the countdown redraws on screen without
                # writing a line per second into the run log.
                # The extra parentheses matter. Inside a method call the comma
                # separates arguments, so Write("..." -f $a, $b) is parsed as
                # Write(("..." -f $a), $b): the format string gets one argument
                # and .NET throws about the argument list, which the catch below
                # then reports as an unreadable keypress.
                [Console]::Write(("`rStarting in {0,3}s -- press 1-{1}, Enter for the default, or wait. " -f $remaining, $Choice.Count))
                $lastShown = $remaining
            }

            if ($Host.UI.RawUI.KeyAvailable) {
                $key = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')

                # Enter takes the default rather than being ignored. Waiting out
                # the timeout already chooses it, so making the obvious keypress
                # mean the same thing costs nothing and saves the wait. 13 is
                # VK_RETURN; the character is checked too, because a host that
                # reports no virtual key code still reports the carriage return.
                $picked = if ($key.VirtualKeyCode -eq 13 -or $key.Character -eq "`r" -or $key.Character -eq "`n") {
                    $DefaultIndex
                } else {
                    [int] $key.Character - [int] [char] '1'
                }

                if ($picked -ge 0 -and $picked -lt $Choice.Count) {
                    [Console]::Write("`r" + (' ' * 70) + "`r")
                    Write-Host ("Chose: {0}" -f $Choice[$picked]) -ForegroundColor Cyan
                    return $picked
                }
            }

            Start-Sleep -Milliseconds 150
        }
    } catch {
        # A host with no readable keyboard throws rather than returning. Taking
        # the default is the safe answer: the run proceeds.
        Write-Host ''
        Write-Warning "Could not read a keypress ($($_.Exception.Message)); taking the default."
        return $DefaultIndex
    }

    [Console]::Write("`r" + (' ' * 60) + "`r")
    Write-Host ("No answer in ${TimeoutSeconds}s; taking the default: {0}" -f $Choice[$DefaultIndex]) -ForegroundColor DarkGray
    return $DefaultIndex
}
