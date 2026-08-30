function New-UpdateTaskSettingsSet {
    # Task settings tuned for a laptop that is asleep, on battery, or off the
    # network as often as not.
    [CmdletBinding()]
    param(
        [switch] $AllowBattery,
        [int]    $ExecutionTimeLimitHours = 2
    )

    $settings = @{
        # A missed run happens at the next opportunity instead of waiting a whole
        # cycle. This is the setting that makes a schedule work on a laptop.
        StartWhenAvailable = $true

        # Nothing to update without a network, and retrying beats failing.
        RunOnlyIfNetworkAvailable = $true

        # A wedged installer should not hold the task open until the next reboot.
        ExecutionTimeLimit = (New-TimeSpan -Hours $ExecutionTimeLimitHours)

        # A run already in progress wins; a second one would fight it for the
        # same package managers and the same log files.
        MultipleInstances = 'IgnoreNew'

        # Transient network failures are the common case, so try again twice.
        RestartCount    = 2
        RestartInterval = (New-TimeSpan -Minutes 30)

        # Do not wake a sleeping laptop to install updates. StartWhenAvailable
        # picks the run up once it is awake anyway.
        WakeToRun = $false
    }

    if ($AllowBattery) {
        $settings['AllowStartIfOnBatteries']    = $true
        $settings['DontStopIfGoingOnBatteries'] = $true
    }

    New-ScheduledTaskSettingsSet @settings
}
