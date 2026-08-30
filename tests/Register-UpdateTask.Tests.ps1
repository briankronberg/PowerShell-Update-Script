#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '6.0' }

<#
    Tests for the scheduled-task registration script.

    Dot-sourced, so the functions are exercised without registering, replacing
    or removing a real scheduled task. Nothing here calls Register-ScheduledTask
    or Unregister-ScheduledTask.
#>

BeforeDiscovery {
    # Every month from 2026 to 2032, to check the Patch Tuesday claim across a
    # full spread of month-start weekdays rather than whichever month it is now.
    $CalendarYears = 2026..2032
}

BeforeAll {
    # Load the module's functions individually rather than importing the module,
    # so tests can reach the private ones directly. $ModuleRoot is what
    # Invoke-SelfElevation and the task builder hand to an elevated child.
    $script:ModuleRoot = Join-Path (Split-Path $PSScriptRoot -Parent) 'src'
    Get-ChildItem "$script:ModuleRoot\Private\*.ps1", "$script:ModuleRoot\Public\*.ps1" |
        ForEach-Object { . $_.FullName }
}

Describe 'Get-NthDayOfWeek' -Tag 'Unit' {

    It 'finds the first Wednesday of a month that starts on Wednesday' {
        # 2026-07-01 is a Wednesday.
        (Get-NthDayOfWeek -Year 2026 -Month 7 -DayOfWeek Wednesday -Occurrence 1).Day |
            Should-Be 1
    }

    It 'finds the third Wednesday' {
        (Get-NthDayOfWeek -Year 2026 -Month 7 -DayOfWeek Wednesday -Occurrence 3).Day |
            Should-Be 15
    }

    It 'returns the requested weekday' {
        (Get-NthDayOfWeek -Year 2027 -Month 3 -DayOfWeek Tuesday -Occurrence 2).DayOfWeek |
            Should-Be ([System.DayOfWeek]::Tuesday)
    }

    It 'throws when the occurrence does not exist' {
        # No month has five of any weekday in its first 28 days, and February
        # 2027 has exactly 28.
        { Get-NthDayOfWeek -Year 2027 -Month 2 -DayOfWeek Monday -Occurrence 5 } |
            Should-Throw -ExceptionMessage '*no occurrence*'
    }
}

Describe 'Patch Tuesday alignment' -Tag 'Unit' {

    # The whole justification for choosing the third Wednesday. Microsoft ships
    # on the second Tuesday; running before that installs nothing new, and
    # running the same day is what the "wait a few days" advice warns against.

    It 'puts the third Wednesday after Patch Tuesday in every month of <_>' -ForEach $CalendarYears {
        $year = $_

        $violations = foreach ($month in 1..12) {
            $patchTuesday = Get-NthDayOfWeek -Year $year -Month $month -DayOfWeek Tuesday -Occurrence 2
            $thirdWed     = Get-NthDayOfWeek -Year $year -Month $month -DayOfWeek Wednesday -Occurrence 3

            if ($thirdWed -le $patchTuesday) {
                "$year-$month : third Wednesday $($thirdWed.ToString('yyyy-MM-dd')) is not after Patch Tuesday $($patchTuesday.ToString('yyyy-MM-dd'))"
            }
        }

        $violations | Should-BeNull
    }

    It 'keeps the gap within a week or so in <_>' -ForEach $CalendarYears {
        $year = $_

        $tooFar = foreach ($month in 1..12) {
            $patchTuesday = Get-NthDayOfWeek -Year $year -Month $month -DayOfWeek Tuesday -Occurrence 2
            $thirdWed     = Get-NthDayOfWeek -Year $year -Month $month -DayOfWeek Wednesday -Occurrence 3
            $gap          = ($thirdWed - $patchTuesday).Days

            if ($gap -gt 8) { "$year-$month gap is $gap days" }
        }

        $tooFar | Should-BeNull -Because 'updates should not sit uninstalled for longer than a week'
    }

    # Documented in the script because it is the trap a reasonable person falls
    # into. If this ever stops being true the comment needs rewriting.
    It 'confirms the second Wednesday would sometimes run too early' {
        $early = foreach ($year in 2026..2032) {
            foreach ($month in 1..12) {
                $patchTuesday = Get-NthDayOfWeek -Year $year -Month $month -DayOfWeek Tuesday -Occurrence 2
                $secondWed    = Get-NthDayOfWeek -Year $year -Month $month -DayOfWeek Wednesday -Occurrence 2
                if ($secondWed -le $patchTuesday) { "$year-$month" }
            }
        }

        @($early).Count | Should-BeGreaterThan 0
    }
}

Describe 'New-UpdateTaskTrigger' -Tag 'Unit' {

    Context 'Daily' {
        It 'builds a daily trigger' {
            $trigger = New-UpdateTaskTrigger -Cadence Daily -DayOfWeek Wednesday -At '12:00'
            $trigger.CimClass.CimClassName | Should-Be 'MSFT_TaskDailyTrigger'
        }
    }

    Context 'Weekly' {
        It 'builds a weekly trigger' {
            $trigger = New-UpdateTaskTrigger -Cadence Weekly -DayOfWeek Wednesday -At '12:00'
            $trigger.CimClass.CimClassName | Should-Be 'MSFT_TaskWeeklyTrigger'
        }

        It 'honours the requested day' {
            $trigger = New-UpdateTaskTrigger -Cadence Weekly -DayOfWeek Saturday -At '09:00'
            # Bitmask: Sunday=1, Monday=2, Tuesday=4, Wednesday=8, Thursday=16,
            # Friday=32, Saturday=64.
            $trigger.DaysOfWeek | Should-Be 64
        }

        # New-ScheduledTaskTrigger normalises StartBoundary to UTC and appends Z,
        # so compare the converted local time rather than the literal string.
        It 'honours the requested time' {
            $trigger = New-UpdateTaskTrigger -Cadence Weekly -DayOfWeek Wednesday -At '09:30'
            ([datetime] $trigger.StartBoundary).ToString('HH:mm') | Should-Be '09:30'
        }
    }

    Context 'PatchTuesday' {

        # New-ScheduledTaskTrigger has no monthly parameter set, so this one is
        # built from the CIM class by hand and is the most likely to break.
        It 'builds a monthly day-of-week trigger' {
            $trigger = New-UpdateTaskTrigger -Cadence PatchTuesday -DayOfWeek Wednesday -At '12:00'
            $trigger.CimClass.CimClassName | Should-Be 'MSFT_TaskMonthlyDOWTrigger'
        }

        It 'targets Wednesday' {
            $trigger = New-UpdateTaskTrigger -Cadence PatchTuesday -DayOfWeek Wednesday -At '12:00'
            $trigger.DaysOfWeek | Should-Be 8
        }

        It 'targets the third week' {
            $trigger = New-UpdateTaskTrigger -Cadence PatchTuesday -DayOfWeek Wednesday -At '12:00'
            # first=1, second=2, third=4, fourth=8
            $trigger.WeeksOfMonth | Should-Be 4
        }

        It 'runs in every month of the year' {
            $trigger = New-UpdateTaskTrigger -Cadence PatchTuesday -DayOfWeek Wednesday -At '12:00'
            $trigger.MonthsOfYear | Should-Be 4095
        }

        It 'starts on a Wednesday' {
            $trigger = New-UpdateTaskTrigger -Cadence PatchTuesday -DayOfWeek Wednesday -At '12:00'
            ([datetime] $trigger.StartBoundary).DayOfWeek | Should-Be ([System.DayOfWeek]::Wednesday)
        }

        It 'carries the requested time of day into the start boundary' {
            $trigger = New-UpdateTaskTrigger -Cadence PatchTuesday -DayOfWeek Wednesday -At '18:45'
            ([datetime] $trigger.StartBoundary).TimeOfDay | Should-Be ([timespan] '18:45:00')
        }
    }
}

Describe 'New-UpdateTaskSettingsSet' -Tag 'Unit' {

    It 'catches up a run missed while the machine was off' {
        (New-UpdateTaskSettingsSet).StartWhenAvailable | Should-BeTrue
    }

    It 'does not bother running without a network' {
        (New-UpdateTaskSettingsSet).RunOnlyIfNetworkAvailable | Should-BeTrue
    }

    It 'refuses to start a second overlapping run' {
        (New-UpdateTaskSettingsSet).MultipleInstances | Should-Be 'IgnoreNew'
    }

    It 'gives up after a couple of hours rather than hanging forever' {
        (New-UpdateTaskSettingsSet -ExecutionTimeLimitHours 2).ExecutionTimeLimit |
            Should-Be 'PT2H'
    }

    It 'retries a failed run' {
        (New-UpdateTaskSettingsSet).RestartCount | Should-Be 2
    }

    It 'does not wake a sleeping laptop' {
        (New-UpdateTaskSettingsSet).WakeToRun | Should-BeFalse
    }

    Context 'Battery' {

        # The cmdlet takes -AllowStartIfOnBatteries / -DontStopIfGoingOnBatteries,
        # but the object it returns exposes the *inverse* properties. The
        # positively-named ones are always $null, so asserting on those would
        # pass or fail for reasons unrelated to the setting.
        It 'waits for mains power by default' {
            (New-UpdateTaskSettingsSet).DisallowStartIfOnBatteries | Should-BeTrue
        }

        It 'stops a run that moves onto battery by default' {
            (New-UpdateTaskSettingsSet).StopIfGoingOnBatteries | Should-BeTrue
        }

        It 'starts on battery when asked' {
            (New-UpdateTaskSettingsSet -AllowBattery).DisallowStartIfOnBatteries | Should-BeFalse
        }

        It 'keeps running on battery when asked' {
            (New-UpdateTaskSettingsSet -AllowBattery).StopIfGoingOnBatteries | Should-BeFalse
        }
    }

}

# RandomDelay belongs to the trigger, not the settings. New-ScheduledTaskSettingsSet
# has no such parameter, and an earlier version of this script put it there --
# which threw on every single run.
Describe 'Random start delay' -Tag 'Unit' {

    It 'is not a task-settings parameter at all' {
        (Get-Command New-ScheduledTaskSettingsSet).Parameters.ContainsKey('RandomDelay') |
            Should-BeFalse -Because 'if this ever changes, the trigger workaround can be simplified'
    }

    # RandomDelay is a *string* CIM property holding an ISO 8601 duration.
    # Asserting against a [timespan] here is what let the original bug ship:
    # PowerShell coerced the comparison, so a stored "00:15:00" compared equal
    # to [timespan] '00:15:00' and the test passed -- while
    # Register-ScheduledTask rejected the task XML outright. Compare strings.
    It 'spreads the start time of the <_> trigger as an ISO 8601 duration' -ForEach @('Daily', 'Weekly', 'PatchTuesday') {
        $trigger = New-UpdateTaskTrigger -Cadence $_ -DayOfWeek Wednesday -At '12:00' -RandomDelayMinutes 15
        $trigger.RandomDelay | Should-BeString 'PT15M'
    }

    # The exact shape Task Scheduler rejected, named so it cannot come back.
    It 'never stores the <_> delay in .NET TimeSpan format' -ForEach @('Daily', 'Weekly', 'PatchTuesday') {
        $trigger = New-UpdateTaskTrigger -Cadence $_ -DayOfWeek Wednesday -At '12:00' -RandomDelayMinutes 15
        $trigger.RandomDelay | Should-NotBeString '00:15:00' -Because 'the task XML rejects that format'
    }

    It 'omits the delay when set to zero' {
        $trigger = New-UpdateTaskTrigger -Cadence Weekly -DayOfWeek Wednesday -At '12:00' -RandomDelayMinutes 0
        $trigger.RandomDelay | Should-BeNull
    }
}

Describe 'Get-UpdateTaskArgument' -Tag 'Unit' {

    # The task imports the module and turns the returned object into an exit
    # code. Only an exit code crosses a process boundary, and Task Scheduler
    # records it as the last run result.

    It 'imports the module by path, not by name' {
        # A task runs in its own session, which may resolve a different copy of
        # the module or none at all when it is installed for the current user.
        Get-UpdateTaskArgument -ModuleRoot 'C:\Program Files\x\UpdateEverything' |
            Should-MatchString ([regex]::Escape("Import-Module 'C:\Program Files\x\UpdateEverything'"))
    }

    It 'turns the result object into an exit code' {
        Get-UpdateTaskArgument -ModuleRoot 'C:\x' |
            Should-MatchString ([regex]::Escape('exit (Update-Everything'))
    }

    It 'uses FailedCount for that exit code' {
        Get-UpdateTaskArgument -ModuleRoot 'C:\x' | Should-MatchString ([regex]::Escape(').FailedCount'))
    }

    It 'bypasses execution policy, so the task does not depend on machine policy' {
        Get-UpdateTaskArgument -ModuleRoot 'C:\x' | Should-MatchString '-ExecutionPolicy Bypass'
    }

    It 'skips the user profile' {
        Get-UpdateTaskArgument -ModuleRoot 'C:\x' | Should-MatchString '-NoProfile'
    }

    It 'asks for notifications by default' {
        Get-UpdateTaskArgument -ModuleRoot 'C:\x' | Should-MatchString '-Notify'
    }

    It 'omits notifications when they are turned off' {
        Get-UpdateTaskArgument -ModuleRoot 'C:\x' -Notify $false | Should-NotMatchString '-Notify'
    }

    It 'quotes each approval so the child parses them as a list' {
        Get-UpdateTaskArgument -ModuleRoot 'C:\x' -AllowInstall 'PSWindowsUpdate', 'BurntToast' |
            Should-MatchString ([regex]::Escape("-AllowInstall 'PSWindowsUpdate','BurntToast'"))
    }

    It 'appends extra arguments' {
        Get-UpdateTaskArgument -ModuleRoot 'C:\x' -ExtraArgument '-IncludeWindowsUpdate', '$false' |
            Should-MatchString ([regex]::Escape('-IncludeWindowsUpdate $false'))
    }
}

Describe 'Get-CadenceDescription' -Tag 'Unit' {

    It 'describes a daily schedule' {
        Get-CadenceDescription -Cadence Daily -DayOfWeek Wednesday -At '12:00' |
            Should-Be 'every day at 12:00'
    }

    It 'names the day for a weekly schedule' {
        Get-CadenceDescription -Cadence Weekly -DayOfWeek Saturday -At '09:00' |
            Should-Be 'every Saturday at 09:00'
    }

    It 'explains the Patch Tuesday schedule' {
        Get-CadenceDescription -Cadence PatchTuesday -DayOfWeek Wednesday -At '12:00' |
            Should-MatchString 'third Wednesday'
    }
}

Describe 'Registration safety' -Tag 'Static' {

    BeforeAll {
        $script:Source = (Get-ChildItem (Join-Path (Split-Path $PSScriptRoot -Parent) 'src\Public'), (Join-Path (Split-Path $PSScriptRoot -Parent) 'src\Private') -Filter *.ps1 | Get-Content -Raw) -join "`n`n"
        $script:Ast = [System.Management.Automation.Language.Parser]::ParseInput(
            $script:Source, [ref] $null, [ref] $null)
    }

    # Register-ScheduledTask reports a rejected task XML as a *non-terminating*
    # error. Without -ErrorAction Stop the script ran on and announced success
    # over the top of a failure, having registered nothing.
    It 'stops on a failed registration instead of reporting success' {
        $call = $script:Ast.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.CommandAst] -and
                $node.GetCommandName() -eq 'Register-ScheduledTask'
            }, $true) | Select-Object -First 1

        $call | Should-NotBeNull
        $call.Extent.Text | Should-MatchString '-ErrorAction Stop'
    }

    # The script's own closing advice has to be runnable on the machine it just
    # printed it to, and that machine may well be AllSigned.
    # Registering a task that passes -Notify while BurntToast is missing produces
    # a schedule that runs and tells nobody. Registration is the moment someone
    # can act on that.
    It 'warns when notifications are requested without the module' {
        $script:Source | Should-MatchString 'Install-Module BurntToast'
    }

    # Plain string matching, not a regex: the regex version needed an escaped
    # backslash, lost it in tooling, and matched nothing at all.
    It 'suggests no command a locked-down machine would refuse' {
        $offenders = $script:Source -split "`r?`n" |
            Where-Object { $_ -match 'Write-Host' -and $_.Contains('.\') -and $_ -match '\.ps1' }

        $offenders | Should-BeNull -Because "these are refused under AllSigned:`n$($offenders -join "`n")"
    }
}

Describe 'Format-LastRunResult' -Tag 'Unit' {

    # A task registered a minute ago reports 30 Nov 1999 / 0x41303, which read
    # literally looks like a failure rather than "has not run yet".
    It 'says never for a task that has not run' {
        Format-LastRunResult -LastRunTime ([datetime] '1999-11-30') -LastTaskResult 267011 |
            Should-Be 'never'
    }

    It 'says never for the sentinel date even if the result code differs' {
        Format-LastRunResult -LastRunTime ([datetime] '1999-11-30') -LastTaskResult 0 |
            Should-Be 'never'
    }

    It 'reports a successful run' {
        Format-LastRunResult -LastRunTime ([datetime] '2026-09-02T12:00:00') -LastTaskResult 0 |
            Should-MatchString 'succeeded'
    }

    # The script exits with the number of failed steps, so 3 means three steps
    # failed, not a Windows error code.
    It 'reports the exit code of a failed run' {
        Format-LastRunResult -LastRunTime ([datetime] '2026-09-02T12:00:00') -LastTaskResult 3 |
            Should-MatchString 'exit 3'
    }
}

Describe 'Get-PowerShellHostPath' -Tag 'Unit' {

    It 'returns a path that exists' {
        Test-Path -LiteralPath (Get-PowerShellHostPath) | Should-BeTrue
    }

    It 'prefers pwsh when it is installed' -Skip:(-not (Get-Command pwsh -CommandType Application -ErrorAction SilentlyContinue)) {
        Get-PowerShellHostPath | Should-MatchString 'pwsh\.exe$'
    }

    It 'falls back to Windows PowerShell when pwsh is absent' {
        Mock Get-Command { } -ParameterFilter { $Name -eq 'pwsh' }
        Mock Get-Command { [pscustomobject]@{ Source = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' } } `
            -ParameterFilter { $Name -eq 'powershell' }

        Get-PowerShellHostPath | Should-MatchString 'powershell\.exe$'
    }
}
