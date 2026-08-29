@{
    # Target the lowest runtime the script claims to support (#Requires -Version 5.1)
    # while still flagging syntax that breaks on PowerShell 7.
    Severity     = @('Error', 'Warning')

    ExcludeRules = @(
        # The script is a console maintenance tool; Write-Host is the intended UI.
        'PSAvoidUsingWriteHost',

        # Elevation relaunch and winget/choco calls legitimately build command
        # strings that are invoked indirectly.
        'PSAvoidUsingInvokeExpression',

        # Steps deliberately swallow and record failures so one bad channel does
        # not abort the run; empty catch blocks are reported through the summary.
        'PSAvoidUsingEmptyCatchBlock'
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
        PSUseConsistentIndentation = @{
            Enable          = $true
            IndentationSize = 4
            Kind            = 'space'
        }
    }
}
