function Set-PwshAsWindowsTerminalDefault {
    # Points Windows Terminal's defaultProfile at the PowerShell 7 (PowershellCore)
    # profile. Only the defaultProfile value is rewritten; nothing else is touched.
    param([Parameter(Mandatory)][string] $LogDir)

    $candidates = @(
        "$env:LOCALAPPDATA\Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json",
        "$env:LOCALAPPDATA\Packages\Microsoft.WindowsTerminalPreview_8wekyb3d8bbwe\LocalState\settings.json",
        "$env:LOCALAPPDATA\Microsoft\Windows Terminal\settings.json"
    )
    # Indexed, not Select-Object -First: see the note in the Microsoft 365 step.
    $present = @($candidates | Where-Object { Test-Path -LiteralPath $_ })
    $settingsPath = if ($present.Count) { $present[0] } else { $null }
    if (-not $settingsPath) {
        Write-Host 'Windows Terminal settings.json not found; Terminal not installed for this user. Skipping.'
        return
    }
    Write-Host "Windows Terminal settings: $settingsPath"

    # Terminal rewrites settings.json from memory when it exits, which silently
    # reverts an edit made while it is running.
    if (Get-Process -Name 'WindowsTerminal', 'WindowsTerminalPreview' -ErrorAction SilentlyContinue) {
        Write-Warning 'Windows Terminal is running. It rewrites settings.json on exit and may revert this change; close it and re-run if the default does not stick.'
    }

    $raw = Get-Content -Raw -LiteralPath $settingsPath -ErrorAction Stop
    if ([string]::IsNullOrWhiteSpace($raw)) {
        throw "settings.json at $settingsPath is empty; refusing to edit it."
    }

    $cfg = $null
    try {
        $cfg = Remove-JsonComment -Text $raw | ConvertFrom-Json -ErrorAction Stop
    } catch {
        Write-Warning "settings.json did not parse even after stripping comments: $($_.Exception.Message)"
    }

    # Stable V5 UUID the PowershellCore generator assigns to the primary pwsh
    # install; used as a fallback if the profile is not yet materialized in the file.
    $wellKnownPwsh = '{574e775e-4f2a-5b96-ac1e-a2962a402336}'
    $ps7Guid = $null
    if ($cfg -and $cfg.profiles -and $cfg.profiles.list) {
        $p = $cfg.profiles.list | Where-Object { $_.source -eq 'Windows.Terminal.PowershellCore' } | Select-Object -First 1
        if (-not $p) { $p = $cfg.profiles.list | Where-Object { $_.commandline -match 'pwsh' } | Select-Object -First 1 }
        if ($p -and $p.guid) { $ps7Guid = $p.guid }
    }
    if (-not $ps7Guid) {
        $ps7Guid = $wellKnownPwsh
        Write-Host "No PowerShell Core profile present yet; using well-known GUID $ps7Guid (Terminal generates it on next launch)."
    } else {
        Write-Host "PowerShell 7 profile GUID: $ps7Guid"
    }

    # Read the current value from the parsed object when possible, and from the
    # raw text otherwise, so a parse failure cannot turn a no-op into a rewrite.
    $current = ''
    if ($cfg -and ($cfg.PSObject.Properties.Name -contains 'defaultProfile')) {
        $current = [string]$cfg.defaultProfile
    } elseif ($raw -match '"defaultProfile"\s*:\s*"([^"]*)"') {
        $current = $Matches[1]
    }

    if ($current -eq $ps7Guid) {
        Write-Host "Default profile is already PowerShell 7 ($ps7Guid). No change needed."
        return
    }
    Write-Host "Current default profile: $current"

    $backup = Join-Path $LogDir ("WindowsTerminal-settings-{0:yyyyMMdd-HHmmss}.json.bak" -f (Get-Date))
    try {
        Copy-Item -LiteralPath $settingsPath -Destination $backup -Force -ErrorAction Stop
    } catch {
        throw "Could not back up settings.json to $backup; refusing to edit without a backup. $($_.Exception.Message)"
    }
    Write-Host "Backed up settings.json -> $backup"

    $newKv = '"defaultProfile": "' + $ps7Guid + '"'
    # Match any string value, not just a GUID. Terminal also accepts a profile
    # name here, and the old GUID-only pattern missed that case and fell through
    # to the insert branch, producing a second defaultProfile key.
    $pattern = '"defaultProfile"\s*:\s*"[^"]*"'
    if ($raw -match $pattern) {
        $updated = [regex]::Replace($raw, $pattern, [System.Text.RegularExpressions.MatchEvaluator]{ param($m) $newKv })
    } else {
        # No defaultProfile key present: insert it right after the opening brace
        $updated = [regex]::Replace($raw, '\A(\s*\{)', [System.Text.RegularExpressions.MatchEvaluator]{ param($m) $m.Groups[1].Value + "`r`n    $newKv," })
    }

    # Guard against the duplicate-key failure mode: Terminal takes the last one,
    # so two keys would make the edit look applied while doing nothing.
    $keyCount = ([regex]::Matches($updated, '"defaultProfile"\s*:')).Count
    if ($keyCount -ne 1) {
        throw "Refusing to write: the edit produced $keyCount 'defaultProfile' keys, expected exactly 1."
    }

    # Only trust the edit if the result is still valid JSON (when the original was)
    if ($cfg) {
        try { $null = Remove-JsonComment -Text $updated | ConvertFrom-Json -ErrorAction Stop }
        catch { throw "Refusing to write: edited settings.json is not valid JSON ($($_.Exception.Message))." }
    }

    try {
        [System.IO.File]::WriteAllText($settingsPath, $updated, [System.Text.UTF8Encoding]::new($false))
    } catch {
        throw "Could not write settings.json (is Windows Terminal holding the file?): $($_.Exception.Message)"
    }
    Write-Host "Set Windows Terminal default profile to PowerShell 7 ($ps7Guid). Restart Windows Terminal to apply."
}
