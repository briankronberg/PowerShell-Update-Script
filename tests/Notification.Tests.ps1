#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '6.0' }

<#
    Tests for the toast-notification path.

    BurntToast is an optional dependency and is not installed on CI, so these
    tests never rely on it being present. A stub stands in for
    New-BurntToastNotification, which also means no test ever pops a real toast
    on the machine running the suite.

    The behaviour under test is mostly about degrading quietly: a missing
    module, a non-interactive session or a failed toast must never be the reason
    a maintenance run does not happen.
#>

BeforeAll {
    . (Join-Path (Split-Path $PSScriptRoot -Parent) 'Update-Everything.ps1')

    # Stand-in for the real cmdlet. Pester cannot mock a command that does not
    # exist, and BurntToast is deliberately not a hard dependency.
    function New-BurntToastNotification {
        param(
            [string[]] $Text,
            [string]   $UniqueIdentifier,
            [switch]   $Urgent
        )
    }
}

Describe 'Initialize-NotificationSupport' -Tag 'Unit','Notification' {

    Context 'No interactive session' {

        BeforeEach { Mock Test-InteractiveSession { $false } }

        # A scheduled task running as SYSTEM has no desktop to draw a toast on.
        It 'reports notifications as unavailable' {
            (Initialize-NotificationSupport -WarningAction SilentlyContinue).Available | Should-BeFalse
        }

        It 'explains why, so the schedule can be fixed' {
            $warnings = @()
            $null = Initialize-NotificationSupport -WarningVariable warnings -WarningAction SilentlyContinue

            ($warnings -join ' ') | Should-MatchString 'interactive'
        }

        It 'does not try to install anything' {
            Mock Install-Module { }
            $null = Initialize-NotificationSupport -Approved @('BurntToast') -WarningAction SilentlyContinue

            Should-NotInvoke Install-Module
        }
    }

    Context 'BurntToast missing' {

        BeforeEach {
            Mock Test-InteractiveSession { $true }
            Mock Get-Module { } -ParameterFilter { $Name -eq 'BurntToast' }
            # Never reach a real prompt: PromptForChoice would block the suite
            # forever on redirected stdin.
            Mock Test-CanPrompt { $true }
            Mock Request-InstallConsent { $false }
        }

        It 'declines rather than installing uninvited' {
            (Initialize-NotificationSupport -WarningAction SilentlyContinue).Available | Should-BeFalse
        }

        # The install command now travels in the returned reason rather than a
        # warning, so the closing summary can repeat it verbatim.
        It 'says how to install it' {
            $result = Initialize-NotificationSupport -WarningAction SilentlyContinue

            $result.Reason | Should-MatchString 'Install-Module BurntToast'
        }

        It 'points at -AllowInstall as the other way in' {
            $result = Initialize-NotificationSupport -WarningAction SilentlyContinue

            $result.Reason | Should-MatchString '-AllowInstall BurntToast'
        }

        # The reason is returned as well as warned, so the end-of-run summary can
        # repeat it. By then the warning itself is thousands of lines back.
        It 'returns a reason the summary can repeat' {
            $result = Initialize-NotificationSupport -WarningAction SilentlyContinue
            $result.Reason | Should-MatchString 'not installed'
        }

        It 'installs when explicitly asked' {
            Mock Install-Module { }
            Mock Import-Module { }

            $null = Initialize-NotificationSupport -Approved @('BurntToast') 6>$null

            Should-Invoke Install-Module -Times 1 -Exactly -ParameterFilter { $Name -eq 'BurntToast' }
        }

        It 'installs for the current user only' {
            Mock Install-Module { }
            Mock Import-Module { }

            $null = Initialize-NotificationSupport -Approved @('BurntToast') 6>$null

            Should-Invoke Install-Module -ParameterFilter { $Scope -eq 'CurrentUser' }
        }

        # An unreachable gallery must not take the update run down with it.
        It 'carries on when the install fails' {
            Mock Install-Module { throw 'no gallery' }

            (Initialize-NotificationSupport -Approved @('BurntToast') -WarningAction SilentlyContinue 6>$null).Available |
                Should-BeFalse
        }
    }

    Context 'BurntToast present' {

        BeforeEach {
            Mock Test-InteractiveSession { $true }
            Mock Get-Module { [pscustomobject]@{ Name = 'BurntToast' } } -ParameterFilter { $Name -eq 'BurntToast' }
        }

        It 'reports notifications as available' {
            Mock Import-Module { }
            (Initialize-NotificationSupport).Available | Should-BeTrue
        }

        It 'carries on when the module will not load' {
            Mock Import-Module { throw 'corrupt module' }
            (Initialize-NotificationSupport -WarningAction SilentlyContinue).Available | Should-BeFalse
        }
    }
}

Describe 'Send-UpdateNotification' -Tag 'Unit','Notification' {

    BeforeEach {
        Mock New-BurntToastNotification { }
        Mock Test-BurntToastSupportsUrgent { $true }
        $script:NotificationsAvailable = $true
    }

    Context 'When notifications are unavailable' {

        It 'sends nothing at all' {
            $script:NotificationsAvailable = $false
            Send-UpdateNotification -Text 'x'

            Should-NotInvoke New-BurntToastNotification
        }

        It 'sends nothing urgent either' {
            $script:NotificationsAvailable = $false
            Send-UpdateNotification -Text 'Restart required' -Urgent

            Should-NotInvoke New-BurntToastNotification
        }

        # The flag is initialised to $false by the main body before any step
        # runs. If that were ever missed, an unset variable is still falsy, so
        # the failure mode is silence rather than a crash at the end of a long
        # run.
        It 'treats an uninitialised flag as unavailable' {
            Remove-Variable -Name NotificationsAvailable -Scope Script -ErrorAction SilentlyContinue
            Send-UpdateNotification -Text 'x'

            Should-NotInvoke New-BurntToastNotification
        }

        It 'does not throw when it cannot send' {
            $script:NotificationsAvailable = $false
            $warnings = @()
            Send-UpdateNotification -Text 'x' -WarningVariable warnings -WarningAction SilentlyContinue

            # Silence, not a warning: the caller was already told at startup.
            $warnings | Should-BeNull
        }
    }

    Context 'An ordinary notification' {

        It 'sends the toast' {
            Send-UpdateNotification -Text 'Updates finished'
            Should-Invoke New-BurntToastNotification -Times 1 -Exactly
        }

        It 'passes the text through' {
            Send-UpdateNotification -Text 'Updates finished', '3 updated'
            Should-Invoke New-BurntToastNotification -ParameterFilter { $Text -contains 'Updates finished' }
        }

        It 'is not marked urgent' {
            Send-UpdateNotification -Text 'Updates finished'
            Should-Invoke New-BurntToastNotification -ParameterFilter { -not $Urgent }
        }

        # Toasts sharing an identifier replace one another, so a weekly task does
        # not leave a stack of stale summaries in the Action Center.
        It 'groups repeat notifications under one identifier' {
            Send-UpdateNotification -Text 'x'
            Should-Invoke New-BurntToastNotification -ParameterFilter { $UniqueIdentifier -eq 'Update-Everything' }
        }
    }

    Context 'The restart notification' {

        It 'is marked urgent, so Focus Assist does not hide it' {
            Send-UpdateNotification -Text 'Restart required' -Urgent
            Should-Invoke New-BurntToastNotification -ParameterFilter { $Urgent }
        }

        It 'uses its own identifier so it does not replace the summary' {
            Send-UpdateNotification -Text 'Restart required' -Urgent -UniqueIdentifier 'Update-Everything-Reboot'
            Should-Invoke New-BurntToastNotification -ParameterFilter { $UniqueIdentifier -eq 'Update-Everything-Reboot' }
        }
    }

    Context 'An older BurntToast without -Urgent' {

        BeforeEach { Mock Test-BurntToastSupportsUrgent { $false } }

        # Passing an unknown parameter would fail the call outright, losing the
        # notification rather than merely its urgency.
        It 'still sends the notification' {
            Send-UpdateNotification -Text 'Restart required' -Urgent -WarningAction SilentlyContinue
            Should-Invoke New-BurntToastNotification -Times 1 -Exactly
        }

        It 'drops the urgent flag rather than failing' {
            Send-UpdateNotification -Text 'Restart required' -Urgent -WarningAction SilentlyContinue
            Should-Invoke New-BurntToastNotification -ParameterFilter { -not $Urgent }
        }
    }

    Context 'When the toast itself fails' {

        It 'warns instead of throwing' {
            Mock New-BurntToastNotification { throw 'shell refused the toast' }

            $warnings = @()
            Send-UpdateNotification -Text 'x' -WarningVariable warnings -WarningAction SilentlyContinue

            $warnings | Should-NotBeNull
        }
    }
}
