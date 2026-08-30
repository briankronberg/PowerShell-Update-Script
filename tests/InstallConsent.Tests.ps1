#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '6.0' }

<#
    Tests for the first-time-install consent gate.

    This is an update script, not an installer. Updating something already
    present is the job; installing something that was never there is a different
    act and needs permission. The rules under test:

      - -AllowInstall approves ahead of time, by component or with All.
      - Without it, an interactive run asks, and the answer defaults to No.
      - A non-interactive run (a scheduled task) declines, because there is
        nobody to ask -- it must never install software unattended.
      - A declined install skips its step. It is not a failure, and must not
        land in the exit code.

    Nothing here installs anything: Request-InstallConsent is mocked, so no
    prompt is ever shown and no package is ever fetched.
#>

BeforeAll {
    # Load the module's functions individually rather than importing the module,
    # so tests can reach the private ones directly. $ModuleRoot is what
    # Invoke-SelfElevation and the task builder hand to an elevated child.
    $script:ModuleRoot = Join-Path (Split-Path $PSScriptRoot -Parent) 'src'
    Get-ChildItem "$script:ModuleRoot\Private\*.ps1", "$script:ModuleRoot\Public\*.ps1" |
        ForEach-Object { . $_.FullName }
}

Describe 'Approve-Install' -Tag 'Unit','Consent' {

    BeforeEach {
        $script:InstallDecision = @{}
        # Nothing may reach a real prompt.
        Mock Request-InstallConsent { throw 'a test asked the operator a real question' }
    }

    Context 'Approved in advance' {

        It 'allows a component named in -AllowInstall' {
            Approve-Install -Component 'PSWindowsUpdate' -Description 'x' -Approved @('PSWindowsUpdate') |
                Should-BeTrue
        }

        It 'allows anything when All is given' {
            Approve-Install -Component 'PowerShell7' -Description 'x' -Approved @('All') | Should-BeTrue
        }

        It 'does not ask when approval is already given' {
            $null = Approve-Install -Component 'BurntToast' -Description 'x' -Approved @('All')
            Should-NotInvoke Request-InstallConsent
        }

        It 'approves only the component named, not its neighbours' {
            Mock Test-CanPrompt { $false }

            Approve-Install -Component 'BurntToast' -Description 'x' -Approved @('PowerShell7') -WarningAction SilentlyContinue |
                Should-BeFalse
        }
    }

    Context 'A non-interactive run' {

        BeforeEach { Mock Test-CanPrompt { $false } }

        # The case that matters most: a scheduled task must never install
        # software on a machine nobody is watching.
        It 'declines rather than installing unattended' {
            Approve-Install -Component 'PSWindowsUpdate' -Description 'x' -WarningAction SilentlyContinue |
                Should-BeFalse
        }

        It 'never tries to prompt' {
            $null = Approve-Install -Component 'PSWindowsUpdate' -Description 'x' -WarningAction SilentlyContinue
            Should-NotInvoke Request-InstallConsent
        }

        It 'says how to approve it next time' {
            $warnings = @()
            $null = Approve-Install -Component 'PSWindowsUpdate' -Description 'x' `
                -WarningVariable warnings -WarningAction SilentlyContinue

            ($warnings -join ' ') | Should-MatchString '-AllowInstall PSWindowsUpdate'
        }
    }

    Context 'An interactive run' {

        BeforeEach { Mock Test-CanPrompt { $true } }

        It 'installs when the operator agrees' {
            Mock Request-InstallConsent { $true }
            Approve-Install -Component 'BurntToast' -Description 'x' | Should-BeTrue
        }

        It 'does not install when the operator declines' {
            Mock Request-InstallConsent { $false }
            Approve-Install -Component 'BurntToast' -Description 'x' -WarningAction SilentlyContinue |
                Should-BeFalse
        }

        It 'passes the component name to the prompt' {
            Mock Request-InstallConsent { $true }
            $null = Approve-Install -Component 'NuGetProvider' -Description 'x'

            Should-Invoke Request-InstallConsent -ParameterFilter { $Component -eq 'NuGetProvider' }
        }

        # Several steps can need the same component. Being asked about
        # PSWindowsUpdate three times in one run would be its own kind of bad.
        It 'asks only once per component' {
            Mock Request-InstallConsent { $true }

            $null = Approve-Install -Component 'BurntToast' -Description 'x'
            $null = Approve-Install -Component 'BurntToast' -Description 'x'
            $null = Approve-Install -Component 'BurntToast' -Description 'x'

            Should-Invoke Request-InstallConsent -Times 1 -Exactly
        }

        It 'remembers a refusal too, rather than asking again' {
            Mock Request-InstallConsent { $false }

            $null = Approve-Install -Component 'BurntToast' -Description 'x' -WarningAction SilentlyContinue
            $null = Approve-Install -Component 'BurntToast' -Description 'x' -WarningAction SilentlyContinue

            Should-Invoke Request-InstallConsent -Times 1 -Exactly
        }

        It 'keeps decisions separate per component' {
            Mock Request-InstallConsent { $true } -ParameterFilter { $Component -eq 'BurntToast' }
            Mock Request-InstallConsent { $false } -ParameterFilter { $Component -eq 'PowerShell7' }

            Approve-Install -Component 'BurntToast' -Description 'x' | Should-BeTrue
            Approve-Install -Component 'PowerShell7' -Description 'x' -WarningAction SilentlyContinue | Should-BeFalse
        }
    }
}

Describe 'Stop-StepAsSkipped' -Tag 'Unit','Consent' {

    It 'throws a recognisable sentinel' {
        { Stop-StepAsSkipped -Reason 'not approved' } | Should-Throw -ExceptionMessage '*STEP-SKIPPED*'
    }

    It 'carries the reason' {
        { Stop-StepAsSkipped -Reason 'installing PowerShell 7 was not approved' } |
            Should-Throw -ExceptionMessage '*installing PowerShell 7 was not approved*'
    }
}

Describe 'A step that declines an install' -Tag 'Unit','Consent' {

    BeforeEach {
        $script:logDir   = Join-Path $TestDrive ('consent-' + [guid]::NewGuid().ToString('N'))
        $null            = New-Item -ItemType Directory -Path $script:logDir -Force
        $script:runStamp = 'teststamp'
        $script:Results  = [System.Collections.Generic.List[object]]::new()
        $script:isAdmin  = $true
    }

    # A refusal is a decision, not a fault. Recording it as Failed would put it
    # in the exit code and make a deliberate choice look like a broken run.
    It 'records the step as Skipped, not Failed' {
        Invoke-Step -Name 'needs-install' -Action { Stop-StepAsSkipped -Reason 'not approved' } 6>$null

        $script:Results[0].Status | Should-Be 'Skipped'
    }

    It 'keeps the reason in the step log' {
        Invoke-Step -Name 'needs-install' -Action { Stop-StepAsSkipped -Reason 'not approved' } 6>$null

        Get-Content (Join-Path $script:logDir 'needs-install-teststamp.log') -Raw |
            Should-MatchString 'SKIPPED \| not approved'
    }

    It 'still fails a step that throws for any other reason' {
        Invoke-Step -Name 'broken' -Action { throw 'genuinely broken' } 3>$null 6>$null

        $script:Results[0].Status | Should-Be 'Failed'
    }

    It 'lets the run continue' {
        Invoke-Step -Name 'declined' -Action { Stop-StepAsSkipped -Reason 'not approved' } 6>$null
        Invoke-Step -Name 'next'     -Action { 'fine' } 6>$null

        $script:Results[1].Status | Should-Be 'OK'
    }
}

Describe 'Every install site is gated' -Tag 'Static','Consent' {

    BeforeAll {
        $script:Source = (Get-ChildItem (Join-Path (Split-Path $PSScriptRoot -Parent) 'src\Public'), (Join-Path (Split-Path $PSScriptRoot -Parent) 'src\Private') -Filter *.ps1 | Get-Content -Raw) -join "`n`n"
        $script:Ast = [System.Management.Automation.Language.Parser]::ParseInput(
            $script:Source, [ref] $null, [ref] $null)

        # Commands that bring something new onto the machine, as opposed to
        # updating something already installed.
        $script:InstallingCommands = @('Install-Module', 'Install-PackageProvider', 'Install-Script', 'Install-PSResource')
    }

    # The gate is only worth anything if nothing routes around it. A new install
    # site added without an Approve-Install nearby should fail here.
    It 'guards every install command with an approval check' {
        $ungated = foreach ($call in $script:Ast.FindAll({
                    param($node)
                    $node -is [System.Management.Automation.Language.CommandAst]
                }, $true)) {

            $name = $call.GetCommandName()
            if ($name -notin $script:InstallingCommands) { continue }

            # Look back a little from the call for the approval that admits it.
            $start = [Math]::Max(0, $call.Extent.StartOffset - 1200)
            $window = $script:Source.Substring($start, $call.Extent.StartOffset - $start)
            if ($window -notmatch 'Approve-Install') {
                "line $($call.Extent.StartLineNumber): $name"
            }
        }

        $ungated | Should-BeNull -Because "these install without asking:`n$($ungated -join "`n")"
    }

    It 'guards the winget install of PowerShell 7' {
        # The AST, not a text search. winget is a native command but still parses
        # as a CommandAst, and matching text instead would also hit the string
        # literal that prints the command as advice -- which installs nothing.
        $installs = @($script:Ast.FindAll({
                    param($node)
                    $node -is [System.Management.Automation.Language.CommandAst] -and
                    $node.GetCommandName() -eq 'winget' -and
                    @($node.CommandElements | ForEach-Object { $_.Extent.Text }) -contains 'install'
                }, $true))

        $installs | Should-NotBeNull -Because 'the PowerShell 7 install should still exist'

        $lines = $script:Source -split "`r?`n"
        $ungated = foreach ($call in $installs) {
            $line   = $call.Extent.StartLineNumber
            $window = ($lines[[Math]::Max(0, $line - 13)..($line - 1)]) -join "`n"
            if ($window -notmatch 'Approve-Install') { "line ${line}: $($call.Extent.Text)" }
        }

        $ungated | Should-BeNull -Because "these install without asking:`n$($ungated -join "`n")"
    }
}
