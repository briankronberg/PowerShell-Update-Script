#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '6.0' }

<#
    Behavioural tests for the functions inside Update-Everything.ps1.

    These dot-source the script, which the dot-source guard makes safe: loading
    it that way defines the functions and returns before anything is updated.
    The companion file Update-Everything.Tests.ps1 asserts statically that the
    guard is present, so this file cannot quietly start running a maintenance
    pass if someone removes it.

    Nothing here touches a real settings.json, a real registry key or the user's
    real log directory. File work goes to TestDrive, and the registry probes are
    mocked.
#>

BeforeAll {
    $script:ScriptPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'Update-Everything.ps1'
    . $script:ScriptPath
}

Describe 'Remove-JsonComment' -Tag 'Unit' {

    Context 'Comment stripping' {

        It 'removes a whole-line // comment' {
            Remove-JsonComment -Text "{`n  // a comment`n  `"a`": 1`n}" |
                Should-NotMatchString '// a comment'
        }

        It 'removes a trailing // comment but keeps the value' {
            $result = Remove-JsonComment -Text '{ "a": 1 // trailing'
            $result | Should-MatchString '"a": 1'
            $result | Should-NotMatchString 'trailing'
        }

        It 'removes a /* block */ comment' {
            Remove-JsonComment -Text '{ /* gone */ "a": 1 }' |
                Should-NotMatchString 'gone'
        }

        It 'removes a block comment spanning lines' {
            Remove-JsonComment -Text "{ /* one`ntwo */ `"a`": 1 }" |
                Should-NotMatchString 'two'
        }

        It 'leaves comment-free JSON unchanged' {
            $json = '{ "a": 1, "b": "two" }'
            Remove-JsonComment -Text $json | Should-Be $json
        }

        It 'accepts an empty string' {
            Remove-JsonComment -Text '' | Should-Be ''
        }
    }

    Context 'Values that merely look like comments' {

        # The whole reason the regex matches string literals first. A URL in a
        # profile's commandline or icon is the realistic case.
        It 'preserves // inside a string value' {
            $result = Remove-JsonComment -Text '{ "url": "https://example.com/x" }'
            $result | Should-MatchString ([regex]::Escape('https://example.com/x'))
        }

        It 'preserves /* inside a string value' {
            Remove-JsonComment -Text '{ "s": "a /* b */ c" }' |
                Should-MatchString ([regex]::Escape('a /* b */ c'))
        }

        It 'still strips a real comment that follows a URL value' {
            $result = Remove-JsonComment -Text '{ "url": "https://example.com" } // note'
            $result | Should-MatchString ([regex]::Escape('https://example.com'))
            $result | Should-NotMatchString 'note'
        }

        It 'handles an escaped quote inside a string' {
            Remove-JsonComment -Text '{ "s": "he said \"hi\" // not a comment" }' |
                Should-MatchString ([regex]::Escape('not a comment'))
        }
    }

    Context 'Round-tripping real JSONC' {

        It 'produces JSON that ConvertFrom-Json accepts' {
            $jsonc = @'
{
    // Windows Terminal writes comments like this
    "defaultProfile": "{guid-1}",
    /* and like this */
    "profiles": { "list": [ { "guid": "{guid-1}", "source": "Windows.Terminal.PowershellCore" } ] }
}
'@
            $parsed = Remove-JsonComment -Text $jsonc | ConvertFrom-Json
            $parsed.defaultProfile | Should-Be '{guid-1}'
        }
    }
}

Describe 'Get-UpdateLogDirectory' -Tag 'Unit' {

    It 'uses the first candidate that is not empty' {
        $target = Get-UpdateLogDirectory -Candidate @($null, '', $TestDrive)
        $target | Should-Be (Join-Path $TestDrive 'UpdateLogs')
    }

    It 'creates the directory when it does not exist' {
        $root = Join-Path $TestDrive 'fresh'
        $null = New-Item -ItemType Directory -Path $root
        $target = Get-UpdateLogDirectory -Candidate @($root)

        Test-Path -LiteralPath $target | Should-BeTrue
    }

    It 'reuses an existing directory rather than failing' {
        $root = Join-Path $TestDrive 'existing'
        $null = New-Item -ItemType Directory -Path (Join-Path $root 'UpdateLogs') -Force
        $marker = Join-Path $root 'UpdateLogs\keep.txt'
        Set-Content -LiteralPath $marker -Value 'keep'

        $null = Get-UpdateLogDirectory -Candidate @($root)

        # A destructive re-create would have removed the marker.
        Test-Path -LiteralPath $marker | Should-BeTrue
    }

    It 'falls back to the temp directory when the preferred one cannot be created' {
        # The fallback calls New-Item a second time with -ErrorAction
        # SilentlyContinue. Pester 6 no longer lets an unmatched call through to
        # the real command, so a default mock has to catch it.
        Mock New-Item { }
        Mock New-Item { throw 'access denied' } -ParameterFilter { $ErrorAction -eq 'Stop' }

        $target = Get-UpdateLogDirectory -Candidate @((Join-Path $TestDrive 'denied')) -WarningAction SilentlyContinue

        $target | Should-Be (Join-Path ([System.IO.Path]::GetTempPath()) 'UpdateLogs')
    }

    It 'warns when it has to fall back' {
        Mock New-Item { }
        Mock New-Item { throw 'access denied' } -ParameterFilter { $ErrorAction -eq 'Stop' }

        $warnings = @()
        $null = Get-UpdateLogDirectory -Candidate @((Join-Path $TestDrive 'denied2')) -WarningVariable warnings -WarningAction SilentlyContinue

        $warnings | Should-NotBeNull
    }
}

Describe 'Test-PendingReboot' -Tag 'Unit' {

    BeforeEach {
        # Default: nothing pending. Individual tests turn one probe positive.
        # v6 no longer falls through to the real command when no ParameterFilter
        # matches, so a catch-all mock has to exist alongside the specific ones.
        Mock Test-Path { $false }
        Mock Get-ItemProperty { throw [System.Management.Automation.ItemNotFoundException]::new('not found') }
    }

    It 'reports nothing pending on a clean machine' {
        $result = Test-PendingReboot
        $result.IsPending | Should-BeFalse
    }

    It 'returns no reasons on a clean machine' {
        (Test-PendingReboot).Reasons | Should-BeCollection -Count 0
    }

    It 'detects a Component Based Servicing reboot' {
        Mock Test-Path { $true } -ParameterFilter { $LiteralPath -like '*Component Based Servicing\RebootPending' }

        $result = Test-PendingReboot
        $result.IsPending | Should-BeTrue
        $result.Reasons | Should-ContainCollection 'Component Based Servicing'
    }

    It 'detects a Windows Update reboot' {
        Mock Test-Path { $true } -ParameterFilter { $LiteralPath -like '*WindowsUpdate\Auto Update\RebootRequired' }

        (Test-PendingReboot).Reasons | Should-ContainCollection 'Windows Update'
    }

    It 'detects pending file renames' {
        Mock Get-ItemProperty { [pscustomobject]@{ PendingFileRenameOperations = @('a', 'b') } } `
            -ParameterFilter { $Name -eq 'PendingFileRenameOperations' }

        $result = Test-PendingReboot
        $result.IsPending | Should-BeTrue
    }

    # The documented false-positive guard: plenty of healthy machines carry an
    # empty PendingFileRenameOperations value, and reporting those as pending
    # would tell every user to reboot after every run.
    It 'ignores an empty PendingFileRenameOperations value' {
        Mock Get-ItemProperty { [pscustomobject]@{ PendingFileRenameOperations = @('', $null) } } `
            -ParameterFilter { $Name -eq 'PendingFileRenameOperations' }

        (Test-PendingReboot).IsPending | Should-BeFalse
    }

    It 'detects a queued computer rename' {
        Mock Get-ItemProperty { [pscustomobject]@{ ComputerName = 'OLD-NAME' } } `
            -ParameterFilter { $LiteralPath -like '*ActiveComputerName' }
        Mock Get-ItemProperty { [pscustomobject]@{ ComputerName = 'NEW-NAME' } } `
            -ParameterFilter { $LiteralPath -like '*Control\ComputerName\ComputerName' }

        $result = Test-PendingReboot
        $result.IsPending | Should-BeTrue
        ($result.Reasons -join ' ') | Should-MatchString 'Computer rename pending'
    }

    It 'does not flag a machine whose active and target names agree' {
        Mock Get-ItemProperty { [pscustomobject]@{ ComputerName = 'SAME' } } `
            -ParameterFilter { $LiteralPath -like '*ComputerName*' }

        (Test-PendingReboot).IsPending | Should-BeFalse
    }

    It 'collects every reason when several are pending' {
        Mock Test-Path { $true } -ParameterFilter { $LiteralPath -like '*Component Based Servicing\RebootPending' }
        Mock Test-Path { $true } -ParameterFilter { $LiteralPath -like '*WindowsUpdate\Auto Update\RebootRequired' }

        (Test-PendingReboot).Reasons | Should-BeCollection -Count 2
    }
}

Describe 'Invoke-Step' -Tag 'Unit' {

    BeforeEach {
        # Invoke-Step writes into $script:logDir / $script:runStamp and appends to
        # $script:Results. Dot-sourcing puts the functions in this file's scope,
        # so these are the same variables the function reads.
        $script:logDir   = Join-Path $TestDrive ('logs-' + [guid]::NewGuid().ToString('N'))
        $null            = New-Item -ItemType Directory -Path $script:logDir -Force
        $script:runStamp = 'teststamp'
        $script:Results  = [System.Collections.Generic.List[object]]::new()
    }

    Context 'A step that succeeds' {

        It 'records the step as OK' {
            Invoke-Step -Name 'good' -Action { 'work' } 6>$null
            $script:Results[0].Status | Should-Be 'OK'
        }

        It 'writes a log file named after the step' {
            Invoke-Step -Name 'good' -Action { 'work' } 6>$null
            Test-Path (Join-Path $script:logDir 'good-teststamp.log') | Should-BeTrue
        }

        It 'sanitises spaces and punctuation out of the log file name' {
            Invoke-Step -Name 'Windows Terminal default = PowerShell 7' -Action { 'x' } 6>$null

            $script:Results[0].Log | Should-MatchString 'Windows-Terminal-default-PowerShell-7-teststamp\.log'
        }
    }

    Context 'A step that fails' {

        It 'records a thrown action as Failed' {
            Invoke-Step -Name 'bad' -Action { throw 'boom' } 3>$null 6>$null
            $script:Results[0].Status | Should-Be 'Failed'
        }

        # The whole point of the step runner: one bad channel must not stop the
        # rest of the run. If the throw escaped, the second step never records.
        It 'lets the following step still run' {
            Invoke-Step -Name 'bad'  -Action { throw 'boom' } 3>$null 6>$null
            Invoke-Step -Name 'next' -Action { 'fine' } 6>$null

            $script:Results | Should-BeCollection -Count 2
            $script:Results[1].Status | Should-Be 'OK'
        }

        It 'records the failure reason in the step log' {
            Invoke-Step -Name 'bad' -Action { throw 'boom' } 3>$null 6>$null

            Get-Content (Join-Path $script:logDir 'bad-teststamp.log') -Raw |
                Should-MatchString 'FAILED'
        }
    }

    Context 'A step whose tool is missing' {

        It 'skips when RequiresCommand cannot be resolved' {
            Invoke-Step -Name 'absent' -RequiresCommand 'definitely-not-a-real-command-xyz' -Action { 'x' } 6>$null
            $script:Results[0].Status | Should-Be 'Skipped'
        }

        It 'does not run the action of a skipped step' {
            $script:ran = $false
            Invoke-Step -Name 'absent' -RequiresCommand 'definitely-not-a-real-command-xyz' -Action { $script:ran = $true } 6>$null
            $script:ran | Should-BeFalse
        }
    }

    Context 'Native exit codes' {

        It 'fails a step whose action leaves a non-zero exit code' {
            Invoke-Step -Name 'exitbad' -Action { $global:LASTEXITCODE = 5 } 3>$null 6>$null
            $script:Results[0].Status | Should-Be 'Failed'
        }

        It 'accepts an exit code listed in AllowedExitCodes' {
            Invoke-Step -Name 'exitok' -AllowedExitCodes 5 -Action { $global:LASTEXITCODE = 5 } 6>$null
            $script:Results[0].Status | Should-Be 'OK'
        }

        # The v2 fix: a cmdlet-only step used to inherit a stale code from an
        # earlier native command and report a failure that never happened.
        It 'ignores a stale exit code left by an earlier step' {
            $global:LASTEXITCODE = 9
            Invoke-Step -Name 'clean' -Action { 'no native command here' } 6>$null

            $script:Results[0].Status | Should-Be 'OK'
        }
    }

    Context 'Result bookkeeping' {

        It 'appends one result per step, in order' {
            Invoke-Step -Name 'first'  -Action { 'a' } 6>$null
            Invoke-Step -Name 'second' -Action { 'b' } 6>$null

            $script:Results.Count | Should-Be 2
            $script:Results[1].Step | Should-Be 'second'
        }

        It 'records a duration' {
            Invoke-Step -Name 'timed' -Action { 'a' } 6>$null
            $script:Results[0].Seconds | Should-BeGreaterThanOrEqual 0
        }
    }
}

Describe 'Add-SkippedStep' -Tag 'Unit' {

    BeforeEach {
        $script:Results = [System.Collections.Generic.List[object]]::new()
    }

    It 'records the step as Skipped' {
        Add-SkippedStep -Name 'off' 6>$null
        $script:Results[0].Status | Should-Be 'Skipped'
    }

    It 'keeps the step name' {
        Add-SkippedStep -Name 'off' 6>$null
        $script:Results[0].Step | Should-Be 'off'
    }
}

Describe 'Write-StepLog' -Tag 'Unit' {

    It 'timestamps each line' {
        $log = Join-Path $TestDrive 'step.log'
        Write-StepLog -Path $log -Message 'hello'

        Get-Content $log -Raw | Should-MatchString '^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2} \| hello'
    }

    It 'appends rather than overwriting' {
        $log = Join-Path $TestDrive 'append.log'
        Write-StepLog -Path $log -Message 'one'
        Write-StepLog -Path $log -Message 'two'

        (Get-Content $log) | Should-BeCollection -Count 2
    }

    # Logging must never be what kills a maintenance run. An escaping exception
    # would fail this test outright, so reaching the assertion proves it degraded.
    It 'warns instead of throwing when the path is unwritable' {
        $bad = Join-Path $TestDrive 'no-such-dir\nested\step.log'

        $warnings = @()
        Write-StepLog -Path $bad -Message 'x' -WarningVariable warnings -WarningAction SilentlyContinue

        $warnings | Should-NotBeNull
    }
}

Describe 'Test-UacEnabled' -Tag 'Unit','Security' {

    It 'reports enabled when EnableLUA is 1' {
        Mock Get-ItemProperty { [pscustomobject]@{ EnableLUA = 1 } }
        Test-UacEnabled | Should-BeTrue
    }

    It 'reports disabled when EnableLUA is 0' {
        Mock Get-ItemProperty { [pscustomobject]@{ EnableLUA = 0 } }
        Test-UacEnabled | Should-BeFalse
    }

    # Guessing "off" would refuse to run on a machine that is merely locked down
    # enough to hide the key, so the safe default is the Windows default.
    It 'assumes enabled when the policy key cannot be read' {
        Mock Get-ItemProperty { throw 'access denied' }
        Test-UacEnabled | Should-BeTrue
    }
}

Describe 'Test-ElevationCapability' -Tag 'Unit','Security' {

    Context 'Already elevated' {

        BeforeEach { Mock Test-IsAdministrator { $true } }

        It 'reports the session as elevated' {
            (Test-ElevationCapability).IsElevated | Should-BeTrue
        }

        It 'does not probe group membership it does not need' {
            Mock Test-AdministratorGroupMember { $false }
            $null = Test-ElevationCapability
            Should-NotInvoke Test-AdministratorGroupMember
        }
    }

    Context 'A standard user who cannot elevate at all' {

        BeforeEach {
            Mock Test-IsAdministrator { $false }
            Mock Test-AdministratorGroupMember { $false }
        }

        It 'refuses rather than raising a prompt that cannot succeed' {
            (Test-ElevationCapability).CanElevate | Should-BeFalse
        }

        It 'explains that the account is not an administrator' {
            (Test-ElevationCapability).Reason | Should-MatchString 'not a member of the local Administrators group'
        }

        It 'points at -SkipElevation as the way forward' {
            (Test-ElevationCapability).Reason | Should-MatchString 'SkipElevation'
        }
    }

    Context 'An administrator on a machine with UAC switched off' {

        BeforeEach {
            Mock Test-IsAdministrator { $false }
            Mock Test-AdministratorGroupMember { $true }
            Mock Test-UacEnabled { $false }
        }

        It 'refuses, because no consent prompt will ever appear' {
            (Test-ElevationCapability).CanElevate | Should-BeFalse
        }

        It 'names UAC as the reason' {
            (Test-ElevationCapability).Reason | Should-MatchString 'UAC'
        }
    }

    Context 'A normal split-token administrator' {

        BeforeEach {
            Mock Test-IsAdministrator { $false }
            Mock Test-AdministratorGroupMember { $true }
            Mock Test-UacEnabled { $true }
        }

        It 'allows elevation to be attempted' {
            (Test-ElevationCapability).CanElevate | Should-BeTrue
        }

        It 'does not claim the session is already elevated' {
            (Test-ElevationCapability).IsElevated | Should-BeFalse
        }
    }

    # This is the regression that a real-machine check caught. Reading the
    # Administrators SID out of the current token reports a genuine admin as a
    # standard user, because a filtered token drops that SID. Treating an
    # unknown answer as "no" would refuse to run for the very people the script
    # is written for.
    Context 'Group membership that cannot be determined' {

        BeforeEach {
            Mock Test-IsAdministrator { $false }
            Mock Test-AdministratorGroupMember { $null }
            Mock Test-UacEnabled { $true }
        }

        It 'attempts elevation rather than refusing' {
            (Test-ElevationCapability).CanElevate | Should-BeTrue
        }
    }
}

Describe 'Test-AdministratorGroupMember' -Tag 'Unit','Security' {

    BeforeAll {
        $script:MySid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    }

    It 'reports true when the current user is a direct member' {
        Mock Get-LocalGroupMember {
            @([pscustomobject]@{
                Name = 'someone'; ObjectClass = 'User'
                SID = [pscustomobject]@{ Value = $script:MySid }
            })
        }

        Test-AdministratorGroupMember | Should-BeTrue
    }

    It 'reports false when the group holds only other users' {
        Mock Get-LocalGroupMember {
            @([pscustomobject]@{
                Name = 'someone-else'; ObjectClass = 'User'
                SID = [pscustomobject]@{ Value = 'S-1-5-21-1-2-3-999' }
            })
        }

        Test-AdministratorGroupMember | Should-BeFalse
    }

    # A domain group nested in local Administrators can still grant membership,
    # and resolving that needs a domain round trip.
    It 'reports unknown when a nested group could still grant membership' {
        Mock Get-LocalGroupMember {
            @([pscustomobject]@{
                Name = 'CONTOSO\Domain Admins'; ObjectClass = 'Group'
                SID = [pscustomobject]@{ Value = 'S-1-5-21-1-2-3-512' }
            })
        }

        Test-AdministratorGroupMember | Should-BeNull
    }

    It 'reports unknown when the group cannot be read at all' {
        Mock Get-LocalGroupMember { throw 'access denied' }

        Test-AdministratorGroupMember | Should-BeNull
    }

    # Localised Windows names the group differently; the SID never changes.
    It 'looks the group up by SID, not by name' {
        Mock Get-LocalGroupMember { @() }

        $null = Test-AdministratorGroupMember

        Should-Invoke Get-LocalGroupMember -Times 1 -Exactly -ParameterFilter { $SID -eq 'S-1-5-32-544' }
    }
}

Describe 'Invoke-Step -RequiresAdmin' -Tag 'Unit','Security' {

    BeforeEach {
        $script:logDir   = Join-Path $TestDrive ('admin-' + [guid]::NewGuid().ToString('N'))
        $null            = New-Item -ItemType Directory -Path $script:logDir -Force
        $script:runStamp = 'teststamp'
        $script:Results  = [System.Collections.Generic.List[object]]::new()
    }

    Context 'Running without administrator rights' {

        BeforeEach { $script:isAdmin = $false }

        It 'skips the step instead of letting it fail on permissions' {
            Invoke-Step -Name 'needs-admin' -RequiresAdmin -Action { 'x' } 6>$null
            $script:Results[0].Status | Should-Be 'Skipped'
        }

        It 'never runs the action' {
            $script:ranAdminAction = $false
            Invoke-Step -Name 'needs-admin' -RequiresAdmin -Action { $script:ranAdminAction = $true } 6>$null

            $script:ranAdminAction | Should-BeFalse
        }

        It 'still runs steps that do not require admin' {
            Invoke-Step -Name 'ordinary' -Action { 'x' } 6>$null
            $script:Results[0].Status | Should-Be 'OK'
        }
    }

    Context 'Running elevated' {

        BeforeEach { $script:isAdmin = $true }

        It 'runs a step that requires admin' {
            Invoke-Step -Name 'needs-admin' -RequiresAdmin -Action { 'x' } 6>$null
            $script:Results[0].Status | Should-Be 'OK'
        }
    }
}
