function New-UpdateTaskTrigger {
    # Builds the trigger for a cadence.
    #
    # New-ScheduledTaskTrigger has no monthly parameter set at all -- it offers
    # Once, Daily, Weekly, Startup and Logon and nothing else -- so the monthly
    # case is built directly from the Task Scheduler CIM class instead.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Builds an object and changes nothing, so there is no operation for -WhatIf to describe.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('Weekly', 'PatchTuesday', 'Daily')]
        [string] $Cadence,

        [Parameter(Mandatory)][System.DayOfWeek] $DayOfWeek,

        [Parameter(Mandatory)][datetime] $At,

        # Spread of the start time. This belongs to the trigger, not the task
        # settings: New-ScheduledTaskSettingsSet has no -RandomDelay at all, and
        # passing one there fails at run time.
        [ValidateRange(0, 1440)]
        [int] $RandomDelayMinutes = 0
    )

    # RandomDelay is a *string* CIM property holding an ISO 8601 duration, so
    # assigning a [TimeSpan] to it after the fact writes "00:15:00" and
    # Register-ScheduledTask then rejects the task XML with "contains a value
    # which is incorrectly formatted or out of range". The cmdlet's own
    # -RandomDelay parameter converts a TimeSpan properly, to "PT15M".
    $extra = @{}
    if ($RandomDelayMinutes -gt 0) {
        $extra['RandomDelay'] = New-TimeSpan -Minutes $RandomDelayMinutes
    }

    switch ($Cadence) {
        'Daily' {
            return New-ScheduledTaskTrigger -Daily -At $At @extra
        }
        'Weekly' {
            return New-ScheduledTaskTrigger -Weekly -DaysOfWeek $DayOfWeek -At $At @extra
        }
        'PatchTuesday' {
            # A weekly trigger on the right weekday and time, which
            # Register-UpdateEverythingTask converts to "the third Wednesday of
            # every month" through Set-MonthlyDayOfWeekTrigger once the task
            # exists.
            #
            # It is not built here because it cannot be. Register-ScheduledTask
            # takes a CimInstance#MSFT_TaskTrigger, and a client-only
            # MSFT_TaskMonthlyDOWTrigger is not one: it lacks the type name, and
            # adding the name by hand passes binding only to fail a layer deeper
            # with "Type mismatch". Rewriting the registered task's XML is the
            # way through, and that needs a registered task.
            $start = Get-NthDayOfWeek -Year $At.Year -Month $At.Month `
                -DayOfWeek ([System.DayOfWeek]::Wednesday) -Occurrence 3
            $start = $start.Date.Add($At.TimeOfDay)

            return New-ScheduledTaskTrigger -Weekly `
                -DaysOfWeek ([System.DayOfWeek]::Wednesday) -At $start @extra
        }
    }
}
