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
    # Load the module's functions individually rather than importing the module,
    # so tests can reach the private ones directly. $ModuleRoot is what
    # Invoke-SelfElevation and the task builder hand to an elevated child.
    $script:ModuleRoot = Join-Path (Split-Path $PSScriptRoot -Parent) 'src'
    Get-ChildItem "$script:ModuleRoot\Private\*.ps1", "$script:ModuleRoot\Public\*.ps1" |
        ForEach-Object { . $_.FullName }
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
        # Returns nothing rather than throwing: the probe now reads the key with
        # -ErrorAction SilentlyContinue and looks for the value itself, and a
        # mock that throws would ignore that and propagate.
        Mock Get-ItemProperty { }
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
            -ParameterFilter { $LiteralPath -like '*Session Manager' }

        $result = Test-PendingReboot
        $result.IsPending | Should-BeTrue
    }

    # The documented false-positive guard: plenty of healthy machines carry an
    # empty PendingFileRenameOperations value, and reporting those as pending
    # would tell every user to reboot after every run.
    It 'ignores an empty PendingFileRenameOperations value' {
        Mock Get-ItemProperty { [pscustomobject]@{ PendingFileRenameOperations = @('', $null) } } `
            -ParameterFilter { $LiteralPath -like '*Session Manager' }

        (Test-PendingReboot).IsPending | Should-BeFalse
    }

    # The entries are [source, destination] pairs. An empty destination is a
    # scheduled deletion, not a rename, and installers queue those for their own
    # temp files constantly. This exact value was on a real machine and made
    # every run print "[!] A reboot is pending" while Component Based Servicing
    # and Windows Update both reported nothing.
    It 'does not call a scheduled deletion a pending reboot' {
        Mock Get-ItemProperty {
            [pscustomobject]@{ PendingFileRenameOperations = @(
                '*1\??\C:\Users\someone\AppData\Local\Temp\DEL396A.tmp', '') }
        } -ParameterFilter { $LiteralPath -like '*Session Manager' }

        (Test-PendingReboot).IsPending | Should-BeFalse
    }

    It 'gives no reboot reason for a scheduled deletion' {
        Mock Get-ItemProperty {
            [pscustomobject]@{ PendingFileRenameOperations = @('\??\C:\Temp\DEL1.tmp', '') }
        } -ParameterFilter { $LiteralPath -like '*Session Manager' }

        (Test-PendingReboot).Reasons | Should-BeCollection -Count 0
    }

    # A rename means Windows is holding a replacement for a file in use, and the
    # restart is what completes it. That still has to be reported.
    It 'still reports a real rename alongside deletions' {
        Mock Get-ItemProperty {
            [pscustomobject]@{ PendingFileRenameOperations = @(
                '\??\C:\Temp\DEL1.tmp', '',
                '\??\C:\Windows\System32\thing.dll', '!\??\C:\Windows\System32\thing.dll') }
        } -ParameterFilter { $LiteralPath -like '*Session Manager' }

        (Test-PendingReboot).IsPending | Should-BeTrue
    }

    It 'counts only the renames, not the deletions beside them' {
        Mock Get-ItemProperty {
            [pscustomobject]@{ PendingFileRenameOperations = @(
                '\??\C:\Temp\DEL1.tmp', '',
                '\??\C:\Temp\DEL2.tmp', '',
                '\??\C:\Windows\System32\thing.dll', '!\??\C:\Windows\System32\thing.dll') }
        } -ParameterFilter { $LiteralPath -like '*Session Manager' }

        (Test-PendingReboot).Reasons | Should-ContainCollection 'Pending file renames (1): C:\Windows\System32\thing.dll'
    }

    # "Pending file renames (1)" on its own sent someone through the event log,
    # the servicing keys and the Office update state to work out what a restart
    # was for, and by then the answer was gone: the queue is consumed at boot
    # and nothing else records it. The path is the answer.
    It 'names the file a restart is waiting on' {
        Mock Get-ItemProperty {
            [pscustomobject]@{ PendingFileRenameOperations = @(
                '\??\C:\Windows\System32\drivers\thing.sys', '!\??\C:\Windows\System32\drivers\thing.sys') }
        } -ParameterFilter { $LiteralPath -like '*Session Manager' }

        (Test-PendingReboot).Reasons |
            Should-ContainCollection 'Pending file renames (1): C:\Windows\System32\drivers\thing.sys'
    }

    # The sources carry NT object-manager syntax and MoveFileEx markers. Left in,
    # the reason reads as machine noise rather than a path.
    It 'strips the <_> prefix from the reported path' -ForEach @('\??\', '*1\??\', '!\??\') {
        $prefix = $_
        Mock Get-ItemProperty {
            [pscustomobject]@{ PendingFileRenameOperations = @(
                ($prefix + 'C:\dir\file.dll'), '!\??\C:\dir\file.dll') }
        } -ParameterFilter { $LiteralPath -like '*Session Manager' }

        (Test-PendingReboot).Reasons | Should-ContainCollection 'Pending file renames (1): C:\dir\file.dll'
    }

    # The summary prints a line per reason and the toast joins the first two, so
    # a machine mid-servicing must not turn either into a wall of text.
    It 'lists at most three paths' {
        Mock Get-ItemProperty {
            [pscustomobject]@{ PendingFileRenameOperations = @(
                '\??\C:\a.dll', '!\??\C:\a.dll',
                '\??\C:\b.dll', '!\??\C:\b.dll',
                '\??\C:\c.dll', '!\??\C:\c.dll',
                '\??\C:\d.dll', '!\??\C:\d.dll',
                '\??\C:\e.dll', '!\??\C:\e.dll') }
        } -ParameterFilter { $LiteralPath -like '*Session Manager' }

        (Test-PendingReboot).Reasons |
            Should-ContainCollection 'Pending file renames (5): C:\a.dll; C:\b.dll; C:\c.dll; and 2 more'
    }

    # The count is the total, not the number of paths shown. Asserting only
    # "renames (4)" would pass against the version that reported a bare count
    # and no paths at all, so this pins the whole reason.
    It 'counts every rename even though it shows three' {
        Mock Get-ItemProperty {
            [pscustomobject]@{ PendingFileRenameOperations = @(
                '\??\C:\a.dll', '!\??\C:\a.dll',
                '\??\C:\b.dll', '!\??\C:\b.dll',
                '\??\C:\c.dll', '!\??\C:\c.dll',
                '\??\C:\d.dll', '!\??\C:\d.dll') }
        } -ParameterFilter { $LiteralPath -like '*Session Manager' }

        (Test-PendingReboot).Reasons |
            Should-ContainCollection 'Pending file renames (4): C:\a.dll; C:\b.dll; C:\c.dll; and 1 more'
    }

    # A path long enough to wrap the summary is trimmed from the left, because
    # the file name is the end and that is the part that identifies it.
    It 'trims a long path from the left, keeping the file name' {
        $long = 'C:\Program Files\Some Vendor\A Very Long Product Name Indeed\subfolder\deeper\thing.dll'
        Mock Get-ItemProperty {
            [pscustomobject]@{ PendingFileRenameOperations = @(('\??\' + $long), '!\??\x') }
        } -ParameterFilter { $LiteralPath -like '*Session Manager' }

        (Test-PendingReboot).Reasons | Should-MatchString 'thing\.dll$'
    }

    # Measuring the trimmed length is not enough on its own: with no path in the
    # reason at all, the measurement lands on "Pending file renames (1)" and
    # passes. The ellipsis is what proves a path was there and was trimmed.
    It 'marks a trimmed path with a leading ellipsis' {
        $long = 'C:\Program Files\Some Vendor\A Very Long Product Name Indeed\subfolder\deeper\thing.dll'
        Mock Get-ItemProperty {
            [pscustomobject]@{ PendingFileRenameOperations = @(('\??\' + $long), '!\??\x') }
        } -ParameterFilter { $LiteralPath -like '*Session Manager' }

        (Test-PendingReboot).Reasons | Should-MatchString 'renames \(1\): \.\.\.'
    }

    # A trailing source with no partner is malformed. Inventing a rename out of
    # it would resurrect the false positive on exactly the machines whose
    # registry is already untidy.
    It 'treats an unpaired trailing entry as a deletion' {
        Mock Get-ItemProperty {
            [pscustomobject]@{ PendingFileRenameOperations = @('\??\C:\Temp\DEL1.tmp') }
        } -ParameterFilter { $LiteralPath -like '*Session Manager' }

        (Test-PendingReboot).IsPending | Should-BeFalse
    }

    # Asking for a value that is absent, with -ErrorAction Stop, throws -- and
    # Start-Transcript records the throw as "TerminatingError(Get-ItemProperty)"
    # in the run log even though it is caught. On a healthy machine that reads
    # like a fault. Read the key, then look for the value.
    It 'does not ask the registry for a value that may not exist' {
        $source = Get-Content (Join-Path (Split-Path $PSScriptRoot -Parent) 'src\Public\Test-PendingReboot.ps1') -Raw
        $probe = [regex]::Match($source, '(?s)function Test-PendingReboot.*?
\}').Value

        $probe | Should-NotMatchString '-Name PendingFileRenameOperations'
    }

    # A key that exists but carries no PendingFileRenameOperations value is the
    # normal case, and must not be read as a pending reboot.
    It 'ignores a Session Manager key without the value at all' {
        Mock Get-ItemProperty { [pscustomobject]@{ SomethingElse = 1 } } `
            -ParameterFilter { $LiteralPath -like '*Session Manager' }

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

    It 'writes -Raw text through without a timestamp' {
        $log = Join-Path $TestDrive 'raw.log'
        Write-StepLog -Path $log -Raw '    Name      Id'

        Get-Content $log -Raw | Should-MatchString '^ {4}Name {6}Id'
    }

    It 'accepts an empty -Raw line, which output is full of' {
        $log = Join-Path $TestDrive 'rawempty.log'
        Write-StepLog -Path $log -Raw ''
        Write-StepLog -Path $log -Raw 'after'

        (Get-Content $log) | Should-BeCollection -Count 2
    }
}

Describe 'Step logs are written in one encoding' -Tag 'Unit' {

    # The bug: Tee-Object -FilePath writes UTF-16LE on Windows PowerShell and has
    # no -Encoding there, while Write-StepLog's Add-Content wrote ANSI. Both hit
    # the same file, so every captured line arrived as interleaved nulls --
    # "P S G a l l e r y   ( P o w e r S h e l l G e t   v 2 )". A NUL byte is
    # the tell, and it is what this asserts on.

    BeforeEach {
        $script:logDir   = Join-Path $TestDrive ('enc-' + [guid]::NewGuid().ToString('N'))
        $null            = New-Item -ItemType Directory -Path $script:logDir -Force
        $script:runStamp = 'encstamp'
        $script:Results  = [System.Collections.Generic.List[object]]::new()
    }

    It 'keeps the captured text readable end to end' {
        Invoke-Step -Name 'enc' -Action { 'PSGallery set to Trusted.' } 6>$null

        Get-Content (Join-Path $script:logDir 'enc-encstamp.log') -Raw |
            Should-MatchString 'PSGallery set to Trusted\.'
    }

    # Objects reach a step log as the Format* records that render a table, not as
    # text. Writing them one at a time would log nothing useful.
    It 'renders a table rather than its format records' {
        Invoke-Step -Name 'enc' -Action {
            [pscustomobject]@{ Alpha = 1; Beta = 'two' } | Format-Table -AutoSize
        } 6>$null

        $text = Get-Content (Join-Path $script:logDir 'enc-encstamp.log') -Raw
        $text | Should-MatchString 'Alpha Beta'
        $text | Should-MatchString '1 two'
    }

    # The status lines and the captured output are written by the same function
    # now, so the two halves of the file have to agree.
    It 'writes the status lines in the same encoding as the output' {
        Invoke-Step -Name 'enc' -Action { 'work' } 6>$null

        $text = Get-Content (Join-Path $script:logDir 'enc-encstamp.log') -Raw
        $text | Should-MatchString 'STARTING enc'
        $text | Should-MatchString 'COMPLETED \| Duration:'
    }

    # This is the one that would have caught the bug, and it only can from 5.1.
    # Tee-Object -FilePath defaults to UTF-16LE there and takes no -Encoding to
    # say otherwise; on 7 it writes UTF-8 and the same code looks fine. The suite
    # runs on 7, so without shelling out nothing here would ever notice.
    It 'leaves no NUL bytes in a step log written by Windows PowerShell' -Skip:(-not (Get-Command powershell.exe -ErrorAction SilentlyContinue)) {
        $dir = Join-Path ([System.IO.Path]::GetTempPath()) ('ue-enc-' + [guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $dir -Force

        try {
            $child = @"
Get-ChildItem '$script:ModuleRoot\Private\*.ps1' | ForEach-Object { . `$_.FullName }
`$script:logDir   = '$dir'
`$script:runStamp = 'enc'
`$script:Results  = [System.Collections.Generic.List[object]]::new()
Invoke-Step -Name 'step' -Action { 'PSGallery set to Trusted.' } 6>`$null | Out-Null
`$bytes = [System.IO.File]::ReadAllBytes((Join-Path '$dir' 'step-enc.log'))
'NULS=' + @(`$bytes | Where-Object { `$_ -eq 0 }).Count
"@
            $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -Command $child

            ($output -join ' ') | Should-MatchString 'NULS=0'
        } finally {
            Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'Invoke-Step does not use the writer that caused the encoding split' -Tag 'Static' {

    # A behavioural guard cannot see this from PowerShell 7, where Tee-Object
    # writes UTF-8 and the bug is invisible. Naming the construct is what keeps
    # it from coming back on the edition where it does damage.
    # The AST, not a text search: the comment explaining why Tee-Object is gone
    # names it, and a regex over the source cannot tell a comment from a call.
    It 'never writes the step log with Tee-Object' {
        $path = Join-Path (Split-Path $PSScriptRoot -Parent) 'src\Private\Invoke-Step.ps1'
        $ast  = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref] $null, [ref] $null)

        $calls = $ast.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.CommandAst] -and
                $node.GetCommandName() -eq 'Tee-Object'
            }, $true)

        $calls | Should-BeNull -Because 'Tee-Object writes UTF-16LE on 5.1 and takes no -Encoding there'
    }
}

Describe 'Helpers called from inside a step do not use Write-Host' -Tag 'Static' {

    # Windows PowerShell routes Write-Host through the information stream. Inside
    # an Invoke-Step action, *>&1 merges that into the pipeline, so the line was
    # written to the console once by Write-Host and rendered again by
    # Out-Default. The transcript recorded both, one wrapped to console width and
    # one not:
    #
    #   Windows Terminal settings:
    #   C:\Users\...\LocalState\settings.json
    #   Windows Terminal settings: C:\Users\...\LocalState\settings.json
    #
    # Update-Everything's own summary is not inside a step, so Write-Host is
    # still correct there and this only covers the helpers a step calls.

    It 'Set-PwshAsWindowsTerminalDefault writes to the pipeline, not the host' {
        $path = Join-Path (Split-Path $PSScriptRoot -Parent) 'src\Private\Set-PwshAsWindowsTerminalDefault.ps1'
        $ast  = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref] $null, [ref] $null)

        $calls = $ast.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.CommandAst] -and
                $node.GetCommandName() -eq 'Write-Host'
            }, $true)

        $calls | Should-BeNull -Because 'inside a step, Write-Host is logged twice on Windows PowerShell'
    }
}

Describe 'Test-ProgressRepaint' -Tag 'Unit' {

    # winget repaints its progress bar with carriage returns, and PowerShell
    # splits captured native output on those, so one download arrives as a
    # column of spinner ticks and percentages -- on the console and in the log.
    # Nothing upstream prevents it: --disable-interactivity governs prompts.

    It 'drops the <_> spinner tick' -ForEach @('-', '\', '|', '/') {
        $tick = $_
        Test-ProgressRepaint -Line "  $tick" | Should-BeTrue
    }

    It 'drops a bare percentage' {
        Test-ProgressRepaint -Line '   86%' | Should-BeTrue
    }

    It 'drops a block bar carrying a percentage' {
        $bar = [string]([char]0x2588) * 12
        Test-ProgressRepaint -Line "$bar  48%" | Should-BeTrue
    }

    It 'drops a block bar with no label' {
        Test-ProgressRepaint -Line ([string]([char]0x2588) * 20) | Should-BeTrue
    }

    It 'keeps a line of real output' {
        Test-ProgressRepaint -Line 'Successfully installed' | Should-BeFalse
    }

    It 'keeps a line that merely mentions a percentage' {
        Test-ProgressRepaint -Line 'Disk is 86% full' | Should-BeFalse
    }

    # winget underlines its upgrade table with runs of hyphens. Reading that as
    # a spinner would eat the header of the one table people actually read.
    It 'keeps a table underline made of hyphens' {
        Test-ProgressRepaint -Line '------- ------ -------- ---------- -------' | Should-BeFalse
    }

    It 'keeps a rule made of equals signs' {
        Test-ProgressRepaint -Line '================' | Should-BeFalse
    }

    # Blank lines are structure, not repaint noise, and the caller already
    # collapses nothing -- so removing them here would reflow real output.
    It 'keeps a blank line' {
        Test-ProgressRepaint -Line '' | Should-BeFalse
    }

    It 'accepts a null line rather than throwing' {
        Test-ProgressRepaint -Line $null | Should-BeFalse
    }

    It 'returns a real boolean' {
        Test-ProgressRepaint -Line 'text' | Should-HaveType ([bool])
    }
}

Describe 'A step strips progress repaints from what it shows and logs' -Tag 'Unit' {

    BeforeEach {
        $script:logDir   = Join-Path $TestDrive ('rp-' + [guid]::NewGuid().ToString('N'))
        $null            = New-Item -ItemType Directory -Path $script:logDir -Force
        $script:runStamp = 'rp'
        $script:Results  = [System.Collections.Generic.List[object]]::new()
    }

    It 'keeps the real lines and drops the repaints' {
        Invoke-Step -Name 'prog' -Action {
            'Starting package install...'
            '  -'
            '  \'
            ([string]([char]0x2588) * 8) + '  48%'
            '95%'
            'Successfully installed'
        } 6>$null

        $body = @(Get-Content (Join-Path $script:logDir 'prog-rp.log') |
            Where-Object { $_ -notmatch '^\d{4}-\d{2}-\d{2} ' })

        $body | Should-BeCollection -Count 2
    }

    It 'still records the step as OK' {
        Invoke-Step -Name 'prog' -Action { '  /'; '50%'; 'done' } 6>$null
        $script:Results[0].Status | Should-Be 'OK'
    }
}

Describe 'Test-ParameterSupport' -Tag 'Unit' {

    # Windows PowerShell ships PowerShellGet 1.0.0.1, whose Update-Module has no
    # -AcceptLicense. Splatting it there is a terminating error, and it failed
    # both the "PowerShell modules" and "Windows Update" steps on a 5.1 run.

    It 'reports true for a parameter the resolved command really has' {
        Test-ParameterSupport -Command 'Get-ChildItem' -Parameter 'Recurse' |
            Should-BeTrue
    }

    It 'reports false for a parameter the resolved command does not have' {
        Test-ParameterSupport -Command 'Get-ChildItem' -Parameter 'AcceptLicense' |
            Should-BeFalse
    }

    # A missing command is the ordinary case on a host without PowerShellGet, so
    # it has to answer rather than throw.
    It 'reports false for a command that does not exist' {
        Test-ParameterSupport -Command 'No-SuchCommandExists' -Parameter 'Whatever' |
            Should-BeFalse
    }

    It 'returns a real boolean rather than a truthy object' {
        Test-ParameterSupport -Command 'Get-ChildItem' -Parameter 'Recurse' |
            Should-HaveType ([bool])
    }
}

Describe 'The gallery steps never splat a parameter blindly' -Tag 'Static' {

    # The regression these guard is subtle: -AcceptLicense is correct on
    # PSResourceGet and on PowerShellGet v2, so it looks right everywhere until
    # it runs on the version Windows actually ships.

    BeforeAll {
        $script:MainSource = Get-Content `
            (Join-Path (Split-Path $PSScriptRoot -Parent) 'src\Public\Update-Everything.ps1') -Raw
    }

    It 'guards the Update-Module call' {
        $script:MainSource |
            Should-MatchString "Test-ParameterSupport -Command 'Update-Module' -Parameter 'AcceptLicense'"
    }

    It 'guards the Install-Module call' {
        $script:MainSource |
            Should-MatchString "Test-ParameterSupport -Command 'Install-Module' -Parameter 'AcceptLicense'"
    }

    # Update-PSResource is a different command with a different history, and it
    # has always had the parameter, so it needs no guard.
    It 'leaves the PSResourceGet branch alone' {
        $script:MainSource | Should-MatchString 'Update-PSResource @p'
    }
}

Describe 'Test-PackagedProcess' -Tag 'Unit','Security' {

    It 'recognises the package binary under WindowsApps' {
        Test-PackagedProcess -Path "$env:ProgramFiles\WindowsApps\Microsoft.PowerShell_7.6.5.0_x64__8wekyb3d8bbwe\pwsh.exe" |
            Should-BeTrue
    }

    # The alias is a zero-byte reparse point, not a program. Start-Process
    # cannot launch it and Task Scheduler cannot either.
    It 'recognises the app execution alias' {
        Test-PackagedProcess -Path "$env:LOCALAPPDATA\Microsoft\WindowsApps\pwsh.exe" |
            Should-BeTrue
    }

    It 'accepts the MSI install as unpackaged' {
        Test-PackagedProcess -Path "$env:ProgramFiles\PowerShell\7\pwsh.exe" |
            Should-BeFalse
    }

    It 'accepts Windows PowerShell as unpackaged' {
        Test-PackagedProcess -Path "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe" |
            Should-BeFalse
    }

    # A substring test would call this packaged. It is an ordinary folder that
    # happens to share a name, and refusing to elevate over it would be wrong.
    It 'does not match a folder merely named WindowsApps elsewhere' {
        Test-PackagedProcess -Path 'D:\Backup\WindowsApps\pwsh.exe' | Should-BeFalse
    }

    It 'treats an empty path as unpackaged rather than throwing' {
        Test-PackagedProcess -Path '' | Should-BeFalse
    }

    It 'treats a null path as unpackaged rather than throwing' {
        Test-PackagedProcess -Path $null | Should-BeFalse
    }

    It 'returns a real boolean' {
        Test-PackagedProcess -Path 'C:\nowhere\pwsh.exe' | Should-HaveType ([bool])
    }
}

Describe 'The PowerShellGet upgrade offer' -Tag 'Static' {

    # PowerShellGet 1.0.0.1 is what Windows ships and it never updates itself.
    # Test-ParameterSupport stops it failing the module step, but it cannot fix
    # the deeper problem: v1 does not see modules installed by v2, so
    # Update-Module on 5.1 quietly skips most of what is actually installed.

    BeforeAll {
        $script:MainSource = Get-Content `
            (Join-Path (Split-Path $PSScriptRoot -Parent) 'src\Public\Update-Everything.ps1') -Raw
    }

    It 'is gated behind the same consent prompt as every other install' {
        $script:MainSource | Should-MatchString "Approve-Install -Component 'PowerShellGet'"
    }

    It 'only fires when the installed version predates 2.0' {
        $script:MainSource | Should-MatchString "\`$psget\.Version -lt \[version\]'2\.0\.0'"
    }

    # The Trust PSGallery step carries no -RequiresAdmin, and -Scope AllUsers
    # fails without elevation, so an unelevated run has to fall back rather than
    # throw in a step that was working fine before.
    It 'installs to AllUsers only when the run is elevated' {
        $script:MainSource | Should-MatchString "if \(\`$isAdmin\) \{ 'AllUsers' \} else \{ 'CurrentUser' \}"
    }

    # Declining is not fatal here: trust is already set and the module step still
    # runs on v1, unlike the NuGet provider which the step cannot work without.
    It 'does not abort the step when the offer is declined' {
        $script:MainSource | Should-NotMatchString "PowerShellGet'[\s\S]{0,400}Stop-StepAsSkipped"
    }

    It 'is accepted by -AllowInstall on both entry points' -ForEach @(
        'src\Public\Update-Everything.ps1'
        'src\Public\Register-UpdateEverythingTask.ps1'
    ) {
        Get-Content (Join-Path (Split-Path $PSScriptRoot -Parent) $_) -Raw |
            Should-MatchString "ValidateSet\('All', 'PowerShell7', 'PSWindowsUpdate', 'NuGetProvider', 'BurntToast', 'PowerShellGet'\)"
    }
}

Describe 'The summary says notifications were not requested' -Tag 'Static' {

    # -Notify defaults to off, so a run that does not pass it never reaches
    # Initialize-NotificationSupport and never offers to install BurntToast.
    # That is correct, but the run said nothing at all about it, which reads as
    # a broken feature rather than an unrequested one, and sends people looking
    # for a consent prompt that was never going to appear.

    It 'reports the unrequested case rather than staying silent' {
        Get-Content (Join-Path (Split-Path $PSScriptRoot -Parent) 'src\Public\Update-Everything.ps1') -Raw |
            Should-MatchString 'Notifications: not requested'
    }

    It 'names the switch that turns them on' {
        Get-Content (Join-Path (Split-Path $PSScriptRoot -Parent) 'src\Public\Update-Everything.ps1') -Raw |
            Should-MatchString 'Notifications: not requested[^\r\n]*-Notify'
    }

    # The existing branch reports notifications that were asked for and could not
    # be sent. This must not swallow it.
    It 'still reports notifications that were requested but unavailable' {
        Get-Content (Join-Path (Split-Path $PSScriptRoot -Parent) 'src\Public\Update-Everything.ps1') -Raw |
            Should-MatchString 'Notifications were requested but could not be sent'
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
            # Mocked rather than left to the real host: whether the developer's
            # own PowerShell came from the Store decides this answer otherwise,
            # and a test that passes or fails on that is not testing anything.
            Mock Test-PackagedProcess { $false }
        }

        It 'allows elevation to be attempted' {
            (Test-ElevationCapability).CanElevate | Should-BeTrue
        }

        It 'does not claim the session is already elevated' {
            (Test-ElevationCapability).IsElevated | Should-BeFalse
        }
    }

    # winget has defaulted Microsoft.PowerShell to the MSIX installer since 7.6,
    # so this is the ordinary state of a machine that installed pwsh the obvious
    # way. Windows does not run packaged apps elevated, and the run used to
    # discover that by raising a UAC prompt that could not succeed and then
    # reporting the failure as though the user had declined it.
    Context 'An MSIX PowerShell with no MSI build installed' {

        BeforeEach {
            Mock Test-IsAdministrator { $false }
            Mock Test-AdministratorGroupMember { $true }
            Mock Test-UacEnabled { $true }
            Mock Test-PackagedProcess { $true }
            Mock Test-Path { $false } -ParameterFilter { $LiteralPath -like '*PowerShell\7\pwsh.exe' }
        }

        It 'refuses rather than raising a prompt that cannot succeed' {
            (Test-ElevationCapability).CanElevate | Should-BeFalse
        }

        It 'names the packaged build as the reason' {
            (Test-ElevationCapability).Reason | Should-MatchString 'MSIX'
        }

        It 'gives the command that installs a build which can elevate' {
            (Test-ElevationCapability).Reason | Should-MatchString 'installer-type wix'
        }

        It 'still offers -SkipElevation as the way forward' {
            (Test-ElevationCapability).Reason | Should-MatchString 'SkipElevation'
        }
    }

    # The MSI build sits at a fixed path and can elevate, so a packaged host is
    # only a dead end when nothing else is installed. Invoke-SelfElevation
    # relaunches through the MSI in this case.
    Context 'An MSIX PowerShell with the MSI build alongside it' {

        BeforeEach {
            Mock Test-IsAdministrator { $false }
            Mock Test-AdministratorGroupMember { $true }
            Mock Test-UacEnabled { $true }
            Mock Test-PackagedProcess { $true }
            Mock Test-Path { $true } -ParameterFilter { $LiteralPath -like '*PowerShell\7\pwsh.exe' }
        }

        It 'allows elevation to be attempted' {
            (Test-ElevationCapability).CanElevate | Should-BeTrue
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
            Mock Test-PackagedProcess { $false }
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
