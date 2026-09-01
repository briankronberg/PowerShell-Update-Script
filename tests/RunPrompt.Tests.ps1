#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '6.0' }

<#
    Tests for the pre-run prompt and the window-style options.

    Read-TimedChoice is mocked throughout: it reads the keyboard and counts down,
    and a test that waited on either would be a test that hangs.
#>

BeforeAll {
    # Load the module's functions individually rather than importing the module,
    # so tests can reach the private ones directly. $ModuleRoot is what
    # Invoke-SelfElevation and the task builder hand to an elevated child.
    $script:ModuleRoot = Join-Path (Split-Path $PSScriptRoot -Parent) 'src'
    Get-ChildItem "$script:ModuleRoot\Private\*.ps1", "$script:ModuleRoot\Public\*.ps1" |
        ForEach-Object { . $_.FullName }
}

Describe 'Request-RunDecision' -Tag 'Unit','Prompt' {

    It 'runs when the first option is chosen' {
        Mock Read-TimedChoice { 0 }
        Request-RunDecision | Should-Be 'Run'
    }

    It 'skips when the second option is chosen' {
        Mock Read-TimedChoice { 1 }
        Request-RunDecision | Should-Be 'Skip'
    }

    It 'delays when the third option is chosen' {
        Mock Read-TimedChoice { 2 }
        Request-RunDecision | Should-Be 'Delay'
    }

    # An unanswered prompt must not become a decision to do nothing. Silence
    # means the machine is unattended, which is when updating matters most.
    It 'runs by default' {
        Mock Read-TimedChoice { 0 }
        $null = Request-RunDecision
        Should-Invoke Read-TimedChoice -ParameterFilter { $DefaultIndex -eq 0 }
    }

    It 'offers exactly three ways out' {
        Mock Read-TimedChoice { 0 }
        $null = Request-RunDecision
        Should-Invoke Read-TimedChoice -ParameterFilter { $Choice.Count -eq 3 }
    }

    It 'names the wait in minutes, so it is not a mystery' {
        Mock Read-TimedChoice { 0 }
        $null = Request-RunDecision -DelayMinutes 90
        Should-Invoke Read-TimedChoice -ParameterFilter { ($Choice -join ' ') -match '90 minutes' }
    }

    It 'passes the timeout through' {
        Mock Read-TimedChoice { 0 }
        $null = Request-RunDecision -TimeoutSeconds 30
        Should-Invoke Read-TimedChoice -ParameterFilter { $TimeoutSeconds -eq 30 }
    }

    It 'treats anything unexpected as run' {
        Mock Read-TimedChoice { 99 }
        Request-RunDecision | Should-Be 'Run'
    }
}

Describe 'Read-TimedChoice' -Tag 'Unit','Prompt' {

    # The point of the whole function: PromptForChoice has no timeout, and a
    # scheduled run blocked on a question nobody is there to answer would sit
    # until the task's execution time limit killed it.
    # The countdown redraw formatted a string inside a method call, where the
    # comma binds as a second argument: Write("..." -f $a, $b) is
    # Write(("..." -f $a), $b). .NET threw about the argument list, the catch
    # reported it as an unreadable keypress, and the countdown never appeared.
    It 'draws the countdown without warning' {
        $warnings = @()
        $null = Read-TimedChoice -Caption 'x' -Choice @('a', 'b') -TimeoutSeconds 3 -DefaultIndex 0 `
            -WarningVariable warnings -WarningAction SilentlyContinue 6>$null

        $warnings | Should-BeNull -Because "the countdown should draw cleanly: $($warnings -join '; ')"
    }

    # The timeout is short because the assertion is that one is honoured at all,
    # not that it lasts any particular length. The upper bound stays well clear
    # of it so a loaded CI agent cannot fail this for being slow.
    It 'gives up and takes the default rather than waiting forever' {
        $elapsed = Measure-Command {
            $script:answer = Read-TimedChoice -Caption 'x' -Choice @('a', 'b') `
                -TimeoutSeconds 2 -DefaultIndex 1 6>$null
        }

        $script:answer | Should-Be 1
        $elapsed.TotalSeconds | Should-BeLessThan 12
    }
}

Describe 'The countdown stays out of the run log' -Tag 'Static','Prompt' {

    BeforeAll {
        $script:Source = (Get-ChildItem (Join-Path (Split-Path $PSScriptRoot -Parent) 'src\Public'), (Join-Path (Split-Path $PSScriptRoot -Parent) 'src\Private') -Filter *.ps1 | Get-Content -Raw) -join "`n`n"
        $script:Timed = [regex]::Match($script:Source, '(?s)function Read-TimedChoice.*?\n\}').Value
    }

    # Start-Transcript records Write-Host but not a raw console write. Redrawing
    # the countdown with Write-Host put one line per second into the log -- 52 of
    # them in a 276 line transcript on a 60 second prompt.
    It 'redraws the countdown with a raw console write' {
        $script:Timed | Should-MatchString '\[Console\]::Write\(\("`rStarting in'
    }

    It 'does not redraw it with Write-Host' {
        $countdownWrites = [regex]::Matches($script:Timed, 'Write-Host[^\r\n]*Starting in')
        $countdownWrites.Count | Should-Be 0
    }

    # The outcome is deliberately Write-Host: which way the run went belongs in
    # the log, unlike the seconds ticking down to it.
    It 'still records the decision in the log' {
        $script:Timed | Should-MatchString 'Write-Host \("No answer in'
    }
}

Describe 'Resolve-WindowStyle' -Tag 'Unit','Prompt' {

    It 'leaves <_> alone when nothing is being asked' -ForEach @('Normal', 'Minimized', 'Hidden') {
        Resolve-WindowStyle -Requested $_ | Should-Be $_
    }

    # The rule: a run that asks a question is always a run you can see.
    It 'forces a prompting run out of <_>' -ForEach @('Minimized', 'Hidden') {
        Resolve-WindowStyle -Requested $_ -PromptBeforeRun -WarningAction SilentlyContinue |
            Should-Be 'Normal'
    }

    It 'says why it overrode the request' {
        $warnings = @()
        $null = Resolve-WindowStyle -Requested Hidden -PromptBeforeRun `
            -WarningVariable warnings -WarningAction SilentlyContinue

        ($warnings -join ' ') | Should-MatchString 'needs a visible window'
    }

    It 'does not warn when there was nothing to override' {
        $warnings = @()
        $null = Resolve-WindowStyle -Requested Normal -PromptBeforeRun `
            -WarningVariable warnings -WarningAction SilentlyContinue

        $warnings | Should-BeNull
    }
}

Describe 'Get-UpdateTaskArgument window and prompt options' -Tag 'Unit','Prompt' {

    It 'says nothing about window style for a normal run' {
        Get-UpdateTaskArgument -ModuleRoot 'C:\x' | Should-NotMatchString '-WindowStyle'
    }

    It 'passes -WindowStyle <_> through' -ForEach @('Hidden', 'Minimized') {
        Get-UpdateTaskArgument -ModuleRoot 'C:\x' -WindowStyle $_ |
            Should-MatchString "-WindowStyle $_"
    }

    # -WindowStyle is an argument to pwsh, not to the module. After -Command it
    # would be swallowed by the command string.
    It 'puts -WindowStyle before -Command, where the host will read it' {
        $arguments = Get-UpdateTaskArgument -ModuleRoot 'C:\x' -WindowStyle Hidden

        $arguments.IndexOf('-WindowStyle') | Should-BeLessThan $arguments.IndexOf('-Command')
    }

    It 'passes -PromptBeforeRun through' {
        Get-UpdateTaskArgument -ModuleRoot 'C:\x' -PromptBeforeRun |
            Should-MatchString '-PromptBeforeRun'
    }

    It 'carries the prompt timeout with it' {
        Get-UpdateTaskArgument -ModuleRoot 'C:\x' -PromptBeforeRun -PromptTimeoutSeconds 30 |
            Should-MatchString '-PromptTimeoutSeconds 30'
    }

    It 'omits the prompt entirely when it is not wanted' {
        Get-UpdateTaskArgument -ModuleRoot 'C:\x' | Should-NotMatchString '-PromptBeforeRun'
    }
}

Describe 'The prompt cannot hang a run' -Tag 'Static','Prompt' {

    BeforeAll {
        $script:Source = (Get-ChildItem (Join-Path (Split-Path $PSScriptRoot -Parent) 'src\Public'), (Join-Path (Split-Path $PSScriptRoot -Parent) 'src\Private') -Filter *.ps1 | Get-Content -Raw) -join "`n`n"
    }

    # A hidden window or redirected input cannot answer. Starting anyway beats
    # blocking until the task's time limit kills the run.
    It 'checks it can prompt before it tries to' {
        $script:Source | Should-MatchString '(?s)if \(\$PromptBeforeRun\).{0,200}Test-CanPrompt'
    }

    # Choosing not to run is a decision, not a fault, so it must not land in
    # FailedCount. As a module it returns a result rather than exiting, which
    # would have taken the caller's session with it.
    # Bounded by the next branch rather than by a character count. The proximity
    # window this used to rely on broke the moment a suppression attribute was
    # added above it, which is a poor reason for a test to fail.
    It 'skips by returning a result, not by exiting' {
        $skip  = $script:Source.IndexOf("'Skip' {")
        $delay = $script:Source.IndexOf("'Delay' {")

        $skip  | Should-BeGreaterThan -1
        $delay | Should-BeGreaterThan $skip

        $branch = $script:Source.Substring($skip, $delay - $skip)
        $branch | Should-MatchString 'New-UpdateEverythingResult -Ran'
    }
}
