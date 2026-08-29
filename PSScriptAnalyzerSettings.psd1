@{
    # Gate on real problems only. The baseline below is clean, so any new finding
    # in CI is something the change actually introduced.
    Severity = @('Error', 'Warning')

    ExcludeRules = @(
        # The script is a console maintenance tool; Write-Host is the intended UI.
        'PSAvoidUsingWriteHost',

        # Elevation relaunch and package-manager calls legitimately build command
        # strings that are invoked indirectly.
        'PSAvoidUsingInvokeExpression',

        # Steps deliberately swallow and record failures so one bad channel does
        # not abort the run; every failure surfaces in the summary and step log.
        'PSAvoidUsingEmptyCatchBlock',

        # Internal helpers in a script whose entire purpose is changing system
        # state. -WhatIf on Set-PwshAsWindowsTerminalDefault would be noise;
        # the real safety valves are the per-feature parameters.
        'PSUseShouldProcessForStateChangingFunctions',

        # False positive on the [MatchEvaluator] { param($m) ... } delegate,
        # whose signature requires the parameter whether or not it is read.
        'PSReviewUnusedParameter',

        # Fires on the script's deliberate formatting of backtick line
        # continuations and multi-line pipeline script blocks.
        'PSUseConsistentIndentation'
    )

    Rules = @{
        PSUseCompatibleSyntax = @{
            Enable         = $true
            TargetVersions = @('5.1', '7.0')
        }
        PSPlaceOpenBrace = @{
            Enable             = $true
            OnSameLine         = $true
            NewLineAfter       = $true
            IgnoreOneLineBlock = $true
        }
    }
}
