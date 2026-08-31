function Initialize-UpdateEverything {
    <#
        .SYNOPSIS
        Sets up UpdateEverything on a machine, from a menu.

        .DESCRIPTION
        A new install leaves you at Update-Everything with no guidance, and the
        things worth doing first -- getting PowerShell 7 and a notification
        module in place, registering a scheduled task, installing the tools this
        module then has something to update -- are each a separate command to
        discover.

            UpdateEverything setup

              1. Run prerequisites only
              2. Set up a scheduled task
              3. Install developer tools
              4. Perform a full first run
              5. Exit

        Typed numbers rather than arrow keys. It needs no dependency, it works
        over a remote session and in a host with no cursor control, and it can be
        tested without simulating key events.

        The menu repeats until you choose Exit, because setting a task up and
        then running for the first time is two answers, not two sessions.

        Nothing here installs anything without asking. Options 1 and 3 both go
        through Approve-Install like every other install in this module.

        .PARAMETER Choice
        Take this option and return instead of showing the menu. Intended for
        tests and for a caller that already knows what it wants; a person should
        use the menu.

        .EXAMPLE
        Initialize-UpdateEverything

        .EXAMPLE
        Initialize-UpdateEverything -Choice DeveloperTools
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Write-Host is the user interface of a console maintenance tool. This is a menu a person reads and answers, not data a caller consumes.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'The menu is the confirmation. Every option states what it will do before doing it, and the installs go through Approve-Install.')]
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [ValidateSet('Prerequisites', 'ScheduledTask', 'DeveloperTools', 'FirstRun')]
        [string] $Choice
    )

    $options = [ordered]@{
        '1' = @{ Key = 'Prerequisites';  Label = 'Run prerequisites only (PowerShell 7, notifications, gallery tooling)' }
        '2' = @{ Key = 'ScheduledTask';  Label = 'Set up a scheduled task' }
        '3' = @{ Key = 'DeveloperTools'; Label = 'Install developer tools' }
        '4' = @{ Key = 'FirstRun';       Label = 'Perform a full first run' }
        '5' = @{ Key = 'Exit';           Label = 'Exit' }
    }

    if ($Choice) {
        Invoke-SetupChoice -Key $Choice
        return
    }

    if (-not (Test-CanPrompt)) {
        Write-Warning 'The setup menu needs an interactive console, and this session cannot prompt.'
        Write-Warning 'Pass -Choice to take one option directly, or run Update-Everything instead.'
        return
    }

    while ($true) {
        Write-Host ''
        Write-Host 'UpdateEverything setup' -ForegroundColor Cyan
        Write-Host ''
        foreach ($entry in $options.GetEnumerator()) {
            Write-Host ("  {0}. {1}" -f $entry.Key, $entry.Value.Label)
        }
        Write-Host ''

        $answer = (Read-Host 'Choose [1-5]').Trim()

        if (-not $options.Contains($answer)) {
            Write-Host "  '$answer' is not one of the options." -ForegroundColor Yellow
            continue
        }

        $key = $options[$answer].Key
        if ($key -eq 'Exit') {
            Write-Host 'Nothing further. Run Initialize-UpdateEverything again whenever you want this menu.' -ForegroundColor DarkGray
            return
        }

        Invoke-SetupChoice -Key $key
    }
}
