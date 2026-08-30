function Get-UpdateLogDirectory {
    # Resolves a writable directory for this run's logs, creating it if needed.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        # Preferred roots, most specific first. USERPROFILE is not guaranteed
        # (SYSTEM contexts, stripped environments), so the list is filtered for
        # non-empty entries rather than used to build a path from $null.
        [string[]] $Candidate = @($env:USERPROFILE, $env:LOCALAPPDATA, $env:TEMP, $PSScriptRoot)
    )

    $logRoot = $Candidate | Where-Object { $_ } | Select-Object -First 1
    if (-not $logRoot) { $logRoot = [System.IO.Path]::GetTempPath() }
    $logDir = Join-Path $logRoot 'UpdateLogs'

    try {
        if (-not (Test-Path -LiteralPath $logDir)) {
            $null = New-Item -ItemType Directory -Path $logDir -Force -ErrorAction Stop
        }
    } catch {
        $logDir = Join-Path ([System.IO.Path]::GetTempPath()) 'UpdateLogs'
        Write-Warning "Could not use the preferred log directory ($($_.Exception.Message)); falling back to $logDir."
        $null = New-Item -ItemType Directory -Path $logDir -Force -ErrorAction SilentlyContinue
    }

    $logDir
}
