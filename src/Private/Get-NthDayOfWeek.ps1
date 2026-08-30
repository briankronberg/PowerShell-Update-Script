function Get-NthDayOfWeek {
    # The Nth given weekday of a month, e.g. the third Wednesday of March 2027.
    [CmdletBinding()]
    [OutputType([datetime])]
    param(
        [Parameter(Mandatory)][int] $Year,
        [Parameter(Mandatory)][ValidateRange(1, 12)][int] $Month,
        [Parameter(Mandatory)][System.DayOfWeek] $DayOfWeek,
        [Parameter(Mandatory)][ValidateRange(1, 5)][int] $Occurrence
    )

    $date  = Get-Date -Year $Year -Month $Month -Day 1 -Hour 0 -Minute 0 -Second 0
    $found = 0
    while ($date.Month -eq $Month) {
        if ($date.DayOfWeek -eq $DayOfWeek) {
            $found++
            if ($found -eq $Occurrence) { return $date }
        }
        $date = $date.AddDays(1)
    }

    throw "There is no occurrence $Occurrence of $DayOfWeek in $Year-$Month."
}
