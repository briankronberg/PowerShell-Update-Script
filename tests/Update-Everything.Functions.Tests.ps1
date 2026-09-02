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

Describe 'Get-ElevationPolicyNote' -Tag 'Unit','Security' {

    # "Elevation was declined or failed" is true and useless on a managed
    # machine. This names the value that did it. It reports and never decides:
    # refusing a run over these would lock out exactly the people they affect,
    # because Test-AdministratorGroupMember already answers $null when a
    # filtered token hides the Administrators SID.

    BeforeEach {
        # No broker, so these test the registry path alone. Without this the
        # three "says nothing" tests pass or fail depending on what is running on
        # the machine -- they were silently host-dependent until a privilege
        # broker was added to what this function looks at, and then failed on the
        # first machine that had one.
        Mock Get-Service { @() }
    }

    It 'says nothing on a machine with no restrictive policy' {
        Mock Get-ItemProperty { [pscustomobject]@{ EnableLUA = 1; ConsentPromptBehaviorAdmin = 2 } }
        Get-ElevationPolicyNote | Should-BeNull
    }

    It 'says nothing when the policy key cannot be read' {
        Mock Get-ItemProperty { }
        Get-ElevationPolicyNote | Should-BeNull
    }

    It 'names a standard-user denial' {
        Mock Get-ItemProperty { [pscustomobject]@{ ConsentPromptBehaviorUser = 0 } }
        Get-ElevationPolicyNote | Should-MatchString 'ConsentPromptBehaviorUser is 0'
    }

    It 'names UAC being switched off' {
        Mock Get-ItemProperty { [pscustomobject]@{ EnableLUA = 0 } }
        Get-ElevationPolicyNote | Should-MatchString 'EnableLUA is 0'
    }

    It 'names a signature requirement' {
        Mock Get-ItemProperty { [pscustomobject]@{ ValidateAdminCodeSignatures = 1 } }
        Get-ElevationPolicyNote | Should-MatchString 'ValidateAdminCodeSignatures is 1'
    }

    # A machine can carry more than one, and hearing about only the first would
    # send someone to change a value that was not the whole story.
    It 'names every restrictive value, not just the first' {
        Mock Get-ItemProperty {
            [pscustomobject]@{ EnableLUA = 0; ConsentPromptBehaviorUser = 0; ValidateAdminCodeSignatures = 1 }
        }
        $note = Get-ElevationPolicyNote
        @('EnableLUA is 0', 'ConsentPromptBehaviorUser is 0', 'ValidateAdminCodeSignatures is 1') |
            Should-All { $note -match $_ }
    }

    # The permissive settings are the common case. Reporting them would make the
    # note appear on every machine and mean nothing on any of them.
    It 'stays quiet when the same values are set permissively' {
        Mock Get-ItemProperty {
            [pscustomobject]@{ EnableLUA = 1; ConsentPromptBehaviorUser = 3; ValidateAdminCodeSignatures = 0 }
        }
        Get-ElevationPolicyNote | Should-BeNull
    }
}

Describe 'A failed elevation names the policy' -Tag 'Static','Security' {

    It 'appends the policy note to the failure it throws' {
        Get-Content (Join-Path (Split-Path $PSScriptRoot -Parent) 'src\Private\Invoke-SelfElevation.ps1') -Raw |
            Should-MatchString '\$policyNote = Get-ElevationPolicyNote'
    }

    It 'still points at -SkipElevation' {
        Get-Content (Join-Path (Split-Path $PSScriptRoot -Parent) 'src\Private\Invoke-SelfElevation.ps1') -Raw |
            Should-MatchString 'Re-run with -SkipElevation'
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

    # The component name now comes from the table the step loops over, so the
    # gate is asserted through that rather than as a literal. InstallConsent's
    # "guards every install command with an approval check" is the general
    # proof; this is the one that says PowerShellGet is still in the set.
    It 'is gated behind the same consent prompt as every other install' {
        $script:MainSource | Should-MatchString 'Approve-Install -Component \$tool\.Component'
        $script:MainSource | Should-MatchString "Module = 'PowerShellGet';\s+Component = 'PowerShellGet'"
    }

    # The version is not the test, and was never quite the right one. Windows
    # ships PowerShellGet 1.0.0.1 in a form Update-Module refuses, and so does
    # PowerShell 7 with its own 2.2.5 -- the shared condition is whether
    # PowerShellGet recorded the install, not what number it carries.
    It 'decides by whether the copy can be updated, not by its version' {
        $script:MainSource | Should-NotMatchString "\`$psget\.Version -lt \[version\]'2\.0\.0'"
        $script:MainSource | Should-MatchString '\$status\.Updatable'
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
            Should-MatchString "ValidateSet\('All', 'PowerShell7', 'PSWindowsUpdate', 'NuGetProvider', 'BurntToast', 'PowerShellGet', 'PSResourceGet'\)"
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

    Context 'An account that is not in the local Administrators group' {

        # Not being in the group is a Caution rather than a refusal. Machines
        # running a privilege-management broker -- BeyondTrust, CyberArk EPM,
        # Admin By Request -- keep the account out of the group and elevate it
        # anyway, often per application, so membership does not settle whether
        # elevation is available. A prompt that then fails is already reported
        # well.

        BeforeEach {
            Mock Test-IsAdministrator { $false }
            Mock Test-AdministratorGroupMember { $false }
            Mock Test-UacEnabled { $true }
            Mock Test-PackagedProcess { $false }
        }

        It 'attempts elevation rather than refusing' {
            (Test-ElevationCapability).CanElevate | Should-BeTrue
        }

        It 'warns that the prompt may be refused' {
            (Test-ElevationCapability).Caution | Should-MatchString 'may be refused'
        }

        It 'says why attempting is still worth it' {
            (Test-ElevationCapability).Caution | Should-MatchString 'privilege-management broker'
        }

        It 'points at -SkipElevation as the way forward' {
            (Test-ElevationCapability).Caution | Should-MatchString 'SkipElevation'
        }
    }

    Context 'The caution reaches the person running it' {

        It 'is written as a warning before elevation is attempted' {
            $source = Get-Content `
                (Join-Path (Split-Path $PSScriptRoot -Parent) 'src\Public\Update-Everything.ps1') -Raw

            $warned = $source.IndexOf('if ($elevation.Caution) { Write-Warning $elevation.Caution }')
            $attempt = $source.IndexOf('Invoke-SelfElevation -BoundParameters')

            $warned | Should-BeGreaterThan -1
            $warned | Should-BeLessThan $attempt
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

Describe 'Get-GalleryModuleStatus' -Tag 'Unit' {

    # Get-Module is left real and asked about modules whose presence is already
    # known: Pester is installed, because it is running this. Mocking Get-Module
    # would put a mock in the path of Pester's own calls to it.
    #
    # Find-Module is mocked in every case, so nothing here needs a network.

    BeforeAll {
        $script:PesterVersion = @(Get-Module Pester -ListAvailable |
            Sort-Object Version -Descending)[0].Version
        $script:Absent = 'UpdateEverything.NoSuchModule.7f3a1c'
    }

    It 'reports an update when the gallery is ahead of what is installed' {
        $newer = [version]::new($script:PesterVersion.Major + 1, 0, 0)
        Mock Find-Module { [pscustomobject]@{ Version = $newer } }

        $status = Get-GalleryModuleStatus -Name Pester

        $status.Installed   | Should-Be $script:PesterVersion
        $status.Available   | Should-Be $newer
        $status.NeedsUpdate | Should-BeTrue
    }

    It 'reports no update when the gallery matches what is installed' {
        Mock Find-Module { [pscustomobject]@{ Version = $script:PesterVersion } }

        (Get-GalleryModuleStatus -Name Pester).NeedsUpdate | Should-BeFalse
    }

    It 'reports no update when the gallery is behind what is installed' {
        Mock Find-Module { [pscustomobject]@{ Version = '0.0.1' } }

        (Get-GalleryModuleStatus -Name Pester).NeedsUpdate | Should-BeFalse
    }

    # A gallery that cannot be reached must present as "cannot tell", never as
    # "up to date" and never as a reason to reinstall.
    It 'reports Available as null when the gallery cannot be reached' {
        Mock Find-Module { throw 'no such host is known' }

        $status = Get-GalleryModuleStatus -Name Pester

        $status.Available   | Should-BeNull
        $status.NeedsUpdate | Should-BeFalse
        $status.Installed   | Should-Be $script:PesterVersion
    }

    It 'reports Installed as null for a module that is not on the machine' {
        Mock Find-Module { [pscustomobject]@{ Version = '9.9.9' } }

        (Get-GalleryModuleStatus -Name $script:Absent).Installed | Should-BeNull
    }

    # An absent module is an install decision, not an update, and the caller
    # tells them apart by this flag.
    It 'never reports an update for a module that is not installed' {
        Mock Find-Module { [pscustomobject]@{ Version = '9.9.9' } }

        (Get-GalleryModuleStatus -Name $script:Absent).NeedsUpdate | Should-BeFalse
    }

    # Update-Module refuses anything it did not install, so this is the flag that
    # decides between an update and a side-by-side install. Get-InstalledModule
    # is mocked rather than read, because whether this machine's Pester arrived
    # through Install-Module is not something a test should depend on.
    It 'reports Updatable when the receipt covers the newest installed copy' {
        Mock Find-Module { [pscustomobject]@{ Version = '9.9.9' } }
        Mock Get-InstalledModule { [pscustomobject]@{ Name = 'Pester'; Version = $script:PesterVersion } }

        (Get-GalleryModuleStatus -Name Pester).Updatable | Should-BeTrue
    }

    # A receipt can name an older version than the newest copy on disk: a
    # gallery install followed by a GitHub install leaves exactly that. The
    # newest copy is then not the one Update-Module moves.
    It 'does not call the newest copy updatable on an older receipt' {
        Mock Find-Module { [pscustomobject]@{ Version = '9.9.9' } }
        Mock Get-InstalledModule { [pscustomobject]@{ Name = 'Pester'; Version = [version] '0.0.1' } }

        (Get-GalleryModuleStatus -Name Pester).Updatable | Should-BeFalse
    }

    It 'reports a copy the host shipped as not updatable' {
        Mock Find-Module { [pscustomobject]@{ Version = '9.9.9' } }
        Mock Get-InstalledModule { }

        (Get-GalleryModuleStatus -Name Pester).Updatable | Should-BeFalse
    }

    # NeedsUpdate answers "is the gallery ahead", not "can this be updated".
    # The caller needs both, and conflating them is what drove Update-Module at
    # a shipped PowerShellGet 1.0.0.1 and failed the step.
    It 'still reports NeedsUpdate for a shipped copy the gallery is ahead of' {
        Mock Find-Module { [pscustomobject]@{ Version = '9.9.9' } }
        Mock Get-InstalledModule { }

        $status = Get-GalleryModuleStatus -Name Pester
        $status.NeedsUpdate | Should-BeTrue
        $status.Updatable   | Should-BeFalse
    }

    It 'reports a module that is not installed as not updatable' {
        Mock Find-Module { [pscustomobject]@{ Version = '9.9.9' } }

        (Get-GalleryModuleStatus -Name $script:Absent).Updatable | Should-BeFalse
    }

    # Find-Module returns the version as a string on some PowerShellGet versions
    # and a [version] on others, and a prerelease carries a suffix that [version]
    # cannot parse at all.
    It 'strips a prerelease suffix rather than failing on it' {
        Mock Find-Module { [pscustomobject]@{ Version = '9.9.9-preview3' } }

        (Get-GalleryModuleStatus -Name Pester).Available | Should-Be ([version]'9.9.9')
    }
}

Describe 'The Gallery tooling step' -Tag 'Static' {

    # The gallery tooling was installed when missing and then never brought
    # forward, so a machine could carry a years-old NuGet provider or a
    # PowerShellGet 2.1 indefinitely. Every other gallery step runs on it.

    BeforeAll {
        $script:MainSource = Get-Content `
            (Join-Path (Split-Path $PSScriptRoot -Parent) 'src\Public\Update-Everything.ps1') -Raw

        $script:ToolingAt = $script:MainSource.IndexOf("Invoke-Step -Name 'Gallery tooling'")
        $script:ModulesAt = $script:MainSource.IndexOf("Invoke-Step -Name 'PowerShell modules'")
        $script:TrustAt   = $script:MainSource.IndexOf("Invoke-Step -Name 'Trust PSGallery'")
    }

    It 'exists' {
        $script:ToolingAt | Should-BeGreaterThan -1
    }

    # Trust has to be set before anything installs, or the install stops on the
    # untrusted-repository prompt rather than failing.
    It 'runs after the trust step' {
        $script:ToolingAt | Should-BeGreaterThan $script:TrustAt
    }

    # The module step is one of the things that runs on this tooling, so
    # updating it afterwards would leave the run using the version it was
    # trying to replace.
    It 'runs before the step that depends on it' {
        $script:ToolingAt | Should-BeLessThan $script:ModulesAt
    }

    It 'asks the gallery through the shared helper rather than inline' {
        $script:MainSource | Should-MatchString 'Get-GalleryModuleStatus -Name \$name'
    }

    It 'covers PSResourceGet as well as PowerShellGet' {
        $script:MainSource | Should-MatchString ([regex]::Escape('Microsoft.PowerShell.PSResourceGet'))
    }

    # Update-Module refuses anything it did not install, so a copy the host
    # shipped can only be replaced side by side -- which is an install, and asks.
    # Windows PowerShell ships PowerShellGet 1.0.0.1 exactly this way, and
    # driving it with Update-Module fails the step outright.
    It 'tells a shipped copy apart from one it can update' {
        $script:MainSource | Should-MatchString '\$status\.Updatable'
    }

    It 'asks before replacing a shipped copy side by side' {
        $script:MainSource | Should-MatchString 'cannot be updated in place'
    }

    # Updating something already present needs no approval, and Update-Module
    # and Update-PSResource are the commands that say so. Install-Module -Force
    # would also work and would read as an install.
    It 'updates a present module with an update command, not an install' {
        $script:MainSource | Should-MatchString 'Update-PSResource -Name \$name'
        $script:MainSource | Should-MatchString 'Update-Module -Name \$name'
    }

    # The module is already loaded, so the files on disk are replaced and the
    # cmdlets running now stay on the code in memory. Reporting it as though the
    # run then benefits is the mistake this guards.
    It 'says an update takes effect in the next session' {
        $script:MainSource | Should-MatchString 'loads in the next session'
    }

    # There is no Update-PackageProvider, so moving a provider forward means
    # running an install command against a binary provider assembly. It asks
    # under the component that already covers the bootstrap.
    It 'gates the provider refresh behind the NuGetProvider component' {
        $script:MainSource | Should-MatchString "Approve-Install -Component 'NuGetProvider'[\s\S]{0,600}Install-PackageProvider -Name NuGet -Force"
    }

    It 'does not treat a gallery it could not reach as up to date' {
        $script:MainSource | Should-MatchString 'the gallery could not be asked about it'
    }

    # Find-PackageProvider fails outright on PowerShell 7, which registers no
    # provider bootstrap source. Reporting that as "current" would claim a
    # machine is up to date on the strength of a lookup that never happened --
    # the same mistake as above, in the branch that does not use the helper.
    It 'does not treat a provider it could not look up as up to date' {
        $script:MainSource | Should-MatchString 'no newer version could be looked up on this host'
    }
}

Describe 'Test-StepTagMatch' -Tag 'Unit' {

    Context 'No filter' {

        # @($null) has a Count of 1 in PowerShell, so counting a filter without
        # first stripping nulls reads an unset one as "one entry, matching
        # nothing" -- which skipped every step in the run.
        It 'runs a step when both filters are null' {
            Test-StepTagMatch -StepTag @('Python') -Tag $null -ExcludeTag $null | Should-BeTrue
        }

        It 'runs a step when both filters are empty' {
            Test-StepTagMatch -StepTag @('Python') | Should-BeTrue
        }

        It 'runs an untagged step when there is no filter' {
            Test-StepTagMatch -StepTag @() | Should-BeTrue
        }
    }

    Context '-Tag selects' {

        It 'runs a step carrying the tag' {
            Test-StepTagMatch -StepTag @('Python') -Tag @('Python') | Should-BeTrue
        }

        It 'runs a step carrying one of several tags' {
            Test-StepTagMatch -StepTag @('Windows', 'PackageManager') -Tag @('PackageManager') | Should-BeTrue
        }

        It 'skips a step carrying none of them' {
            Test-StepTagMatch -StepTag @('Node') -Tag @('Python') | Should-BeFalse
        }

        # Asking for Python and receiving a step that claims no subject at all
        # would make the filter meaningless.
        It 'skips an untagged step when a tag was asked for' {
            Test-StepTagMatch -StepTag @() -Tag @('Python') | Should-BeFalse
        }
    }

    Context '-ExcludeTag refuses' {

        It 'skips a step carrying the excluded tag' {
            Test-StepTagMatch -StepTag @('Python') -ExcludeTag @('Python') | Should-BeFalse
        }

        It 'runs a step carrying none of them' {
            Test-StepTagMatch -StepTag @('Node') -ExcludeTag @('Python') | Should-BeTrue
        }

        It 'runs an untagged step' {
            Test-StepTagMatch -StepTag @() -ExcludeTag @('Python') | Should-BeTrue
        }

        It 'skips a step that carries the excluded tag among others' {
            Test-StepTagMatch -StepTag @('Windows', 'Microsoft') -ExcludeTag @('Microsoft') | Should-BeFalse
        }
    }

    Context 'Both at once' {

        # Not a contradiction: the pair is how one task takes everything in a
        # subject except one part of it.
        It 'runs a step selected by -Tag and not excluded' {
            Test-StepTagMatch -StepTag @('Python') -Tag @('Python') -ExcludeTag @('Node') | Should-BeTrue
        }

        It 'lets exclusion win over selection' {
            Test-StepTagMatch -StepTag @('Python') -Tag @('Python') -ExcludeTag @('Python') | Should-BeFalse
        }
    }
}

Describe 'The skip reason names the filter that refused the step' -Tag 'Unit' {

    # Exclusion wins when both filters are given, so a reason worked out by
    # asking "was -Tag set" first blames -Tag for an exclusion and sends someone
    # looking at the wrong parameter.

    BeforeEach {
        $script:logDir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $script:logDir -Force
        $script:runStamp = 'reason'
        $script:isAdmin = $true
        $script:Results = [System.Collections.Generic.List[object]]::new()
        $script:TagFilter = @()
        $script:ExcludeTagFilter = @()
    }

    It 'blames -ExcludeTag when that is what refused it' {
        $script:TagFilter = @('PowerShell')
        $script:ExcludeTagFilter = @('Windows')

        Invoke-Step -Name 'both' -Tag 'PowerShell', 'Windows' -Action { 'x' } 6>$null

        $script:Results[0].Status | Should-Be 'Skipped'
    }

    It 'blames -Tag when nothing was excluded' {
        $script:TagFilter = @('Python')

        Invoke-Step -Name 'other' -Tag 'Node' -Action { 'x' } 6>$null

        $script:Results[0].Status | Should-Be 'Skipped'
    }

    It 'runs a step that survives both filters' {
        $script:TagFilter = @('PowerShell')
        $script:ExcludeTagFilter = @('Windows')

        Invoke-Step -Name 'kept' -Tag 'PowerShell' -Action { 'x' } 6>$null

        $script:Results[0].Status | Should-Be 'OK'
    }
}

Describe 'Every step declares a tag' -Tag 'Static' {

    # A step with no tag is invisible to -Tag and unstoppable by -ExcludeTag, so
    # it would quietly run in every filtered run. The ValidateSet is the other
    # half: a tag no step carries selects nothing, and a typo would.

    BeforeAll {
        $script:MainPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'src\Public\Update-Everything.ps1'
        $script:MainAst = [System.Management.Automation.Language.Parser]::ParseFile(
            $script:MainPath, [ref] $null, [ref] $null)

        $script:StepTags = @{}
        foreach ($call in $script:MainAst.FindAll({
                    param($n)
                    $n -is [System.Management.Automation.Language.CommandAst] -and
                    $n.GetCommandName() -eq 'Invoke-Step'
                }, $true)) {

            $elements = $call.CommandElements
            $name = $null
            $tags = @()
            for ($i = 0; $i -lt $elements.Count; $i++) {
                if ($elements[$i] -isnot [System.Management.Automation.Language.CommandParameterAst]) { continue }
                switch ($elements[$i].ParameterName) {
                    'Name' { if ($i + 1 -lt $elements.Count) { $name = $elements[$i + 1].Value } }
                    'Tag'  {
                        if ($i + 1 -lt $elements.Count) {
                            $tags = @($elements[$i + 1].Extent.Text -split ',' |
                                ForEach-Object { $_.Trim().Trim("'", '"') })
                        }
                    }
                }
            }
            if ($name) { $script:StepTags[$name] = $tags }
        }

        # Read from the parameter itself rather than kept as a copy, which had
        # already drifted once by the time a new tag landed.
        $script:DeclaredTags = @((Get-Command Update-Everything).Parameters['Tag'].Attributes |
            Where-Object { $_ -is [System.Management.Automation.ValidateSetAttribute] } |
            ForEach-Object { $_.ValidValues })
    }

    It 'validates the same tag set on <_> of both entry points' -ForEach @('Tag', 'ExcludeTag') {
        $parameter = $_
        $register = @((Get-Command Register-UpdateEverythingTask).Parameters[$parameter].Attributes |
            Where-Object { $_ -is [System.Management.Automation.ValidateSetAttribute] } |
            ForEach-Object { $_.ValidValues })
        $update = @((Get-Command Update-Everything).Parameters[$parameter].Attributes |
            Where-Object { $_ -is [System.Management.Automation.ValidateSetAttribute] } |
            ForEach-Object { $_.ValidValues })

        $register | Should-BeCollection $script:DeclaredTags
        $update   | Should-BeCollection $script:DeclaredTags
    }

    It 'found the steps to check' {
        $script:StepTags.Count | Should-BeGreaterThan 20
    }

    It 'gives every step at least one tag' {
        $untagged = $script:StepTags.GetEnumerator() |
            Where-Object { -not $_.Value -or -not @($_.Value | Where-Object { $_ }).Count } |
            ForEach-Object { $_.Key }

        $untagged | Should-BeNull -Because "these run in every filtered run and cannot be excluded:`n$($untagged -join "`n")"
    }

    It 'uses only tags the ValidateSet accepts' {
        $unknown = $script:StepTags.GetEnumerator() |
            ForEach-Object {
                $step = $_.Key
                $_.Value | Where-Object { $_ -and $_ -notin $script:DeclaredTags } |
                    ForEach-Object { "$step -> $_" }
            }

        $unknown | Should-BeNull -Because "a tag outside the ValidateSet can never be asked for:`n$($unknown -join "`n")"
    }

    It 'declares no tag that no step carries' {
        $used = $script:StepTags.Values | ForEach-Object { $_ } | Where-Object { $_ } | Select-Object -Unique
        $orphans = $script:DeclaredTags | Where-Object { $_ -notin $used }

        $orphans | Should-BeNull -Because "these select nothing, so asking for one runs an empty pass: $($orphans -join ', ')"
    }

    It 'accepts -<_> on both entry points' -ForEach @('Tag', 'ExcludeTag') {
        $parameter = $_
        foreach ($file in 'src\Public\Update-Everything.ps1', 'src\Public\Register-UpdateEverythingTask.ps1') {
            Get-Content (Join-Path (Split-Path $PSScriptRoot -Parent) $file) -Raw |
                Should-MatchString "\`$$parameter = @\(\)"
        }
    }
}

Describe 'Get-UpdateToolInventory' -Tag 'Unit' {

    # A catalogue is passed in rather than using the real one, so the test does
    # not depend on what happens to be installed on the machine running it.

    BeforeAll {
        $script:RealTool  = @{ Name = 'PowerShell'; Command = 'powershell'; VersionArgument = $null }
        $script:FakeTool  = @{ Name = 'Nothing';    Command = 'ue-no-such-tool-7f3a1c'; VersionArgument = '--version' }
    }

    It 'reports a tool that is on the machine as present' {
        $r = Get-UpdateToolInventory -Catalogue @($script:RealTool)
        $r.Present | Should-BeTrue
    }

    It 'reports a tool that is not as absent' {
        $r = Get-UpdateToolInventory -Catalogue @($script:FakeTool)
        $r.Present | Should-BeFalse
    }

    It 'gives an absent tool no version, owner or place' {
        $r = Get-UpdateToolInventory -Catalogue @($script:FakeTool)
        $r.Version | Should-BeNull
        $r.Owner   | Should-BeNull
        $r.Copies  | Should-Be 0
    }

    It 'returns one record per catalogue entry' {
        $r = @(Get-UpdateToolInventory -Catalogue @($script:RealTool, $script:FakeTool))
        $r | Should-BeCollection -Count 2
    }

    It 'carries the friendly name through, not just the command' {
        (Get-UpdateToolInventory -Catalogue @($script:FakeTool)).Name | Should-Be 'Nothing'
    }

    # PATHEXT resolves npm.cmd and npm from one folder as two commands. Counting
    # files would report a single install as a conflict, and a warning that cries
    # wolf is one people stop reading.
    It 'counts places rather than executables' {
        $r = Get-UpdateToolInventory -Catalogue @($script:RealTool)
        $r.Copies | Should-Be @($r.Places).Count
    }

    It 'does not let a tool that fails its version argument fail the inventory' {
        # A real executable given an argument it rejects.
        $bad = @{ Name = 'Bad'; Command = 'powershell'; VersionArgument = '--definitely-not-a-flag' }

        $r = Get-UpdateToolInventory -Catalogue @($bad)
        $r.Present | Should-BeTrue
    }

    It 'leaves no non-zero exit code behind for the step runner to fail on' {
        $bad = @{ Name = 'Bad'; Command = 'powershell'; VersionArgument = '--definitely-not-a-flag' }

        $null = Get-UpdateToolInventory -Catalogue @($bad)
        $LASTEXITCODE | Should-Be 0
    }
}

Describe 'Step order' -Tag 'Static' {

    # The order is a contract, not a preference, so it is asserted rather than
    # left to whoever edits the file next. Everything here is a dependency
    # somebody would otherwise have to rediscover.

    BeforeAll {
        $script:OrderSource = Get-Content `
            (Join-Path (Split-Path $PSScriptRoot -Parent) 'src\Public\Update-Everything.ps1') -Raw

        $script:Order = @([regex]::Matches($script:OrderSource, "Invoke-Step -Name '([^']+)'") |
            ForEach-Object { $_.Groups[1].Value })

        $script:PositionOf = {
            param($name)
            $i = [array]::IndexOf($script:Order, $name)
            if ($i -lt 0) { throw "No step named '$name'." }
            $i
        }
    }

    It 'found every step' {
        $script:Order.Count | Should-BeGreaterThan 20
    }

    It 'takes the inventory before it changes anything' {
        & $script:PositionOf 'Inventory' | Should-Be 0
    }

    # Chocolatey and Scoop install language toolchains. Updating uv or npm
    # first and the manager that owns it second updates a tool and then the
    # thing responsible for it.
    It '<_> runs before the toolchains it may own' -ForEach @('Chocolatey', 'Scoop') {
        $manager = & $script:PositionOf $_
        foreach ($toolchain in 'uv', 'pipx packages', 'npm', 'rustup', '.NET global tools') {
            $manager | Should-BeLessThan (& $script:PositionOf $toolchain)
        }
    }

    # winget owns Chocolatey and Scoop on plenty of machines, and App Installer
    # is winget updating itself.
    It 'updates winget before the managers winget may own' {
        $winget = & $script:PositionOf 'winget self-update'
        $winget | Should-BeLessThan (& $script:PositionOf 'winget (all sources)')
        $winget | Should-BeLessThan (& $script:PositionOf 'Chocolatey')
        $winget | Should-BeLessThan (& $script:PositionOf 'Scoop')
    }

    # The module step runs on the client the tooling step installs.
    It 'sets up the gallery before it uses the gallery' {
        (& $script:PositionOf 'Trust PSGallery')  | Should-BeLessThan (& $script:PositionOf 'Gallery tooling')
        (& $script:PositionOf 'Gallery tooling')  | Should-BeLessThan (& $script:PositionOf 'PowerShell modules')
    }

    # -AutoReboot can restart the machine out from under whatever follows, so
    # nothing may follow.
    It 'leaves Windows Update until last' {
        & $script:PositionOf 'Windows Update' | Should-Be ($script:Order.Count - 1)
    }

    # Windows Terminal's default profile points at the pwsh the PowerShell 7
    # step installs, so it has to exist first.
    It 'installs PowerShell 7 before pointing Terminal at it' {
        (& $script:PositionOf 'PowerShell 7 (latest)') |
            Should-BeLessThan (& $script:PositionOf 'Windows Terminal default = PowerShell 7')
    }
}

Describe 'Get-ModuleVersionMap' -Tag 'Unit' {

    It 'returns a hashtable keyed on module name' {
        $map = Get-ModuleVersionMap
        $map | Should-HaveType ([hashtable])
    }

    It 'finds the module running these tests' {
        (Get-ModuleVersionMap).ContainsKey('Pester') | Should-BeTrue
    }

    # A module is installed side by side, one folder per version, so the same
    # name arrives more than once and the highest is the one that binds.
    It 'keeps the highest version of a name installed more than once' {
        $map = Get-ModuleVersionMap
        $highest = @(Get-Module Pester -ListAvailable | Sort-Object Version -Descending)[0].Version

        $map['Pester'] | Should-Be $highest
    }

    It 'reports a version, not a string' {
        (Get-ModuleVersionMap)['Pester'] | Should-HaveType ([version])
    }
}

Describe 'The PowerShell modules step' -Tag 'Static' {

    BeforeAll {
        $script:ModSource = Get-Content `
            (Join-Path (Split-Path $PSScriptRoot -Parent) 'src\Public\Update-Everything.ps1') -Raw
    }

    # Update-Module and Update-PSResource are both silent on success, so the
    # step reported OK and a duration and nothing else. Forty updates and none
    # read the same.
    It 'takes a version map either side of the pass' {
        $script:ModSource | Should-MatchString '\$before = Get-ModuleVersionMap'
        $script:ModSource | Should-MatchString '\$after = Get-ModuleVersionMap'
    }

    It 'reports what moved rather than only that it finished' {
        $script:ModSource | Should-MatchString 'module\(s\) updated'
    }

    It 'says so when nothing needed updating' {
        $script:ModSource | Should-MatchString 'No modules needed updating'
    }

    It 'can be turned off' {
        $script:ModSource | Should-MatchString 'if \(-not \$IncludePowerShellModules\)'
    }

    # Skipped rather than dropped, so the summary still accounts for every step.
    It 'reports the step as skipped rather than removing it' {
        $script:ModSource | Should-MatchString "Add-SkippedStep -Name 'PowerShell modules'"
    }
}

Describe '-UpdateSelf runs only the self step' -Tag 'Static' {

    BeforeAll {
        $source = Get-Content `
            (Join-Path (Split-Path $PSScriptRoot -Parent) 'src\Public\Update-Everything.ps1') -Raw

        # The guard block, told apart from the step's own if ($UpdateSelf) by
        # the inner tag check.
        $script:Guard = [regex]::Match($source,
            "(?s)if \(\`$UpdateSelf\) \{\s*\n\s*if \(\`$Tag.*?\n    \}").Value
    }

    It 'found the guard' {
        $script:Guard | Should-NotBeEmptyString
    }

    It 'narrows the run to the Self tag' {
        $script:Guard | Should-MatchString "\`$Tag = @\('Self'\)"
    }

    It 'clears any exclusion, so -ExcludeTag Self cannot empty the run' {
        $script:Guard | Should-MatchString "\`$ExcludeTag = @\(\)"
    }

    It 'skips the elevation prompt for the self-update' {
        $script:Guard | Should-MatchString "\`$SkipElevation = \`$true"
    }

    It 'says so when tags were also passed' {
        $script:Guard | Should-MatchString 'ignored'
    }

    It 'runs before the elevation decision it suppresses' {
        $guardAt = $source.IndexOf('-UpdateSelf is a shortcut')
        $elevationAt = $source.IndexOf('$script:isAdmin = Test-IsAdministrator')

        $guardAt | Should-BeGreaterThan 0
        $guardAt | Should-BeLessThan $elevationAt
    }
}

Describe 'Updating the module itself' -Tag 'Static' {

    BeforeAll {
        $script:SelfSource = Get-Content `
            (Join-Path (Split-Path $PSScriptRoot -Parent) 'src\Public\Update-Everything.ps1') -Raw
    }

    It 'defaults to the published release rather than the branch' {
        $script:SelfSource | Should-MatchString "\`$UpdateSelfSource = 'Gallery'"
    }

    It 'still offers the branch' {
        $script:SelfSource | Should-MatchString "ValidateSet\('Gallery', 'Main'\)"
    }

    # The gallery path reuses the same check the tooling step needed: a copy the
    # GitHub installer put there was not installed by PowerShellGet, and
    # Update-Module refuses it.
    It 'notices a copy the gallery cannot move, and names the way forward' {
        $script:SelfSource | Should-MatchString 'was not installed from the gallery'
        $script:SelfSource | Should-MatchString '-UpdateSelfSource Main'
    }

    It 'says an update lands on the next run, on both paths' {
        $onNextRun = [regex]::Matches($script:SelfSource, 'loads on the next run')
        $onNextRun.Count | Should-BeGreaterThanOrEqual 2
    }
}

Describe 'Get-DeveloperToolCatalogue' -Tag 'Unit' {

    BeforeAll { $script:Catalogue = @(Get-DeveloperToolCatalogue) }

    It 'offers something to install' {
        $script:Catalogue.Count | Should-BeGreaterThan 5
    }

    It 'gives every entry a name, an id, a command and a description' {
        $incomplete = $script:Catalogue |
            Where-Object { -not $_.Name -or -not $_.Id -or -not $_.Command -or -not $_.Description } |
            ForEach-Object { $_.Name }

        $incomplete | Should-BeNull
    }

    It 'uses each name once' {
        $duplicates = $script:Catalogue | Group-Object Name | Where-Object Count -gt 1 | ForEach-Object Name
        $duplicates | Should-BeNull
    }

    It 'uses each winget id once' {
        $duplicates = $script:Catalogue | Group-Object Id | Where-Object Count -gt 1 | ForEach-Object Name
        $duplicates | Should-BeNull
    }

    It 'reports whether each tool is already on the machine' {
        $script:Catalogue[0].Present | Should-HaveType ([bool])
    }

    # winget has defaulted Microsoft.PowerShell to MSIX since 7.6, and Windows
    # will not run an MSIX process elevated. The update step forces wix for the
    # same reason.
    It 'forces the MSI build of PowerShell 7' {
        $pwsh = $script:Catalogue | Where-Object { $_.Id -eq 'Microsoft.PowerShell' }
        $pwsh.InstallerType | Should-Be 'wix'
    }
}

Describe 'Install-DeveloperTool' -Tag 'Unit' {

    # The whole point of the decision recorded in the issue: -AllowInstall All
    # must not reach the catalogue, or an unattended scheduled task quietly
    # becomes a provisioning job.
    It 'never consults the run-wide AllowInstall' {
        $source = Get-Content `
            (Join-Path (Split-Path $PSScriptRoot -Parent) 'src\Private\Install-DeveloperTool.ps1') -Raw

        $source | Should-NotMatchString '\$AllowInstall'
    }

    It 'passes the selection itself as the approval' {
        $source = Get-Content `
            (Join-Path (Split-Path $PSScriptRoot -Parent) 'src\Private\Install-DeveloperTool.ps1') -Raw

        $source | Should-MatchString 'Approve-Install -Component \$tool\.Name -Approved \$Name'
    }

    It 'refuses a name that is not in the catalogue' {
        $result = Install-DeveloperTool -Name 'NotARealTool' -WarningAction SilentlyContinue
        $result.Installed | Should-Be 0
    }

    It 'installs nothing for a name it refused' {
        $result = Install-DeveloperTool -Name 'NotARealTool' -WarningAction SilentlyContinue
        $result.Skipped | Should-Be 1
    }

    It 'skips a tool that is already on the machine' {
        # PowerShell 7 is running these tests, so pwsh resolves.
        $result = Install-DeveloperTool -Name 'PowerShell 7' -WarningAction SilentlyContinue 6>$null
        $result.Installed | Should-Be 0
        $result.Skipped   | Should-Be 1
    }
}

Describe 'Initialize-UpdateEverything' -Tag 'Unit' {

    It 'is exported by the manifest' {
        $manifest = Import-PowerShellDataFile `
            (Join-Path (Split-Path $PSScriptRoot -Parent) 'src\UpdateEverything.psd1')

        $manifest.FunctionsToExport | Should-ContainCollection 'Initialize-UpdateEverything'
    }

    It 'takes every menu option as a -Choice' {
        $set = (Get-Command Initialize-UpdateEverything).Parameters['Choice'].Attributes |
            Where-Object { $_ -is [System.Management.Automation.ValidateSetAttribute] }

        foreach ($key in 'Prerequisites', 'ScheduledTask', 'DeveloperTools', 'FirstRun') {
            $set.ValidValues | Should-ContainCollection $key
        }
    }

    # A session that cannot prompt would block on Read-Host until whatever is
    # running it gives up.
    It 'refuses to show a menu it cannot get an answer to' {
        Mock Test-CanPrompt { $false }

        $warnings = @()
        Initialize-UpdateEverything -WarningVariable warnings -WarningAction SilentlyContinue

        ($warnings -join ' ') | Should-MatchString 'interactive console'
    }

    It 'points at -Choice as the way through without a console' {
        Mock Test-CanPrompt { $false }

        $warnings = @()
        Initialize-UpdateEverything -WarningVariable warnings -WarningAction SilentlyContinue

        ($warnings -join ' ') | Should-MatchString '-Choice'
    }

    It 'does not reach the menu when -Choice is given' {
        Mock Test-CanPrompt { $false }
        Mock Invoke-SetupChoice { }

        Initialize-UpdateEverything -Choice DeveloperTools -WarningAction SilentlyContinue

        Should-Invoke Invoke-SetupChoice -ParameterFilter { $Key -eq 'DeveloperTools' }
    }
}

Describe 'The setup menu loop' -Tag 'Unit' {

    # Read-Host is mocked rather than piped. Piping makes Test-CanPrompt refuse
    # the menu outright -- correctly, since a redirected session cannot answer --
    # so the loop itself can only be reached with a mock.

    BeforeEach {
        Mock Test-CanPrompt { $true }
        Mock Invoke-SetupChoice { }
        Mock Write-Host { }
    }

    It 'exits on 5 without taking any option' {
        Mock Read-Host { '5' }

        Initialize-UpdateEverything

        Should-NotInvoke Invoke-SetupChoice
    }

    It 'takes the option matching the number typed' {
        $script:answers = @('3', '5')
        $script:next = 0
        Mock Read-Host { $script:answers[$script:next++] }

        Initialize-UpdateEverything

        Should-Invoke Invoke-SetupChoice -ParameterFilter { $Key -eq 'DeveloperTools' }
    }

    # A typo must not end the session or take an option nobody asked for.
    It 'asks again after an answer that is not an option' {
        $script:answers = @('99', 'x', '5')
        $script:next = 0
        Mock Read-Host { $script:answers[$script:next++] }

        Initialize-UpdateEverything

        Should-NotInvoke Invoke-SetupChoice
        $script:next | Should-Be 3
    }

    # Setting a task up and then running for the first time is two answers, not
    # two sessions.
    It 'keeps offering the menu until told to stop' {
        $script:answers = @('1', '4', '5')
        $script:next = 0
        Mock Read-Host { $script:answers[$script:next++] }

        Initialize-UpdateEverything

        Should-Invoke Invoke-SetupChoice -Times 2 -Exactly
    }

    It 'ignores whitespace around the answer' {
        $script:answers = @('  2  ', '5')
        $script:next = 0
        Mock Read-Host { $script:answers[$script:next++] }

        Initialize-UpdateEverything

        Should-Invoke Invoke-SetupChoice -ParameterFilter { $Key -eq 'ScheduledTask' }
    }
}

Describe 'The first run points at the setup menu' -Tag 'Static' {

    BeforeAll {
        $script:FirstRunSource = Get-Content `
            (Join-Path (Split-Path $PSScriptRoot -Parent) 'src\Public\Update-Everything.ps1') -Raw
    }

    It 'decides by looking for a previous transcript' {
        $script:FirstRunSource | Should-MatchString "\`$isFirstRun = -not @\(Get-ChildItem"
    }

    # Both would answer it wrongly: pruning can empty the directory on a machine
    # that has simply not run in a while, and the transcript would find its own
    # log and conclude the run had happened before.
    It 'asks before pruning and before the transcript starts' {
        $decided = $script:FirstRunSource.IndexOf('$isFirstRun = -not')
        $pruned  = $script:FirstRunSource.IndexOf('$cutoff = (Get-Date).AddDays')
        $started = $script:FirstRunSource.IndexOf('Start-Transcript -Path $mainLog')

        $decided | Should-BeGreaterThan -1
        $decided | Should-BeLessThan $pruned
        $decided | Should-BeLessThan $started
    }

    It 'names the command it is pointing at' {
        $script:FirstRunSource | Should-MatchString 'Initialize-UpdateEverything sets up'
    }

    # A tool that repeats advice on every run teaches people to skim past its
    # output, which costs more than the hint gains.
    It 'says it once, and only when it is the first run' {
        $mentions = [regex]::Matches($script:FirstRunSource, 'That was the first run')
        $mentions.Count | Should-Be 1
        $script:FirstRunSource | Should-MatchString 'if \(\$isFirstRun\)'
    }
}

Describe 'A step survives a caller who prefers Stop' -Tag 'Unit' {

    # Found by the fresh-machine smoke test, which is the first thing to run this
    # module from a session that sets ErrorActionPreference = Stop, on a machine
    # where WSL genuinely is not installed:
    #
    #   PS>TerminatingError(wsl.exe): "...ErrorActionPreference... is set to
    #   Stop: The Windows Subsystem for Linux is not installed."
    #   WARNING: FAILED: WSL kernel
    #
    # The step is written to handle exactly that machine and never got the
    # chance: wsl writes to stderr, Stop makes a native command's stderr
    # terminating, and the throw beat the exit-code check. npm, winget and dotnet
    # all write to stderr routinely, so this was never only about WSL.

    BeforeEach {
        $script:logDir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $script:logDir -Force
        $script:runStamp = 'eap'
        $script:isAdmin = $true
        $script:Results = [System.Collections.Generic.List[object]]::new()
        $script:TagFilter = @()
        $script:ExcludeTagFilter = @()
    }

    It 'reports a native command by its exit code, not by its stderr' {
        $ErrorActionPreference = 'Stop'

        Invoke-Step -Name 'noisy' -Action {
            & cmd.exe /c 'echo something on stderr 1>&2 & exit 0'
        } 6>$null

        $script:Results[0].Status | Should-Be 'OK'
    }

    It 'still fails a step whose command exits non-zero' {
        $ErrorActionPreference = 'Stop'

        Invoke-Step -Name 'broken' -Action {
            & cmd.exe /c 'echo bad 1>&2 & exit 3'
        } 6>$null

        $script:Results[0].Status | Should-Be 'Failed'
    }

    # The preference is set inside Invoke-Step's own scope. If it leaked, the
    # caller would silently stop getting terminating errors it asked for.
    It 'leaves the caller preference alone' {
        $ErrorActionPreference = 'Stop'

        Invoke-Step -Name 'quiet' -Action { 'x' } 6>$null

        $ErrorActionPreference | Should-Be 'Stop'
    }

    It 'still counts a PowerShell error record as a warning' {
        $ErrorActionPreference = 'Stop'

        Invoke-Step -Name 'writes-error' -Action { Write-Error 'a real one' } 6>$null

        $script:Results[0].Status | Should-Be 'Warning'
    }
}

Describe 'Format-SelfVersionStatus' -Tag 'Unit' {

    # Three answers that must not be confused, because each has been a wrong
    # message somewhere before: behind, not behind, and could not tell.

    BeforeAll {
        $script:StatusOf = {
            param($Installed, $Available, $Updatable = $true)
            [pscustomobject]@{
                Name        = 'UpdateEverything'
                Installed   = if ($Installed) { [version] $Installed } else { $null }
                Available   = if ($Available) { [version] $Available } else { $null }
                Updatable   = $Updatable
                NeedsUpdate = [bool] ($Installed -and $Available -and ([version]$Available -gt [version]$Installed))
            }
        }
    }

    It 'says the running version is current when it matches the gallery' {
        $line = Format-SelfVersionStatus -Running '1.1.0' -Status (& $script:StatusOf '1.1.0' '1.1.0')
        $line | Should-MatchString 'newest published'
    }

    It 'names both versions when the gallery is ahead' {
        $line = Format-SelfVersionStatus -Running '1.1.0' -Status (& $script:StatusOf '1.1.0' '1.2.0')
        $line | Should-MatchString '1\.1\.0'
        $line | Should-MatchString '1\.2\.0'
    }

    It 'points at -UpdateSelf when the gallery is ahead' {
        $line = Format-SelfVersionStatus -Running '1.1.0' -Status (& $script:StatusOf '1.1.0' '1.2.0')
        $line | Should-MatchString '-UpdateSelf'
    }

    # A copy the GitHub installer placed is frequently ahead of the gallery, and
    # Update-Module refuses it either way, so -UpdateSelf alone is wrong advice.
    It 'gives a copy the gallery cannot move the advice that works' {
        $line = Format-SelfVersionStatus -Running '1.1.0' -Status (& $script:StatusOf '1.1.0' '1.2.0' $false)
        $line | Should-MatchString 'Install-Module UpdateEverything -Force'
    }

    # Normal for a clone or a GitHub install, and not a fault.
    It 'does not call a version ahead of the gallery out of date' {
        $line = Format-SelfVersionStatus -Running '1.2.0' -Status (& $script:StatusOf '1.2.0' '1.1.0')
        $line | Should-MatchString 'ahead of the published'
        $line | Should-NotMatchString 'is published'
    }

    # An offline run must not report currency it did not establish.
    It 'says it could not tell when the gallery was unreachable' {
        $line = Format-SelfVersionStatus -Running '1.1.0' -Status (& $script:StatusOf '1.1.0' $null)
        $line | Should-MatchString 'could not be asked'
        $line | Should-NotMatchString 'newest published'
    }

    It 'says the same when the gallery was never asked at all' {
        $line = Format-SelfVersionStatus -Running '1.1.0' -Status $null
        $line | Should-MatchString 'could not be asked'
    }

    # Running from a clone: a manifest version, nothing installed to compare.
    It 'reports the running version even with nothing installed' {
        $line = Format-SelfVersionStatus -Running '1.2.0' -Status (& $script:StatusOf $null '1.1.0' $false)
        $line | Should-MatchString '1\.2\.0'
    }
}

Describe 'A run says which version produced it' -Tag 'Static' {

    BeforeAll {
        $script:VersionSource = Get-Content `
            (Join-Path (Split-Path $PSScriptRoot -Parent) 'src\Public\Update-Everything.ps1') -Raw
    }

    # The running module, not the highest installed. A session imported by path,
    # or one that loaded before an update replaced the files on disk, is running
    # something else -- and the log belongs to what ran.
    It 'takes the version from the module actually executing' {
        $script:VersionSource | Should-MatchString '\$MyInvocation\.MyCommand\.Module\.Version'
    }

    It 'prints it at the start, where the log is read from' {
        $banner = $script:VersionSource.IndexOf('Maintenance run started')
        $version = $script:VersionSource.IndexOf('Write-Host "UpdateEverything $script:RunningVersion"')

        $version | Should-BeGreaterThan $banner
        ($version - $banner) | Should-BeLessThan 400
    }

    # The banner costs nothing and happens always; the comparison costs a network
    # call, so it lives where -ExcludeTag Inventory already turns it off.
    It 'keeps the gallery lookup out of the startup path' {
        $lookup = $script:VersionSource.IndexOf('Format-SelfVersionStatus')
        $inventory = $script:VersionSource.IndexOf("Invoke-Step -Name 'Inventory'")
        $selfStep = $script:VersionSource.IndexOf("Invoke-Step -Name 'UpdateEverything (self)'")

        $lookup | Should-BeGreaterThan $inventory
        $lookup | Should-BeLessThan $selfStep
    }
}

Describe 'An expected answer does not throw' -Tag 'Static' {

    # Start-Transcript records a terminating error whether or not it is caught,
    # so throwing for an outcome that is expected puts a TerminatingError line in
    # a run log where nothing went wrong. Reported from a 1.1.0 run:
    #
    #   PS>TerminatingError(Find-PackageProvider): "...No match was found for
    #   the specified search criteria and package name 'NuGet'."
    #
    # The step goes on to report the right thing. Both lookups have an expected
    # empty answer on supported hosts: Find-PackageProvider cannot answer at all
    # on PowerShell 7, and Find-Module is asked about modules that may not be
    # published. Test-PendingReboot uses SilentlyContinue with Get-ItemProperty
    # for the same reason.

    BeforeAll {
        $script:LookupSources = @{
            'Update-Everything.ps1'      = Get-Content (Join-Path (Split-Path $PSScriptRoot -Parent) 'src\Public\Update-Everything.ps1') -Raw
            'Get-GalleryModuleStatus.ps1' = Get-Content (Join-Path (Split-Path $PSScriptRoot -Parent) 'src\Private\Get-GalleryModuleStatus.ps1') -Raw
        }
    }

    It 'does not ask Find-PackageProvider to throw for an empty answer' {
        $script:LookupSources['Update-Everything.ps1'] |
            Should-NotMatchString 'Find-PackageProvider[^\r\n]*-ErrorAction Stop'
    }

    It 'does not ask Find-Module to throw for an empty answer' {
        $script:LookupSources['Get-GalleryModuleStatus.ps1'] |
            Should-NotMatchString 'Find-Module[^\r\n]*-ErrorAction Stop'
    }

    # SilentlyContinue only suppresses non-terminating errors, so a hard network
    # failure still throws and still must not take the step with it.
    It 'still guards <_> against a hard failure' -ForEach @('Update-Everything.ps1', 'Get-GalleryModuleStatus.ps1') {
        $script:LookupSources[$_] | Should-MatchString 'failed outright'
    }
}

Describe 'Get-WingetUpgradeTable' -Tag 'Unit' {

    # The sample is the real table from a Windows 365 VM, which is where the
    # reporting gap was noticed. winget localises its headers and truncates the
    # Id column to the console width, so the parser anchors on the row of dashes
    # and takes column positions from the header's word starts -- neither of
    # which depends on the language.

    BeforeAll {
        $script:RealTable = @'
Name                 Id                       Version Available Source
----------------------------------------------------------------------
Cisco Webex Meetings Cisco.CiscoWebexMeetings 45.6.4  45.6.4.8  winget
uv                   astral-sh.uv             0.11.19 0.12.7    winget
2 upgrades available.
'@
    }

    It 'finds both rows' {
        @(Get-WingetUpgradeTable -Text $script:RealTable) | Should-BeCollection -Count 2
    }

    It 'reads the ids' {
        $ids = @(Get-WingetUpgradeTable -Text $script:RealTable).Id
        $ids | Should-ContainCollection 'astral-sh.uv'
        $ids | Should-ContainCollection 'Cisco.CiscoWebexMeetings'
    }

    It 'reads the installed and available versions' {
        $uv = @(Get-WingetUpgradeTable -Text $script:RealTable) | Where-Object { $_.Id -eq 'astral-sh.uv' }
        $uv.Version   | Should-Be '0.11.19'
        $uv.Available | Should-Be '0.12.7'
    }

    It 'keeps a name that contains spaces in one piece' {
        $webex = @(Get-WingetUpgradeTable -Text $script:RealTable) | Where-Object { $_.Id -like 'Cisco*' }
        $webex.Name | Should-Be 'Cisco Webex Meetings'
    }

    # "2 upgrades available." is winget's own summary, localised, and not a row.
    It 'stops at the blank line rather than reading the summary as a package' {
        @(Get-WingetUpgradeTable -Text $script:RealTable).Id | Should-NotContainCollection '2'
    }

    # The header row is the only part of the table that is English here. Anchor
    # on the dashes and the column positions, and a German or Japanese console
    # parses the same.
    It 'parses a table whose headers are not English' {
        $localised = @'
Name                 Kennung                  Version Verfuegbar Quelle
-----------------------------------------------------------------------
uv                   astral-sh.uv             0.11.19 0.12.7     winget
'@
        (Get-WingetUpgradeTable -Text $localised).Id | Should-Be 'astral-sh.uv'
    }

    It 'returns nothing when there is no table' {
        Get-WingetUpgradeTable -Text 'No installed package found matching input criteria.' | Should-BeNull
    }

    It 'returns nothing for empty input' {
        Get-WingetUpgradeTable -Text '' | Should-BeNull
        Get-WingetUpgradeTable -Text $null | Should-BeNull
    }
}

Describe 'Get-WingetLeftover' -Tag 'Unit' {

    # The two outcomes that need different answers. From the run this came from:
    # uv was attempted and failed on a file in use, Webex was listed and never
    # attempted because the newer package does not apply to that system. One
    # exit code covered both.

    BeforeAll {
        $script:Before = @(
            [pscustomobject]@{ Name = 'Cisco Webex Meetings'; Id = 'Cisco.CiscoWebexMeetings'; Version = '45.6.4'; Available = '45.6.4.8' }
            [pscustomobject]@{ Name = 'uv'; Id = 'astral-sh.uv'; Version = '0.11.19'; Available = '0.12.7' }
        )

        # Trimmed from the real transcript. The "Found ... [id]" line is what
        # winget writes when it begins a package, and is the only reliable
        # signal that one was attempted.
        $script:Output = @'
Cisco Webex Meetings Cisco.CiscoWebexMeetings 45.6.4  45.6.4.8  winget
uv                   astral-sh.uv             0.11.19 0.12.7    winget
2 upgrades available.
(1/1) Found uv [astral-sh.uv] Version 0.12.7
Successfully verified installer hash
Starting package install...
An unexpected error occurred while executing the command:
remove: Access is denied.: "C:\...\WinGet\Packages\astral-sh.uv_...\uv.exe"
'@
    }

    It 'reports both packages that are still listed' {
        @(Get-WingetLeftover -Before $script:Before -After $script:Before -Output $script:Output) |
            Should-BeCollection -Count 2
    }

    It 'marks the one winget named as attempted' {
        $uv = @(Get-WingetLeftover -Before $script:Before -After $script:Before -Output $script:Output) |
            Where-Object { $_.Id -eq 'astral-sh.uv' }
        $uv.Attempted | Should-BeTrue
    }

    # Webex appears in the upgrade table inside the same output, so a plain
    # substring search would call it attempted. Only the "[id]" marker counts.
    It 'does not mistake a table row for an attempt' {
        $webex = @(Get-WingetLeftover -Before $script:Before -After $script:Before -Output $script:Output) |
            Where-Object { $_.Id -eq 'Cisco.CiscoWebexMeetings' }
        $webex.Attempted | Should-BeFalse
    }

    It 'names a file in use as something the reader can act on' {
        $uv = @(Get-WingetLeftover -Before $script:Before -After $script:Before -Output $script:Output) |
            Where-Object { $_.Id -eq 'astral-sh.uv' }
        $uv.Reason | Should-MatchString 'in use'
    }

    It 'says a skipped package is expected to stay that way' {
        $webex = @(Get-WingetLeftover -Before $script:Before -After $script:Before -Output $script:Output) |
            Where-Object { $_.Id -eq 'Cisco.CiscoWebexMeetings' }
        $webex.Reason | Should-MatchString 'does not apply'
    }

    It 'reports nothing when everything upgraded' {
        Get-WingetLeftover -Before $script:Before -After @() -Output $script:Output | Should-BeNull
    }

    It 'carries the versions through for the report' {
        $uv = @(Get-WingetLeftover -Before $script:Before -After $script:Before -Output $script:Output) |
            Where-Object { $_.Id -eq 'astral-sh.uv' }
        $uv.Version   | Should-Be '0.11.19'
        $uv.Available | Should-Be '0.12.7'
    }

    It 'tells a newly listed package apart from a skipped one' {
        $extra = [pscustomobject]@{ Name = 'New App'; Id = 'New.New'; Version = '1.0'; Available = '1.1' }
        $rows = @(Get-WingetLeftover -Before $script:Before -After (@($script:Before) + $extra) -Output $script:Output)

        @($rows | Where-Object { $_.Id -eq 'New.New' }).Listed | Should-BeFalse
        @($rows | Where-Object { $_.Id -eq 'Cisco.CiscoWebexMeetings' }).Listed | Should-BeTrue
    }
}

Describe 'Errors reach the person watching the run' -Tag 'Unit' {

    # An error is transcribed twice: once when PowerShell raises it, once when
    # the step pipeline displays it. Investigated under #49 and left alone, and
    # this is the test that stops it being "tidied up" later.
    #
    # Measured, counting a marker in the error text:
    #
    #             console   transcript
    #   as it is  visible       2
    #   filtered  NOTHING       1
    #
    # The raise-time transcript entry comes with no console rendering, so
    # dropping the displayed copy would make every error invisible to whoever is
    # watching -- silently, and only noticed the next time somebody needed to see
    # one. Two lines in a log is the cheaper problem.

    BeforeEach {
        $script:logDir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $script:logDir -Force
        $script:runStamp = 'err'
        $script:isAdmin = $true
        $script:Results = [System.Collections.Generic.List[object]]::new()
        $script:TagFilter = @()
        $script:ExcludeTagFilter = @()
    }

    It 'does not filter error records out of what it displays' {
        $source = Get-Content `
            (Join-Path (Split-Path $PSScriptRoot -Parent) 'src\Private\Invoke-Step.ps1') -Raw

        $source | Should-NotMatchString 'isnot \[System\.Management\.Automation\.ErrorRecord\]'
    }

    It 'writes the error text to the step log, which is the single-copy record' {
        Invoke-Step -Name 'noisy' -Action { Write-Error 'SINGLECOPYMARKER' } 6>$null

        $log = Get-Content (Join-Path $script:logDir 'noisy-err.log') -Raw
        ([regex]::Matches($log, 'SINGLECOPYMARKER')).Count | Should-Be 1
    }

    It 'counts the error once, whatever the transcript shows' {
        Invoke-Step -Name 'counted' -Action { Write-Error 'x' } 6>$null

        $script:Results[0].Status | Should-Be 'Warning'
    }
}

Describe 'The pip step' -Tag 'Static' {

    BeforeAll {
        $script:PipSource = Get-Content `
            (Join-Path (Split-Path $PSScriptRoot -Parent) 'src\Public\Update-Everything.ps1') -Raw

        $script:PipStep = [regex]::Match($script:PipSource,
            "(?s)Invoke-Step -Name 'pip'.*?\r?\n    \}").Value
    }

    It 'exists and is tagged Python' {
        $script:PipStep | Should-NotBeEmptyString
        $script:PipStep | Should-MatchString "-Tag 'Python'"
    }

    # An active virtualenv is the easiest interpreter to reach from a step and
    # the worst one to change: its packages belong to whatever project made it.
    It 'refuses to touch an active virtual environment' {
        $script:PipStep | Should-MatchString '\$env:VIRTUAL_ENV'
        $script:PipStep | Should-MatchString 'Stop-StepAsSkipped'
    }

    # On Windows pip cannot replace its own running executable, so
    # "pip install --upgrade pip" fails on a locked file. Through the
    # interpreter, the exe is not running. Same shape as the winget/uv failure
    # that prompted this module's leftover reporting.
    It 'upgrades through the interpreter, not the bare pip executable' {
        $script:PipStep | Should-MatchString '-m pip install --upgrade pip'
        $script:PipStep | Should-NotMatchString '(?m)^\s*pip install --upgrade'
    }

    # pip has no upgrade-all, and list-outdated-then-upgrade-each does not keep
    # the dependency set consistent. That is the problem pipx and uv solve by
    # isolating, and both have their own steps.
    It 'does not try to upgrade installed packages' {
        $script:PipStep | Should-NotMatchString 'list --outdated'
        $script:PipStep | Should-NotMatchString 'freeze'
    }

    It 'names the other interpreters rather than changing them' {
        $script:PipStep | Should-MatchString 'were not changed'
    }

    # No -RequiresCommand, because either py or python will do, so the step has
    # to resolve its own tool and skip explicitly when neither is there.
    It 'skips itself when no interpreter is present' {
        $script:PipStep | Should-MatchString 'no Python interpreter is on PATH'
    }

    It 'skips itself when the interpreter has no pip' {
        $script:PipStep | Should-MatchString 'pip is not available to'
    }

    It 'runs before pipx, which depends on a working Python' {
        $pip  = $script:PipSource.IndexOf("Invoke-Step -Name 'pip'")
        $pipx = $script:PipSource.IndexOf("Invoke-Step -Name 'pipx packages'")

        $pip | Should-BeGreaterThan -1
        $pip | Should-BeLessThan $pipx
    }
}

Describe 'pip is in the inventory' -Tag 'Unit' {

    It 'is one of the tools reported' {
        $catalogue = @(Get-UpdateToolInventory -Catalogue @(
            @{ Name = 'pip'; Command = 'pip'; VersionArgument = '--version' }))

        $catalogue.Name | Should-Be 'pip'
    }

    It 'is in the real catalogue, so a machine with pip and no pipx says so' {
        $source = Get-Content `
            (Join-Path (Split-Path $PSScriptRoot -Parent) 'src\Private\Get-UpdateToolInventory.ps1') -Raw

        $source | Should-MatchString "Name = 'pip';"
    }
}

Describe 'Get-ElevationPolicyNote names a privilege broker' -Tag 'Unit' {

    # A broker can deny an elevation, or allow one application and refuse
    # another, without leaving anything in the registry, so a machine can refuse
    # while every policy value reads as permissive.
    #
    # Vendors are recognised by service name, so a vendor absent from the list is
    # not mentioned. Nothing is decided either way: the note only explains a
    # refusal that has already happened.

    BeforeEach {
        # Nothing restrictive in the registry, so only the broker can produce a
        # note. That is the case this exists for.
        Mock Get-ItemProperty { [pscustomobject]@{ EnableLUA = 1; ConsentPromptBehaviorAdmin = 2 } }
    }

    It 'names <_> when its service is running' -ForEach @(
        'Avecto Defendpoint Service'
        'BeyondTrust Privilege Management'
        'CyberArk Endpoint Privilege Manager'
        'AdminByRequest'
    ) {
        $display = $_
        Mock Get-Service { @([pscustomobject]@{ Name = 'svc'; DisplayName = $display; Status = 'Running' }) }

        Get-ElevationPolicyNote | Should-MatchString ([regex]::Escape($display))
    }

    It 'says a broker leaves nothing in the registry' {
        Mock Get-Service { @([pscustomobject]@{ Name = 'defendpoint'; DisplayName = 'Avecto Defendpoint Service'; Status = 'Running' }) }

        Get-ElevationPolicyNote | Should-MatchString 'leave nothing in the registry'
    }

    It 'ignores a broker service that is not running' {
        Mock Get-Service { @([pscustomobject]@{ Name = 'defendpoint'; DisplayName = 'Avecto Defendpoint Service'; Status = 'Stopped' }) }

        Get-ElevationPolicyNote | Should-BeNull
    }

    # "privilege" alone matches unrelated services, and a false positive here
    # sends somebody to their IT department over nothing.
    It 'does not match a service that merely contains the word privilege' {
        Mock Get-Service { @([pscustomobject]@{ Name = 'SeprivilegeHelper'; DisplayName = 'Some Privilege Helper'; Status = 'Running' }) }

        Get-ElevationPolicyNote | Should-BeNull
    }

    It 'says nothing on a machine with neither policy nor broker' {
        Mock Get-Service { @([pscustomobject]@{ Name = 'Spooler'; DisplayName = 'Print Spooler'; Status = 'Running' }) }

        Get-ElevationPolicyNote | Should-BeNull
    }

    It 'still reports a restrictive registry value with no broker present' {
        Mock Get-ItemProperty { [pscustomobject]@{ ConsentPromptBehaviorUser = 0 } }
        Mock Get-Service { @() }

        Get-ElevationPolicyNote | Should-MatchString 'ConsentPromptBehaviorUser'
    }

    It 'reports both when both are present' {
        Mock Get-ItemProperty { [pscustomobject]@{ ConsentPromptBehaviorUser = 0 } }
        Mock Get-Service { @([pscustomobject]@{ Name = 'x'; DisplayName = 'Avecto Defendpoint Service'; Status = 'Running' }) }

        $note = Get-ElevationPolicyNote
        $note | Should-MatchString 'ConsentPromptBehaviorUser'
        $note | Should-MatchString 'Avecto'
    }

    # Enumerating services can fail on a locked-down machine, and an explanation
    # that throws is worse than one that is missing.
    It 'survives being unable to enumerate services' {
        Mock Get-Service { throw 'access denied' }
        Mock Get-ItemProperty { [pscustomobject]@{ ConsentPromptBehaviorUser = 0 } }

        Get-ElevationPolicyNote | Should-MatchString 'ConsentPromptBehaviorUser'
    }
}
