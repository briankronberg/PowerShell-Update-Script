function Get-CadenceDescription {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string] $Cadence,
        [Parameter(Mandatory)][System.DayOfWeek] $DayOfWeek,
        [Parameter(Mandatory)][datetime] $At
    )

    $time = $At.ToString('HH:mm')
    switch ($Cadence) {
        'Daily'        { "every day at $time" }
        'Weekly'       { "every $DayOfWeek at $time" }
        'PatchTuesday' { "the third Wednesday of each month at $time (always after Patch Tuesday)" }
    }
}
