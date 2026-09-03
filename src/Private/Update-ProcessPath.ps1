function Update-ProcessPath {
    <#
        .SYNOPSIS
        Brings this process's PATH up to date with the machine and user PATH.

        .DESCRIPTION
        A step that installs a manager writes to the machine or user PATH in the
        registry, and a process keeps the PATH it started with. Without this, a
        tool installed by one step is found by the next run rather than the next
        step.

        The result is the process-only entries first, in their existing order,
        then the machine entries, then the user entries, each once. Process-only
        entries are the ones neither hive lists: an activated virtual environment,
        a per-session prepend. They keep their place at the front so what they
        shadow stays shadowed.

        Returns the entries that were in a hive and not in the process PATH
        before, so the caller can say what the run gained. Returns nothing, and
        changes nothing, when neither hive could be read.

        .PARAMETER MachinePath
        The machine PATH, unexpanded. Read from the registry when not given.

        .PARAMETER UserPath
        The user PATH, unexpanded. Read from the registry when not given.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Changes only this process''s PATH, to match what the registry already says. Nothing on the machine is touched, and the run that calls it reports every entry gained.')]
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [string] $MachinePath,
        [string] $UserPath
    )

    # DoNotExpandEnvironmentNames, then expand: Get-ItemProperty expands the
    # REG_EXPAND_SZ value itself, but against this process's environment, which is
    # the thing being brought up to date.
    $read = {
        param($Key)
        try {
            $item = Get-Item -LiteralPath $Key -ErrorAction Stop
            [string] $item.GetValue('Path', '', 'DoNotExpandEnvironmentNames')
        } catch {
            Write-Verbose "Could not read PATH from ${Key}: $($_.Exception.Message)"
            ''
        }
    }
    if (-not $PSBoundParameters.ContainsKey('MachinePath')) {
        $MachinePath = & $read 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment'
    }
    if (-not $PSBoundParameters.ContainsKey('UserPath')) {
        $UserPath = & $read 'HKCU:\Environment'
    }
    if ([string]::IsNullOrWhiteSpace($MachinePath) -and [string]::IsNullOrWhiteSpace($UserPath)) {
        return
    }

    $split = {
        param($Text)
        @(([Environment]::ExpandEnvironmentVariables([string] $Text) -split ';') |
            ForEach-Object { $_.Trim() } |
            Where-Object { $_ })
    }
    $before = @(& $split $env:PATH)
    $hive   = @(& $split $MachinePath) + @(& $split $UserPath)

    # Trailing separators are the usual reason one directory appears as two.
    $key = { param($Entry) $Entry.TrimEnd('\', '/') }
    $comparer = [System.StringComparer]::OrdinalIgnoreCase

    $inHive = [System.Collections.Generic.HashSet[string]]::new($comparer)
    foreach ($entry in $hive) { $null = $inHive.Add((& $key $entry)) }
    $inBefore = [System.Collections.Generic.HashSet[string]]::new($comparer)
    foreach ($entry in $before) { $null = $inBefore.Add((& $key $entry)) }

    $seen = [System.Collections.Generic.HashSet[string]]::new($comparer)
    $ordered = [System.Collections.Generic.List[string]]::new()
    foreach ($entry in $before) {
        if (-not $inHive.Contains((& $key $entry)) -and $seen.Add((& $key $entry))) { $ordered.Add($entry) }
    }
    $gained = [System.Collections.Generic.List[string]]::new()
    foreach ($entry in $hive) {
        if ($seen.Add((& $key $entry))) {
            $ordered.Add($entry)
            if (-not $inBefore.Contains((& $key $entry))) { $gained.Add($entry) }
        }
    }

    $env:PATH = $ordered -join ';'
    $gained
}
