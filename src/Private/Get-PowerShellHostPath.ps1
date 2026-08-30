function Get-PowerShellHostPath {
    # Prefer PowerShell 7 when it is installed: the script runs on either, but
    # pwsh is the host the rest of the toolchain assumes.
    [CmdletBinding()]
    [OutputType([string])]
    param()

    foreach ($candidate in 'pwsh', 'powershell') {
        $resolved = Get-Command $candidate -CommandType Application -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($resolved) { return $resolved.Source }
    }

    # Last resort: the host running this script.
    return (Get-Process -Id $PID).Path
}
