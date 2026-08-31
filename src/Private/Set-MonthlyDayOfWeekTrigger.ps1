function Set-MonthlyDayOfWeekTrigger {
    <#
        .SYNOPSIS
        Converts a registered task's trigger to "the Nth <weekday> of every
        month", by rewriting its XML.

        .DESCRIPTION
        Register-ScheduledTask has no way to accept a monthly day-of-week
        trigger. New-ScheduledTaskTrigger offers Once, Daily, Weekly, Startup and
        Logon and nothing else, and a client-only MSFT_TaskMonthlyDOWTrigger
        built with New-CimInstance is refused: it carries no
        CimInstance#MSFT_TaskTrigger type name, and inserting one by hand gets
        past parameter binding only to fail a layer deeper with "Type mismatch".

        So the task is registered with an ordinary weekly trigger first, and its
        exported XML is rewritten and registered again. Task Scheduler accepts
        from XML what the cmdlets cannot express.

        The namespace is declared on the fragment rather than left to the parent.
        Elements assigned through InnerXml do not inherit the document's default
        namespace, and Task Scheduler rejects the result with "The task XML
        contains an element or attribute from an unexpected namespace".

        .PARAMETER Occurrence
        Which one in the month: 1 to 4, or 5 for the last.

        .EXAMPLE
        Set-MonthlyDayOfWeekTrigger -TaskName Update-Everything -TaskPath '\' `
            -Start (Get-Date '03:00') -DayOfWeek Wednesday -Occurrence 3
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Called only by Register-UpdateEverythingTask, immediately after it registered the task and inside its own ShouldProcess. A second confirmation for finishing one registration would be noise.')]
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string] $TaskName,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string] $TaskPath,
        [Parameter(Mandatory)][datetime] $Start,
        [Parameter(Mandatory)][System.DayOfWeek] $DayOfWeek,
        [Parameter(Mandatory)][ValidateRange(1, 5)][int] $Occurrence,
        [ValidateRange(0, 1440)][int] $RandomDelayMinutes = 0
    )

    $xml = [xml](Export-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath)
    $uri = $xml.DocumentElement.NamespaceURI

    $manager = New-Object System.Xml.XmlNamespaceManager($xml.NameTable)
    $manager.AddNamespace('t', $uri)

    $triggers = $xml.SelectSingleNode('//t:Triggers', $manager)
    if (-not $triggers) { throw "The exported XML for '$TaskName' has no Triggers element." }

    $months = (@('January', 'February', 'March', 'April', 'May', 'June', 'July',
                 'August', 'September', 'October', 'November', 'December') |
        ForEach-Object { "<$_ />" }) -join ''

    # ISO 8601, the same form the CIM class wants. A [TimeSpan] rendered as
    # "00:15:00" is rejected as incorrectly formatted.
    $delay = if ($RandomDelayMinutes -gt 0) { "<RandomDelay>PT${RandomDelayMinutes}M</RandomDelay>" } else { '' }

    $triggers.InnerXml =
        "<CalendarTrigger xmlns='$uri'>" +
        "<StartBoundary>$($Start.ToString('s'))</StartBoundary>" +
        '<Enabled>true</Enabled>' +
        '<ScheduleByMonthDayOfWeek>' +
        "<Weeks><Week>$Occurrence</Week></Weeks>" +
        "<DaysOfWeek><$DayOfWeek /></DaysOfWeek>" +
        "<Months>$months</Months>" +
        '</ScheduleByMonthDayOfWeek>' +
        $delay +
        '</CalendarTrigger>'

    $null = Register-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath `
        -Xml $xml.OuterXml -Force -ErrorAction Stop
}
