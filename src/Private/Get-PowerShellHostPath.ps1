function Get-PowerShellHostPath {
    <#
        .SYNOPSIS
        The pwsh to bake into a scheduled task.

        .DESCRIPTION
        Prefer the MSI install. Resolving pwsh from PATH inside a packaged
        session returns

            ...\WindowsApps\Microsoft.PowerShell_7.6.5.0_x64__8wekyb3d8bbwe\pwsh.exe

        which carries the version, so it stops existing at the next PowerShell
        update and takes the task with it. The app execution alias that also
        resolves is no better: Task Scheduler cannot launch a zero-byte reparse
        point.

        Windows PowerShell remains the last resort, at a path that has not moved
        in twenty years.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $msi = Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe'
    if (Test-Path -LiteralPath $msi) { return $msi }

    foreach ($candidate in 'pwsh', 'powershell') {
        $resolved = Get-Command $candidate -CommandType Application -ErrorAction SilentlyContinue |
            Where-Object { -not (Test-PackagedProcess -Path $_.Source) } |
            Select-Object -First 1
        if ($resolved) { return $resolved.Source }
    }

    # Last resort: the host running this script. Packaged or not, a task that
    # names something is better than one that names nothing.
    (Get-Process -Id $PID).Path
}
