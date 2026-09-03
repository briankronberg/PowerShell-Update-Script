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

        # This used to assert a hand-built MSFT_TaskMonthlyDOWTrigger, and every
        # assertion passed while the cadence could not register a task at all:
        # Register-ScheduledTask refuses a client-only instance of that class.
        # The monthly shape is now asserted where it is actually applied, by the
        # Integration tests at the end of this file.
        It 'returns a trigger Register-ScheduledTask will accept' {
            $trigger = New-UpdateTaskTrigger -Cadence PatchTuesday -DayOfWeek Wednesday -At '12:00'
            $trigger.PSObject.TypeNames |
                Should-ContainCollection 'Microsoft.Management.Infrastructure.CimInstance#MSFT_TaskTrigger'
        }

        It 'targets Wednesday' {
            $trigger = New-UpdateTaskTrigger -Cadence PatchTuesday -DayOfWeek Wednesday -At '12:00'
            $trigger.DaysOfWeek | Should-Be 8
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
            Should-MatchString ([regex]::Escape("Import-Module 'C:\Program Files\x\UpdateEverything\UpdateEverything.psd1'"))
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

    # Update-Everything notifies by default, so leaving -Notify out would turn
    # them back on.
    It 'says notifications are off when they are turned off' {
        Get-UpdateTaskArgument -ModuleRoot 'C:\x' -Notify $false | Should-MatchString ([regex]::Escape('-Notify:$false'))
    }

    It 'quotes each approval so the child parses them as a list' {
        Get-UpdateTaskArgument -ModuleRoot 'C:\x' -AllowInstall 'PSWindowsUpdate', 'BurntToast' |
            Should-MatchString ([regex]::Escape("-AllowInstall 'PSWindowsUpdate','BurntToast'"))
    }

    It 'appends extra arguments' {
        Get-UpdateTaskArgument -ModuleRoot 'C:\x' -ExtraArgument '-IncludeWindowsUpdate', '$false' |
            Should-MatchString ([regex]::Escape('-IncludeWindowsUpdate $false'))
    }

    It 'quotes each tag so the child parses them as a list' {
        Get-UpdateTaskArgument -ModuleRoot 'C:\x' -Tag 'Node', 'Cloud' |
            Should-MatchString ([regex]::Escape("-Tag 'Node','Cloud'"))
    }

    It 'quotes exclusions the same way' {
        Get-UpdateTaskArgument -ModuleRoot 'C:\x' -ExcludeTag 'Cloud' |
            Should-MatchString ([regex]::Escape("-ExcludeTag 'Cloud'"))
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

Describe 'Registration refusals' -Tag 'Unit' {

    # Both guards throw before anything is created, so a refused registration
    # leaves no task behind.

    BeforeEach {
        Mock Write-Host { }
        Mock Register-ScheduledTask { }
        Mock Get-ScheduledTask { }
    }

    It 'refuses a session without elevation' {
        Mock Test-IsAdministrator { $false }

        { Register-UpdateEverythingTask } | Should-Throw -ExceptionMessage '*elevated session*'
        Should-NotInvoke Register-ScheduledTask
    }

    It 'refuses to replace an existing task without -Force' {
        Mock Test-IsAdministrator { $true }
        Mock Get-ScheduledTask { [pscustomobject]@{ TaskName = 'Update-Everything' } }

        { Register-UpdateEverythingTask } | Should-Throw -ExceptionMessage '*already exists*'
        Should-NotInvoke Register-ScheduledTask
    }

    # A scheduled run cannot prompt for consent to install BurntToast, so a
    # task registered with -Notify and no way to notify deserves a warning now,
    # not silence at three in the morning.
    It 'warns when the task will notify nobody' {
        Mock Test-IsAdministrator { $true }
        Mock Test-NotificationModuleAvailable { $false }
        Mock Register-ScheduledTask { [pscustomobject]@{ TaskName = $TaskName } }

        $everything = @(Register-UpdateEverythingTask 3>&1)

        "$($everything -join ' ')" | Should-MatchString 'notify nobody'
    }

    # A task has nobody at the window, so -Attended in -ExtraArgument would hold
    # every run open until the hold timed out.
    It 'warns when the task would hold the window for nobody' {
        Mock Test-IsAdministrator { $true }
        Mock Test-NotificationModuleAvailable { $true }
        Mock Register-ScheduledTask { [pscustomobject]@{ TaskName = $TaskName } }

        $everything = @(Register-UpdateEverythingTask -ExtraArgument '-Attended' 3>&1)

        "$($everything -join ' ')" | Should-MatchString 'nobody at the window'
    }
}

Describe 'Unregister-UpdateEverythingTask' -Tag 'Unit' {

    BeforeEach {
        Mock Write-Host { }
        Mock Unregister-ScheduledTask { }
    }

    It 'removes the task when it exists' {
        Mock Get-ScheduledTask { [pscustomobject]@{ TaskName = 'Update-Everything' } }

        Unregister-UpdateEverythingTask -Confirm:$false

        Should-Invoke Unregister-ScheduledTask -Times 1 -Exactly -ParameterFilter {
            $TaskName -eq 'Update-Everything'
        }
    }

    It 'does nothing, quietly, when there is no task' {
        Mock Get-ScheduledTask { }

        Unregister-UpdateEverythingTask -Confirm:$false

        Should-NotInvoke Unregister-ScheduledTask
    }

    It 'carries a custom name and folder through' {
        Mock Get-ScheduledTask { [pscustomobject]@{ TaskName = 'Nightly' } }

        Unregister-UpdateEverythingTask -TaskName 'Nightly' -TaskPath '\WWT\' -Confirm:$false

        Should-Invoke Unregister-ScheduledTask -Times 1 -Exactly -ParameterFilter {
            $TaskName -eq 'Nightly' -and $TaskPath -eq '\WWT\'
        }
    }

    # Removing a schedule is the operation -WhatIf exists for.
    It 'honours -WhatIf' {
        Mock Get-ScheduledTask { [pscustomobject]@{ TaskName = 'Update-Everything' } }

        Unregister-UpdateEverythingTask -WhatIf

        Should-NotInvoke Unregister-ScheduledTask
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

    # When the MSI path is absent and no unpackaged host resolves, the task
    # gets the process running this script rather than nothing.
    It 'falls back to the process running these tests when nothing resolves' {
        Mock Test-Path { $false }
        Mock Get-Command { }

        Get-PowerShellHostPath | Should-Be (Get-Process -Id $PID).Path
    }

    # This path is baked into a scheduled task, so it has to still exist months
    # later. A packaged pwsh resolves to
    # ...\WindowsApps\Microsoft.PowerShell_7.6.5.0_x64__8wekyb3d8bbwe\pwsh.exe,
    # which carries the version and disappears at the next update, and the app
    # execution alias beside it is a zero-byte reparse point Task Scheduler
    # cannot launch. Neither is a thing to write into a task definition.

    It 'returns a path that exists' {
        Test-Path -LiteralPath (Get-PowerShellHostPath) | Should-BeTrue
    }

    It 'prefers the MSI install, whose path does not move' {
        Mock Test-Path { $true } -ParameterFilter { $LiteralPath -like '*PowerShell\7\pwsh.exe' }

        Get-PowerShellHostPath | Should-Be (Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe')
    }

    It 'prefers an unpackaged pwsh on PATH when there is no MSI install' {
        Mock Test-Path { $false } -ParameterFilter { $LiteralPath -like '*PowerShell\7\pwsh.exe' }
        Mock Get-Command { [pscustomobject]@{ Source = 'D:\tools\pwsh.exe' } } `
            -ParameterFilter { $Name -eq 'pwsh' }

        Get-PowerShellHostPath | Should-Be 'D:\tools\pwsh.exe'
    }

    # The regression: a task registered on an MSIX-only machine used to name a
    # version-stamped WindowsApps path and die at the next PowerShell update.
    # Windows PowerShell at a path that has not moved in twenty years is the
    # better answer, and the module supports 5.1 anyway.
    It 'skips a packaged pwsh in favour of Windows PowerShell' {
        Mock Test-Path { $false } -ParameterFilter { $LiteralPath -like '*PowerShell\7\pwsh.exe' }
        Mock Get-Command {
            [pscustomobject]@{ Source = "$env:ProgramFiles\WindowsApps\Microsoft.PowerShell_7.6.5.0_x64__8wekyb3d8bbwe\pwsh.exe" }
        } -ParameterFilter { $Name -eq 'pwsh' }
        Mock Get-Command { [pscustomobject]@{ Source = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' } } `
            -ParameterFilter { $Name -eq 'powershell' }

        Get-PowerShellHostPath | Should-MatchString 'powershell\.exe$'
    }

    It 'never returns an app execution alias' {
        Mock Test-Path { $false } -ParameterFilter { $LiteralPath -like '*PowerShell\7\pwsh.exe' }
        Mock Get-Command {
            [pscustomobject]@{ Source = "$env:LOCALAPPDATA\Microsoft\WindowsApps\pwsh.exe" }
        } -ParameterFilter { $Name -eq 'pwsh' }
        Mock Get-Command { [pscustomobject]@{ Source = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' } } `
            -ParameterFilter { $Name -eq 'powershell' }

        Get-PowerShellHostPath | Should-NotMatchString 'WindowsApps'
    }

    It 'falls back to Windows PowerShell when pwsh is absent' {
        Mock Test-Path { $false } -ParameterFilter { $LiteralPath -like '*PowerShell\7\pwsh.exe' }
        Mock Get-Command { } -ParameterFilter { $Name -eq 'pwsh' }
        Mock Get-Command { [pscustomobject]@{ Source = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' } } `
            -ParameterFilter { $Name -eq 'powershell' }

        Get-PowerShellHostPath | Should-MatchString 'powershell\.exe$'
    }
}

Describe 'Finding every task this module registered' -Tag 'Unit' {

    # Found by what they run, not by what they are called. A machine can carry
    # several: a daily run that skips a toolchain and a monthly one that updates
    # only that toolchain, which is what -Tag and -ExcludeTag are for.

    BeforeAll {
        $script:MakeTask = {
            param($Name, $Arguments)
            [pscustomobject]@{
                TaskName  = $Name
                TaskPath  = '\'
                State     = 'Ready'
                Principal = [pscustomobject]@{ UserId = 'me'; RunLevel = 'Highest'; LogonType = 'Interactive' }
                Actions   = @([pscustomobject]@{ Execute = 'pwsh.exe'; Arguments = $Arguments })
            }
        }

        $script:Ours = "-NoProfile -Command `"Import-Module 'C:\M\UpdateEverything\1.0.0\UpdateEverything.psd1' -Force; exit (Update-Everything -Notify).FailedCount`""
        $script:Theirs = '-NoProfile -Command "Write-Host hello"'
    }

    BeforeEach {
        # Task Scheduler reports a never-run task with the 1899 sentinel rather
        # than a null, and Format-LastRunResult takes a [datetime].
        Mock Get-ScheduledTaskInfo {
            [pscustomobject]@{
                LastRunTime    = [datetime]'1899-12-30'
                LastTaskResult = 267011
                NextRunTime    = [datetime]'2026-09-07 03:00'
            }
        }
    }

    It 'returns every task that runs this module' {
        Mock Get-ScheduledTask {
            @(
                & $script:MakeTask 'Update-Everything' $script:Ours
                & $script:MakeTask 'Update-Everything-Python' $script:Ours
            )
        }

        @(Get-UpdateEverythingTask) | Should-BeCollection -Count 2
    }

    # A task called Update-Everything that runs something else is not this
    # module's, and removing it because of its name would be destructive.
    It 'ignores a task that only shares the name' {
        Mock Get-ScheduledTask {
            @(& $script:MakeTask 'Update-Everything' $script:Theirs)
        }

        Get-UpdateEverythingTask | Should-BeNull
    }

    # A task renamed by hand is still this module's task.
    It 'finds one that was renamed' {
        Mock Get-ScheduledTask {
            @(& $script:MakeTask 'Nightly maintenance' $script:Ours)
        }

        (Get-UpdateEverythingTask).TaskName | Should-Be 'Nightly maintenance'
    }

    It 'returns nothing when none are registered' {
        Mock Get-ScheduledTask { @() }

        Get-UpdateEverythingTask | Should-BeNull
    }

    It 'still takes one by exact name' {
        Mock Get-ScheduledTask { @(& $script:MakeTask 'Update-Everything-Python' $script:Ours) } `
            -ParameterFilter { $TaskName -eq 'Update-Everything-Python' }

        (Get-UpdateEverythingTask -TaskName 'Update-Everything-Python').TaskName |
            Should-Be 'Update-Everything-Python'
    }
}

Describe 'Select-TaskFromList' -Tag 'Unit' {

    BeforeAll {
        $script:Two = @(
            [pscustomobject]@{ TaskName = 'one' }
            [pscustomobject]@{ TaskName = 'two' }
        )
    }

    It 'returns the task at the number typed' {
        Mock Read-Host { '2' }
        (Select-TaskFromList -Task $script:Two -Prompt 'x').TaskName | Should-Be 'two'
    }

    It 'returns nothing for a blank answer' {
        Mock Read-Host { '' }
        Select-TaskFromList -Task $script:Two -Prompt 'x' | Should-BeNull
    }

    # Acting on a mistyped number would be worse than asking again.
    It 'returns nothing for a number that is not listed' {
        Mock Read-Host { '9' }
        Mock Write-Host { }
        Select-TaskFromList -Task $script:Two -Prompt 'x' | Should-BeNull
    }

    It 'returns nothing for an answer that is not a number' {
        Mock Read-Host { 'both' }
        Mock Write-Host { }
        Select-TaskFromList -Task $script:Two -Prompt 'x' | Should-BeNull
    }

    It 'returns nothing when there is nothing to choose from' {
        Select-TaskFromList -Task @() -Prompt 'x' | Should-BeNull
    }
}

Describe 'Adding a second task' -Tag 'Unit' {

    # A second task, not a second trigger. Every trigger on a task runs the same
    # action, so two triggers cannot express "everything but Python daily, only
    # Python monthly" -- which is the reason for wanting a second run at all.

    BeforeEach {
        Mock Write-Host { }
        Mock Register-UpdateEverythingTask { }
        Mock Get-UpdateEverythingTask { @([pscustomobject]@{ TaskName = 'Update-Everything' }) }
    }

    It 'suggests a name that is not already taken' {
        $script:answers = @('', '', '', '')
        $script:next = 0
        Mock Read-Host { $script:answers[$script:next++] }

        New-TaskFromPrompt

        Should-Invoke Register-UpdateEverythingTask -ParameterFilter { $TaskName -eq 'Update-Everything-2' }
    }

    It 'passes the tags through, which is the whole point of a second task' {
        $script:answers = @('Update-Everything-Python', 'Daily', 'Python', '')
        $script:next = 0
        Mock Read-Host { $script:answers[$script:next++] }

        New-TaskFromPrompt

        Should-Invoke Register-UpdateEverythingTask -ParameterFilter {
            $TaskName -eq 'Update-Everything-Python' -and $Cadence -eq 'Daily' -and $Tag -contains 'Python'
        }
    }

    It 'passes an exclusion through' {
        $script:answers = @('daily-task', 'Daily', '', 'Python')
        $script:next = 0
        Mock Read-Host { $script:answers[$script:next++] }

        New-TaskFromPrompt

        Should-Invoke Register-UpdateEverythingTask -ParameterFilter { $ExcludeTag -contains 'Python' }
    }

    # Monthly is the obvious guess and is not one of the names: the monthly
    # cadence here is PatchTuesday. Catching it turns a binding failure into a
    # sentence.
    It 'refuses a cadence it does not offer' {
        $script:answers = @('x', 'Monthly', '', '')
        $script:next = 0
        Mock Read-Host { $script:answers[$script:next++] }

        New-TaskFromPrompt -WarningAction SilentlyContinue

        Should-NotInvoke Register-UpdateEverythingTask
    }

    # A tag outside the set selects nothing, so the task would run an empty pass
    # every month and report success.
    It 'refuses a tag that is not a real tag' {
        $script:answers = @('x', 'Weekly', 'Pythonn', '')
        $script:next = 0
        Mock Read-Host { $script:answers[$script:next++] }

        New-TaskFromPrompt -WarningAction SilentlyContinue

        Should-NotInvoke Register-UpdateEverythingTask
    }

    It 'replaces rather than refusing when told to' {
        $script:answers = @('', 'Weekly', '', '')
        $script:next = 0
        Mock Read-Host { $script:answers[$script:next++] }

        New-TaskFromPrompt -DefaultName 'Update-Everything' -Replace

        Should-Invoke Register-UpdateEverythingTask -ParameterFilter { $Force }
    }

    # Register throws on a session without elevation. Mid-wizard that becomes a
    # warning naming the cause, not a stack trace out of the menu.
    It 'turns a failed registration into a warning' {
        $script:answers = @('', '', '', '')
        $script:next = 0
        Mock Read-Host { $script:answers[$script:next++] }
        Mock Register-UpdateEverythingTask { throw 'requires an elevated session' }

        $warnings = @(New-TaskFromPrompt 3>&1)

        "$($warnings -join ' ')" | Should-MatchString 'Could not register the task'
        "$($warnings -join ' ')" | Should-MatchString 'elevated session'
    }
}

Describe 'Every cadence can actually register a task' -Tag 'Integration' {

    # This registers real scheduled tasks and removes them again, which
    # CONTRIBUTING otherwise rules out. The exception is documented there, and
    # this is the case that earned it: PatchTuesday shipped in 1.0.0 unable to
    # register at all, and every unit test passed the whole time.
    #
    # New-UpdateTaskTrigger's output was asserted and was correct. Nothing
    # handed it to Register-ScheduledTask, which is the only place it was
    # refused -- the bug lived in the join between two things that were each
    # fine, and only a real registration crosses that join.

    # BeforeDiscovery, not BeforeAll: -Skip: is evaluated while Pester is
    # discovering tests, which is before any BeforeAll has run. Setting it there
    # leaves $script:CanRegister null and skips the tests on a machine that could
    # have run them.
    BeforeDiscovery {
        $script:CanRegister = ([Security.Principal.WindowsPrincipal] `
            [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
                [Security.Principal.WindowsBuiltInRole]::Administrator)
    }

    BeforeAll {
        $script:TestTaskName = 'UpdateEverything-PesterCadence'
    }

    AfterEach {
        Unregister-ScheduledTask -TaskName $script:TestTaskName -Confirm:$false -ErrorAction SilentlyContinue
    }

    It 'registers a <_> task' -ForEach @('Daily', 'Weekly') -Skip:(-not $script:CanRegister) {
        $cadence = $_

        # Not wrapped in an assertion about throwing: if it throws, the test
        # fails with the actual message, which is more use than "expected not to
        # throw". This is how the cadence bug would have announced itself.
        Register-UpdateEverythingTask -TaskName $script:TestTaskName -Cadence $cadence `
            -Notify $false -Confirm:$false -ErrorAction Stop 6>$null | Out-Null

        Get-ScheduledTask -TaskName $script:TestTaskName -ErrorAction SilentlyContinue |
            Should-NotBeNull
    }

    # PatchTuesday is registered once here and asserted twice, rather than once
    # per test. Registering and removing real tasks costs seconds each against
    # the Task Scheduler, and the second registration would produce the same
    # task as the first.
    #
    # The parent AfterEach still runs between these two, so the export is taken
    # in BeforeAll while the task exists.
    Context 'PatchTuesday' -Skip:(-not $script:CanRegister) {

        BeforeAll {
            Register-UpdateEverythingTask -TaskName $script:TestTaskName -Cadence PatchTuesday `
                -Notify $false -Confirm:$false -ErrorAction Stop 6>$null | Out-Null

            $script:PatchTuesdayXml = [xml](Export-ScheduledTask -TaskName $script:TestTaskName)
        }

        It 'registers a task' {
            Get-ScheduledTask -TaskName $script:TestTaskName -ErrorAction SilentlyContinue |
                Should-NotBeNull
        }

        # Week 3, Wednesday, all twelve months. Registering is not enough on its
        # own: the weekly trigger it starts from would also register cleanly, and
        # would then run every week instead of every month.
        It 'gives it a monthly day-of-week trigger, not the weekly one it started as' {
            $schedule = $script:PatchTuesdayXml.Task.Triggers.CalendarTrigger.ScheduleByMonthDayOfWeek

            $schedule | Should-NotBeNull
            $schedule.Weeks.Week | Should-Be '3'
            @($schedule.DaysOfWeek.ChildNodes).Name | Should-Be 'Wednesday'
            @($schedule.Months.ChildNodes) | Should-BeCollection -Count 12
        }
    }
}
