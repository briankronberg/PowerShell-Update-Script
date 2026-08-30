function Format-LastRunResult {
    # Task Scheduler reports a task that has never run as 30 November 1999 with
    # result 0x41303 (SCHED_S_TASK_HAS_NOT_RUN). Printed literally, that reads
    # like a failure on a task registered thirty seconds ago.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [datetime] $LastRunTime,
        [int]      $LastTaskResult
    )

    if ($LastTaskResult -eq 267011 -or $LastRunTime -lt [datetime] '2000-01-01') {
        return 'never'
    }

    if ($LastTaskResult -eq 0) {
        return "$LastRunTime (succeeded)"
    }

    # Update-Everything.ps1 exits with the number of failed steps, so a small
    # number here is a step count rather than a Windows error code.
    "{0} (exit {1}, 0x{1:X})" -f $LastRunTime, $LastTaskResult
}
