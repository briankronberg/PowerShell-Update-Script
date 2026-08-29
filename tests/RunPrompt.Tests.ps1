#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '6.0' }

<#
    Tests for the pre-run prompt and the window-style options.

    Read-TimedChoice is mocked throughout: it reads the keyboard and counts down,
    and a test that waited on either would be a test that hangs.
#>

BeforeAll {
    . (Join-Path (Split-Path $PSScriptRoot -Parent) 'Update-Everything.ps1')
    . (Join-Path (Split-Path $PSScriptRoot -Parent) 'Register-UpdateTask.ps1')
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
    It 'gives up and takes the default rather than waiting forever' {
        $elapsed = Measure-Command {
            $script:answer = Read-TimedChoice -Caption 'x' -Choice @('a', 'b') `
                -TimeoutSeconds 5 -DefaultIndex 1 6>$null
        }

        $script:answer | Should-Be 1
        $elapsed.TotalSeconds | Should-BeLessThan 15
    }
}

Describe 'The countdown stays out of the run log' -Tag 'Static','Prompt' {

    BeforeAll {
        $script:Source = Get-Content (Join-Path (Split-Path $PSScriptRoot -Parent) 'Update-Everything.ps1') -Raw
        $script:Timed = [regex]::Match($script:Source, '(?s)function Read-TimedChoice.*?\n\}').Value
    }

    # Start-Transcript records Write-Host but not a raw console write. Redrawing
    # the countdown with Write-Host put one line per second into the log -- 52 of
    # them in a 276 line transcript on a 60 second prompt.
    It 'redraws the countdown with a raw console write' {
        $script:Timed | Should-MatchString '\[Console\]::Write\("`rStarting in'
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
        Get-UpdateTaskArgument -ScriptPath 'C:\x.ps1' | Should-NotMatchString '-WindowStyle'
    }

    It 'passes -WindowStyle <_> through' -ForEach @('Hidden', 'Minimized') {
        Get-UpdateTaskArgument -ScriptPath 'C:\x.ps1' -WindowStyle $_ |
            Should-MatchString "-WindowStyle $_"
    }

    # -WindowStyle is an argument to pwsh, not to the script. After -File it
    # would be handed to the script, which has no such parameter.
    It 'puts -WindowStyle before -File, where the host will read it' {
        $arguments = Get-UpdateTaskArgument -ScriptPath 'C:\x.ps1' -WindowStyle Hidden

        $arguments.IndexOf('-WindowStyle') | Should-BeLessThan $arguments.IndexOf('-File')
    }

    It 'passes -PromptBeforeRun through' {
        Get-UpdateTaskArgument -ScriptPath 'C:\x.ps1' -PromptBeforeRun |
            Should-MatchString '-PromptBeforeRun'
    }

    It 'carries the prompt timeout with it' {
        Get-UpdateTaskArgument -ScriptPath 'C:\x.ps1' -PromptBeforeRun -PromptTimeoutSeconds 30 |
            Should-MatchString '-PromptTimeoutSeconds 30'
    }

    It 'omits the prompt entirely when it is not wanted' {
        Get-UpdateTaskArgument -ScriptPath 'C:\x.ps1' | Should-NotMatchString '-PromptBeforeRun'
    }
}

Describe 'The prompt cannot hang a run' -Tag 'Static','Prompt' {

    BeforeAll {
        $script:Source = Get-Content (Join-Path (Split-Path $PSScriptRoot -Parent) 'Update-Everything.ps1') -Raw
    }

    # A hidden window or redirected input cannot answer. Starting anyway beats
    # blocking until the task's time limit kills the run.
    It 'checks it can prompt before it tries to' {
        $script:Source | Should-MatchString '(?s)if \(\$PromptBeforeRun\).{0,200}Test-CanPrompt'
    }

    It 'skips cleanly rather than reporting a failure' {
        # Choosing not to run is a decision, not a fault, so it must not land in
        # the exit code.
        $script:Source | Should-MatchString "(?s)'Skip'.{0,400}exit 0"
    }
}
