#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '6.0' }

<#
    Static checks on the module itself: the manifest, what it exports, the shape
    of the source tree, and the contract of Update-Everything.

    Nothing here runs the module's work. Update-Everything elevates, installs
    software and can reboot the machine, so the suite inspects it through the
    AST and through Get-Command and Get-Help, which report a parameter block and
    help without executing a body.
#>

BeforeDiscovery {
    $RepoRoot   = Split-Path $PSScriptRoot -Parent
    $ModuleRoot = Join-Path $RepoRoot 'src'
    $Manifest   = Join-Path $ModuleRoot 'UpdateEverything.psd1'

    # -ForEach data is consumed during discovery, so it is built here.
    $ExpectedParameters = @(
        @{ Name = 'IncludeWindowsUpdate';      TypeName = 'bool';     Type = [bool];     Default = '$true' }
        @{ Name = 'IncludePowerShell7';        TypeName = 'bool';     Type = [bool];     Default = '$true' }
        @{ Name = 'SetPwshTerminalDefault';    TypeName = 'bool';     Type = [bool];     Default = '$true' }
        @{ Name = 'IncludePowerShellModules'; TypeName = 'bool';     Type = [bool];     Default = '$true' }
        @{ Name = 'AutoReboot';                TypeName = 'switch';   Type = [switch];   Default = $null }
        @{ Name = 'IncludePrerelease';         TypeName = 'switch';   Type = [switch];   Default = $null }
        @{ Name = 'UpdateGlobalNpm';           TypeName = 'switch';   Type = [switch];   Default = $null }
        @{ Name = 'SkipElevation';             TypeName = 'switch';   Type = [switch];   Default = $null }
        @{ Name = 'Notify';                    TypeName = 'switch';   Type = [switch];   Default = $null }
        @{ Name = 'AllowInstall';              TypeName = 'string[]'; Type = [string[]]; Default = '@()' }
        @{ Name = 'Tag';                       TypeName = 'string[]'; Type = [string[]]; Default = '@()' }
        @{ Name = 'ExcludeTag';                TypeName = 'string[]'; Type = [string[]]; Default = '@()' }
        @{ Name = 'PromptBeforeRun';           TypeName = 'switch';   Type = [switch];   Default = $null }
        @{ Name = 'PromptTimeoutSeconds';      TypeName = 'int';      Type = [int];      Default = '60' }
        @{ Name = 'DelayMinutes';              TypeName = 'int';      Type = [int];      Default = '60' }
        @{ Name = 'LogRetentionDays';          TypeName = 'int';      Type = [int];      Default = '30' }
        @{ Name = 'UpdateSelf';                TypeName = 'switch';   Type = [switch];   Default = $null }
        @{ Name = 'UpdateSelfSource';          TypeName = 'string';   Type = [string];   Default = "'Gallery'" }
    )

    # Each of these either reboots the machine, moves pinned toolchains, or
    # reaches out to the gallery, so turning one on has to be deliberate.
    $DefaultOffSwitches = @(
        'AutoReboot', 'IncludePrerelease', 'UpdateGlobalNpm', 'SkipElevation',
        'Notify', 'PromptBeforeRun', 'UpdateSelf'
    )

    # Steps that cannot work unelevated, and so must carry -RequiresAdmin.
    $AdminOnlySteps = @('Windows Update', 'Defender signatures', 'PowerShell 7 (latest)')

    $ExportedFunctions = @(
        'Update-Everything'
        'Initialize-UpdateEverything'
        'Register-UpdateEverythingTask'
        'Unregister-UpdateEverythingTask'
        'Get-UpdateEverythingTask'
        'Test-PendingReboot'
    )

    $HasAnalyzer = [bool] (Get-Module PSScriptAnalyzer -ListAvailable)

    $LintTargets = @(Get-ChildItem -Path (Join-Path $ModuleRoot 'Public'), (Join-Path $ModuleRoot 'Private') -Filter *.ps1 |
            ForEach-Object { $_.FullName })
    $LintTargets += (Join-Path $ModuleRoot 'UpdateEverything.psm1')
    $LintTargets += (Join-Path $RepoRoot 'test.ps1')
    $LintTargets += (Join-Path $RepoRoot 'Install.ps1')
    $LintTargets += (Join-Path $RepoRoot 'Convert-PowerShell7ToMsi.ps1')

    # Everything under tests\: the test files, and the fresh-machine and
    # elevation harnesses. Pester runs *.Tests.ps1 and nothing runs the
    # harnesses, so for the harnesses the analyzer is the only reader they have.
    $LintTargets += @(Get-ChildItem -Path (Join-Path $RepoRoot 'tests') -Filter *.ps1 -Recurse -ErrorAction SilentlyContinue |
            ForEach-Object { $_.FullName })
}

BeforeAll {
    $script:RepoRoot   = Split-Path $PSScriptRoot -Parent
    $script:ModuleRoot = Join-Path $script:RepoRoot 'src'
    $script:Manifest   = Join-Path $script:ModuleRoot 'UpdateEverything.psd1'
    $script:MainPath   = Join-Path $script:ModuleRoot 'Public\Update-Everything.ps1'

    Import-Module $script:Manifest -Force

    $script:Ast = [System.Management.Automation.Language.Parser]::ParseFile(
        $script:MainPath, [ref] $null, [ref] $null)

    $script:MainFunction = $script:Ast.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq 'Update-Everything'
        }, $true) | Select-Object -First 1

    $script:DeclaredParameters = $script:MainFunction.Body.ParamBlock.Parameters

    # Every Invoke-Step call with the switches it was given.
    $script:StepCalls = $script:Ast.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.CommandAst] -and
            $node.GetCommandName() -eq 'Invoke-Step'
        }, $true) | ForEach-Object {
        $elements = $_.CommandElements
        $name = $null
        $requiresAdmin = $false
        for ($i = 0; $i -lt $elements.Count; $i++) {
            if ($elements[$i] -isnot [System.Management.Automation.Language.CommandParameterAst]) { continue }
            switch ($elements[$i].ParameterName) {
                'Name'          { if ($i + 1 -lt $elements.Count) { $name = $elements[$i + 1].Value } }
                'RequiresAdmin' { $requiresAdmin = $true }
            }
        }
        [pscustomobject]@{ Name = $name; RequiresAdmin = $requiresAdmin }
    }

    $script:StepNames = $script:StepCalls.Name
    $script:Readme = Get-Content (Join-Path $script:RepoRoot 'README.md') -Raw
}

AfterAll {
    Remove-Module UpdateEverything -Force -ErrorAction SilentlyContinue
}

Describe 'Module manifest' -Tag 'Static','Module' {

    It 'is a valid manifest' {
        # Test-ModuleManifest throws on a malformed manifest, so reaching the
        # assertion at all is most of the test.
        $data = Test-ModuleManifest -Path $script:Manifest -ErrorAction Stop
        $data.Name | Should-Be 'UpdateEverything'
    }

    It 'names the psm1 as its root module' {
        (Import-PowerShellDataFile $script:Manifest).RootModule | Should-Be 'UpdateEverything.psm1'
    }

    # 5.1 because the script this grew from always supported Windows PowerShell,
    # and a tool for updating a machine is least useful if it cannot run on one
    # that has not been updated yet.
    It 'still supports Windows PowerShell 5.1' {
        (Import-PowerShellDataFile $script:Manifest).PowerShellVersion | Should-Be '5.1'
    }

    It 'declares a GUID' {
        (Import-PowerShellDataFile $script:Manifest).GUID | Should-NotBeEmptyString
    }

    It 'points at the project and its licence' {
        $data = (Import-PowerShellDataFile $script:Manifest).PrivateData.PSData
        $data.ProjectUri | Should-MatchString 'github.com'
        $data.LicenseUri | Should-MatchString 'LICENSE'
    }

    # An empty export list makes a module import cleanly and do nothing, which is
    # a confusing way to fail.
    It 'exports <_>' -ForEach $ExportedFunctions {
        (Import-PowerShellDataFile $script:Manifest).FunctionsToExport | Should-ContainCollection $_
    }

    It 'exports nothing the manifest does not list' {
        $declared = (Import-PowerShellDataFile $script:Manifest).FunctionsToExport
        $actual = (Get-Command -Module UpdateEverything -CommandType Function).Name

        $extra = $actual | Where-Object { $_ -notin $declared }
        $extra | Should-BeNull -Because "these are exported but unlisted: $($extra -join ', ')"
    }

    It 'keeps every private function private' {
        $exported = (Get-Command -Module UpdateEverything -CommandType Function).Name
        $private = (Get-ChildItem (Join-Path $script:ModuleRoot 'Private') -Filter *.ps1).BaseName

        $leaked = $private | Where-Object { $_ -in $exported }
        $leaked | Should-BeNull -Because "these private helpers are exported: $($leaked -join ', ')"
    }
}

Describe 'Imports on both PowerShell editions' -Tag 'Module' {

    # The manifest promises 5.1, and the suite runs on 7, so nothing else here
    # would notice the module refusing to load on Windows PowerShell. It did:
    # the loader read [Environment]::OSVersion.Version and then asked it for
    # .Platform, which is always $null, and 5.1 has no $IsWindows to fall back
    # on. Shelling out is worth the second it costs.
    It 'imports under Windows PowerShell 5.1' -Skip:(-not (Get-Command powershell.exe -ErrorAction SilentlyContinue)) {
        $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -Command `
            "try { Import-Module '$($script:Manifest)' -Force -ErrorAction Stop; 'OK' } catch { 'FAILED: ' + `$_.Exception.Message }"

        ($output -join ' ') | Should-MatchString 'OK'
    }

    It 'imports under PowerShell 7' -Skip:(-not (Get-Command pwsh.exe -ErrorAction SilentlyContinue)) {
        $output = & pwsh.exe -NoProfile -Command `
            "try { Import-Module '$($script:Manifest)' -Force -ErrorAction Stop; 'OK' } catch { 'FAILED: ' + `$_.Exception.Message }"

        ($output -join ' ') | Should-MatchString 'OK'
    }
}

Describe 'Module source layout' -Tag 'Static','Module' {

    # The loader dot-sources Public and Private and exports $Public.BaseName, so
    # a file whose name does not match the function inside it exports nothing.
    It 'has one function per public file, named after the file' {
        $mismatched = foreach ($file in Get-ChildItem (Join-Path $script:ModuleRoot 'Public') -Filter *.ps1) {
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref] $null, [ref] $null)
            $names = $ast.FindAll({
                    param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst]
                }, $false).Name

            if ($names -notcontains $file.BaseName) {
                "$($file.Name) defines $($names -join ', ')"
            }
        }

        $mismatched | Should-BeNull
    }

    It 'has one function per private file, named after the file' {
        $mismatched = foreach ($file in Get-ChildItem (Join-Path $script:ModuleRoot 'Private') -Filter *.ps1) {
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref] $null, [ref] $null)
            $names = $ast.FindAll({
                    param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst]
                }, $false).Name

            if ($names -notcontains $file.BaseName) {
                "$($file.Name) defines $($names -join ', ')"
            }
        }

        $mismatched | Should-BeNull
    }

    # A module function that calls exit takes the caller's whole session with it.
    # Update-Everything used to do exactly that, as a script.
    It 'never calls exit, which would kill the calling session' {
        $offenders = foreach ($file in Get-ChildItem (Join-Path $script:ModuleRoot 'Public'), (Join-Path $script:ModuleRoot 'Private') -Filter *.ps1) {
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref] $null, [ref] $null)
            foreach ($stop in $ast.FindAll({
                        param($node) $node -is [System.Management.Automation.Language.ExitStatementAst]
                    }, $true)) {
                "$($file.Name):$($stop.Extent.StartLineNumber)"
            }
        }

        $offenders | Should-BeNull -Because "these would end the caller's session:`n$($offenders -join "`n")"
    }

    # Assigning $ErrorActionPreference inside a module changes the preference of
    # whoever imported it, and converts every later non-terminating error in that
    # scope whether or not that was wanted. The per-call -ErrorAction Stop next to
    # the try/catch is the version that only affects the call it is on.
    # Install.ps1, Publish.ps1 and test.ps1 do set it. They own their session.
    #
    # Invoke-Step is the documented exception, and only for a function-local
    # assignment. It sets Continue before invoking a step action, in the other
    # direction: a caller that prefers Stop makes a native command's stderr
    # terminating, and most steps drive tools that write to stderr routinely, so
    # each would throw before reaching the exit-code check written to handle it.
    # A function-local assignment cannot reach the caller's session, which is what
    # this rule protects.
    It 'never assigns $ErrorActionPreference, which belongs to the caller' {
        $localAllowed = 'Invoke-Step.ps1'

        $offenders = foreach ($file in Get-ChildItem (Join-Path $script:ModuleRoot 'Public'), (Join-Path $script:ModuleRoot 'Private') -Filter *.ps1) {
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref] $null, [ref] $null)
            foreach ($assignment in $ast.FindAll({
                        param($node)
                        $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
                        $node.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and
                        $node.Left.VariablePath.UserPath -match '^(global:|script:)?ErrorActionPreference$'
                    }, $true)) {

                $scoped = $assignment.Left.VariablePath.UserPath -match '^(global:|script:)'
                if (-not $scoped -and $file.Name -eq $localAllowed) { continue }

                "$($file.Name):$($assignment.Extent.StartLineNumber)"
            }
        }

        $offenders | Should-BeNull -Because "these change the importing session's preference:`n$($offenders -join "`n")"
    }

    # The allowance above is for a function-local assignment only. A global: or
    # script: one leaks to the caller wherever it is written, including here.
    It 'never assigns it at global or script scope, not even where local is allowed' {
        $offenders = foreach ($file in Get-ChildItem (Join-Path $script:ModuleRoot 'Public'), (Join-Path $script:ModuleRoot 'Private') -Filter *.ps1) {
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref] $null, [ref] $null)
            foreach ($assignment in $ast.FindAll({
                        param($node)
                        $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
                        $node.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and
                        $node.Left.VariablePath.UserPath -match '^(global:|script:)ErrorActionPreference$'
                    }, $true)) {
                "$($file.Name):$($assignment.Extent.StartLineNumber)"
            }
        }

        $offenders | Should-BeNull
    }

    # A catch that swallows in silence is indistinguishable from one that never
    # ran. Six of these were hiding a failed Stop-Transcript, an encoding that
    # would not restore, and an unreadable registry key -- on every run.
    # Say what was ignored, so -Verbose can show it.
    It 'never swallows an error in silence' {
        $offenders = foreach ($file in Get-ChildItem (Join-Path $script:ModuleRoot 'Public'), (Join-Path $script:ModuleRoot 'Private') -Filter *.ps1) {
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref] $null, [ref] $null)
            foreach ($try in $ast.FindAll({
                        param($node) $node -is [System.Management.Automation.Language.TryStatementAst]
                    }, $true)) {
                foreach ($clause in $try.CatchClauses) {
                    # Statements, not text: a catch holding only a comment parses
                    # to an empty body and is just as silent as an empty one.
                    if ($clause.Body.Statements.Count -eq 0) {
                        "$($file.Name):$($clause.Extent.StartLineNumber)"
                    }
                }
            }
        }

        $offenders | Should-BeNull -Because "these swallow an error without saying so:`n$($offenders -join "`n")"
    }
}

Describe 'Shared run state' -Tag 'Static','Module' {

    # As a script, $logDir and friends sat at script scope, so the private
    # helpers reading $script:logDir saw the same variable. Inside a module a
    # plain assignment is function-scoped and $script: means module scope, so
    # the helpers read $null and every step failed on Join-Path. The suite did
    # not notice, because the behavioural tests set $script:logDir themselves.
    It 'assigns <_> at module scope, where the private helpers read it' -ForEach @(
        'isAdmin', 'logDir', 'runStamp', 'Results'
    ) {
        $name = $_
        $source = Get-Content (Join-Path $script:ModuleRoot 'Public\Update-Everything.ps1') -Raw

        $unqualified = [regex]::Matches($source, "(?m)^\s*\`$$name\s*=")
        $unqualified.Count | Should-Be 0 -Because "a plain `$$name assignment is function-scoped, so `$script:$name stays unset"

        $source | Should-MatchString ([regex]::Escape('$script:' + $name) + '\s*=')
    }

    It 'reads no module-scope name the entry point never sets' {
        $publicSource = Get-Content (Join-Path $script:ModuleRoot 'Public\Update-Everything.ps1') -Raw

        $privateSource = (Get-ChildItem (Join-Path $script:ModuleRoot 'Private') -Filter *.ps1 |
            Get-Content -Raw) -join "`n"

        $read = [regex]::Matches($privateSource, '\$script:(\w+)') |
            ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique

        # ModuleRoot is set by the loader rather than by Update-Everything.
        $set = @('ModuleRoot') + ([regex]::Matches($publicSource, '\$script:(\w+)\s*=') |
            ForEach-Object { $_.Groups[1].Value })

        $orphans = $read | Where-Object { $_ -notin $set }
        $orphans | Should-BeNull -Because "these read as `$null at run time: $($orphans -join ', ')"
    }
}

Describe 'Logging starts before the run can decline to start' -Tag 'Static','Module' {

    # Logging is set up before elevation is attempted, so a path that ends the
    # run early still leaves a log behind. A PowerShell 7 run that cannot
    # elevate is exactly the case someone goes looking for a log to explain.

    BeforeAll {
        $script:Source = Get-Content $script:MainPath -Raw

        $script:LineOf = {
            param($pattern)
            ($script:Source -split "`r?`n" | Select-String -Pattern $pattern |
                Select-Object -First 1).LineNumber
        }

        # The handoff assertions are bounded structurally rather than by
        # proximity. Taking the first Stop-Transcript in the file would find the
        # one in the "cannot elevate" return, which sits earlier and is before
        # the handoff for reasons that have nothing to do with this rule --
        # green for the wrong reason.
        $lines = $script:Source -split "`r?`n"
        $hand  = ($lines | Select-String -Pattern 'Invoke-SelfElevation -BoundParameters' |
            Select-Object -First 1).LineNumber

        # Starts after the "cannot elevate" return, not at the elevation test.
        # That branch has a Stop-Transcript of its own, and including it made the
        # close assertion pass against code that never closed anything before the
        # handoff -- verified by running it against the previous implementation.
        $open  = ($lines | Select-String -Pattern '-Ran \$false -Reason \$elevation\.Reason' |
            Select-Object -First 1).LineNumber
        $close = ($lines | Select-String -Pattern '-Ran \$false -Elevated' | Select-Object -First 1).LineNumber

        $script:BeforeHandoff = ($lines[($open - 1)..($hand - 1)]) -join "`n"
        $script:AfterHandoff  = ($lines[($hand - 1)..($close - 1)]) -join "`n"
    }

    It 'starts the transcript before testing whether it can elevate' {
        $transcript = & $script:LineOf 'Start-Transcript'
        $elevation  = & $script:LineOf 'Test-ElevationCapability'

        $transcript | Should-BeLessThan $elevation
    }

    It 'resolves the log directory before testing whether it can elevate' {
        $logDir    = & $script:LineOf '\$script:logDir\s*=\s*Get-UpdateLogDirectory'
        $elevation = & $script:LineOf 'Test-ElevationCapability'

        $logDir | Should-BeLessThan $elevation
    }

    It 'starts the transcript before handing off to an elevated child' {
        $transcript = & $script:LineOf 'Start-Transcript'
        $elevate    = & $script:LineOf 'Invoke-SelfElevation'

        $transcript | Should-BeLessThan $elevate
    }

    # Opening a transcript and returning without closing it leaves it running in
    # the caller's session, where it silently records everything they do next.
    It 'stops the transcript on every early return' {
        $starts = ([regex]::Matches($script:Source, 'Start-Transcript')).Count
        $stops  = ([regex]::Matches($script:Source, 'Stop-Transcript')).Count

        $stops | Should-BeGreaterThanOrEqual 3 -Because "one per early return plus the normal end; found $starts start(s) and $stops stop(s)"
    }

    # Two processes with the same transcript open at once is not benign, and it
    # fails silently: the child's Start-Transcript -Append reports success and
    # its content is then lost. Measured, a child needs ~1.7s to start and import
    # before it stamps, so the one-second stamps differ today -- but that is a
    # timing margin that narrows on faster hardware, and it guards the loss of
    # the elevated run's transcript. So the parent does not overlap it at all.
    It 'closes the transcript before handing off to the child' {
        $script:BeforeHandoff |
            Should-MatchString 'Stop-Transcript' -Because 'the child opens its own transcript on a path that can collide with this one'
    }

    It 'reopens the transcript after the child returns' {
        $script:AfterHandoff |
            Should-MatchString 'Start-Transcript' -Because 'the outcome still has to be recorded'
    }

    # Losing this would leave a hung child with no explanation anywhere.
    It 'names where the real work will be logged before closing' {
        $script:BeforeHandoff | Should-MatchString 'Handing off to an elevated run'
    }

    # Reporting it from inside Invoke-SelfElevation would put the line on the
    # console while the transcript is closed, so an unattended run would lose it.
    It 'reports the elevated outcome from the caller' {
        $script:AfterHandoff | Should-MatchString 'Elevated run finished with exit code'
    }

    It 'does not also report it from inside Invoke-SelfElevation' {
        Get-Content (Join-Path $script:ModuleRoot 'Private\Invoke-SelfElevation.ps1') -Raw |
            Should-NotMatchString 'Write-Host "Elevated run finished'
    }

    It 'reports the log location even when nothing ran' {
        # Both early returns take -LogDirectory now, so the caller can find the
        # transcript that explains the refusal.
        $script:Source | Should-MatchString '-Ran \$false -Reason \$elevation\.Reason `\r?\n\s*-LogDirectory \$logDir -MainLog \$mainLog'
    }
}

Describe 'Update-Everything' -Tag 'Static' {

    Context 'Parameter contract' {

        It 'declares -<Name> as <TypeName>' -ForEach $ExpectedParameters {
            Get-Command Update-Everything | Should-HaveParameter -ParameterName $Name -Type $Type
        }

        It 'defaults -<Name> to <Default>' -ForEach ($ExpectedParameters | Where-Object Default) {
            $declared = $script:DeclaredParameters |
                Where-Object { $_.Name.VariablePath.UserPath -eq $Name }

            $declared.DefaultValue.Extent.Text | Should-Be $Default
        }

        It 'leaves -<_> off unless explicitly passed' -ForEach $DefaultOffSwitches {
            # Capture the -ForEach item first. Inside Where-Object, $_ rebinds to
            # the pipeline element, and comparing against that matches nothing,
            # which would make this pass vacuously.
            $switchName = $_

            $declared = $script:DeclaredParameters |
                Where-Object { $_.Name.VariablePath.UserPath -eq $switchName }

            $declared | Should-NotBeNull -Because "-$switchName should still exist"
            $declared.DefaultValue | Should-BeNull -Because 'switches must stay opt-in'
        }

        It 'declares no parameters beyond the documented contract' {
            $script:DeclaredParameters.Name.VariablePath.UserPath |
                Should-BeCollection -Count 18 -Because 'a new parameter needs docs and a test'
        }

        It 'bounds -LogRetentionDays with ValidateRange' {
            $declared = $script:DeclaredParameters |
                Where-Object { $_.Name.VariablePath.UserPath -eq 'LogRetentionDays' }

            $declared.Attributes.TypeName.Name | Should-ContainCollection 'ValidateRange'
        }
    }

    Context 'Returns rather than exits' {

        It 'is documented as returning an object' {
            (Get-Help Update-Everything).returnValues | Out-String | Should-MatchString 'FailedCount'
        }

        It 'builds its result through one helper' {
            # Counts derived in one place cannot disagree with the records they
            # describe.
            $script:Ast.Extent.Text | Should-MatchString 'New-UpdateEverythingResult'
        }
    }

    Context 'Comment-based help' {

        It 'has a synopsis' {
            (Get-Help Update-Everything).Synopsis | Should-NotBeEmptyString
        }

        It 'documents -<Name>' -ForEach $ExpectedParameters {
            (Get-Help Update-Everything).parameters.parameter.name |
                Should-ContainCollection $Name -Because 'undocumented parameters drift into surprises'
        }

        It 'has a description' {
            (Get-Help Update-Everything).description |
                Out-String | Should-NotBeEmptyString
        }

        # A line whose first non-space character is a dot is read as a help
        # keyword, whatever word follows it. ".NET global tools" wrapped to the
        # start of a line ends the section it sits in and silently discards
        # every section after it -- Get-Help reports no error, it just returns
        # empty descriptions and outputs.
        It 'starts no help line with a dot that is not a help keyword' {
            $keywords = 'SYNOPSIS', 'DESCRIPTION', 'PARAMETER', 'EXAMPLE', 'INPUTS',
                        'OUTPUTS', 'NOTES', 'LINK', 'COMPONENT', 'ROLE',
                        'FUNCTIONALITY', 'FORWARDHELPTARGETNAME',
                        'FORWARDHELPCATEGORY', 'REMOTEHELPRUNSPACE', 'EXTERNALHELP'

            $offenders = foreach ($file in Get-ChildItem $script:ModuleRoot -Recurse -Filter *.ps1) {
                $text = Get-Content -LiteralPath $file.FullName -Raw
                foreach ($block in [regex]::Matches($text, '(?s)<#(.*?)#>')) {
                    foreach ($line in $block.Groups[1].Value -split "`r?`n") {
                        if ($line -match '^\s*\.([A-Za-z]\w*)' -and $Matches[1].ToUpperInvariant() -notin $keywords) {
                            "$($file.Name): $($line.Trim())"
                        }
                    }
                }
            }

            $offenders | Should-BeNull -Because "these silently truncate comment-based help:`n$($offenders -join "`n")"
        }
    }

    Context 'Step definitions' {

        It 'defines every update step through Invoke-Step' {
            $script:StepNames.Count | Should-BeGreaterThan 10
        }

        It 'gives every step a unique name' {
            # Step names become log file names, so duplicates overwrite each other.
            $duplicates = $script:StepNames |
                Group-Object |
                Where-Object Count -gt 1 |
                Select-Object -ExpandProperty Name

            $duplicates | Should-BeNull -Because "these step names repeat: $($duplicates -join ', ')"
        }

        It 'marks <_> as requiring administrator' -ForEach $AdminOnlySteps {
            $stepName = $_
            $call = $script:StepCalls | Where-Object { $_.Name -eq $stepName }

            $call | Should-NotBeNull -Because "the step '$stepName' should still exist"
            $call.RequiresAdmin | Should-BeTrue -Because 'it cannot work unelevated'
        }
    }

    Context 'Transcript noise' {

        # Inside a step every stream is merged with *>&1, so a Write-Host line is
        # recorded twice: once when written, once when the merged record is
        # rendered as the step's output.
        It 'uses Write-Output inside step actions, not Write-Host' {
            $offenders = foreach ($call in $script:Ast.FindAll({
                        param($node)
                        $node -is [System.Management.Automation.Language.CommandAst] -and
                        $node.GetCommandName() -eq 'Invoke-Step'
                    }, $true)) {

                foreach ($write in $call.FindAll({
                            param($node)
                            $node -is [System.Management.Automation.Language.CommandAst] -and
                            $node.GetCommandName() -eq 'Write-Host'
                        }, $true)) {
                    "line $($write.Extent.StartLineNumber): $($write.Extent.Text)"
                }
            }

            $offenders | Should-BeNull -Because "these are logged twice:`n$($offenders -join "`n")"
        }

        # Select-Object -First stops the upstream pipeline, and inside a step the
        # transcript records the stop as a TerminatingError.
        It 'does not halt a pipeline inside a step action' {
            $offenders = foreach ($call in $script:Ast.FindAll({
                        param($node)
                        $node -is [System.Management.Automation.Language.CommandAst] -and
                        $node.GetCommandName() -eq 'Invoke-Step'
                    }, $true)) {

                $halts = $call.FindAll({
                        param($node)
                        $node -is [System.Management.Automation.Language.CommandAst] -and
                        $node.GetCommandName() -eq 'Select-Object' -and
                        ($node.CommandElements | Where-Object {
                            $_ -is [System.Management.Automation.Language.CommandParameterAst] -and
                            $_.ParameterName -eq 'First'
                        })
                    }, $true)

                if ($halts) { "line $($call.Extent.StartLineNumber)" }
            }

            $offenders | Should-BeNull
        }
    }
}

Describe 'Repository documentation' -Tag 'Docs' {

    # The count comes from the function rather than a live probe: with command
    # lookup shadowed to resolve nothing, every tool reports absent, no version
    # command executes, and one record per catalogue entry still comes out.
    It 'shows an inventory sample sized to the real catalogue' {
        $readme = Get-Content (Join-Path $script:RepoRoot 'README.md') -Raw
        $readme -match 'of (\d+) tools present' | Should-BeTrue
        [int]$documented = $Matches[1]

        $catalogue = & (Get-Module UpdateEverything) {
            function Get-Command { }
            Get-UpdateToolInventory
        }
        $documented | Should-Be @($catalogue).Count
    }

    It 'README documents -<Name>' -ForEach $ExpectedParameters {
        $script:Readme | Should-MatchString ([regex]::Escape("-$Name"))
    }

    It 'README documents <_>' -ForEach $ExportedFunctions {
        $script:Readme | Should-MatchString ([regex]::Escape($_))
    }

    It 'ships a LICENSE file' {
        Test-Path (Join-Path $script:RepoRoot 'LICENSE') | Should-BeTrue
    }

    It 'licenses under MIT' {
        Get-Content (Join-Path $script:RepoRoot 'LICENSE') -Raw | Should-MatchString 'MIT License'
    }

    It 'README points at the license' {
        $script:Readme | Should-MatchString '\(LICENSE\)'
    }

    It 'warns that there is no support' {
        $script:Readme | Should-MatchString '(?s)## Support'
    }

    It 'explains the execution policy trap' {
        $script:Readme | Should-MatchString 'ExecutionPolicy Bypass'
    }

    # PowerShell 7 is one of the things this module installs, so the install
    # instructions cannot require it to already be there. The documented command
    # ended in "pwsh -NoProfile ... -File $i", and on a machine with only
    # Windows PowerShell that is "The term 'pwsh' is not recognized" -- the
    # download succeeds and the install never happens, on exactly the machine
    # the instructions are written for.
    #
    # Scoped to the Install section and to lines that run a host against a
    # -File, so the Defender demonstration further down (which says pwsh to make
    # a point about process creation) and the developer test commands are left
    # alone.
    It 'gives an install command that runs on Windows PowerShell' {
        $section = [regex]::Match($script:Readme, '(?s)\n## Install\r?\n(.*?)\r?\n## ').Groups[1].Value
        $section | Should-NotBeEmptyString -Because 'the Install section should still be findable'

        $offenders = $section -split "`r?`n" |
            Where-Object { $_ -match '-File' -and $_ -match '\bpwsh\b' }

        $offenders | Should-BeNull -Because "pwsh does not exist until this module installs it:`n$($offenders -join "`n")"
    }

    # The module installs into a folder named for its version and the installer
    # refuses to overwrite one that exists. The version does not move with every
    # commit, so a second install from main is 1.0.0 over 1.0.0 and stops. A
    # documented command that works exactly once is worse than one that asks for
    # a flag, because it looks like the instructions are wrong.
    It 'gives an install command that can be run more than once' {
        $section = [regex]::Match($script:Readme, '(?s)\n## Install\r?\n(.*?)\r?\n## ').Groups[1].Value

        $installs = $section -split "`r?`n" |
            Where-Object { $_ -match 'powershell .*-File' }

        $installs | Should-NotBeNull -Because 'the Install section should still show how to run the installer'

        $unforced = $installs | Where-Object { $_ -notmatch '(?i)\s-Force\b' }
        $unforced | Should-BeNull -Because "these stop on a reinstall from main:`n$($unforced -join "`n")"
    }

    # -Force has to be an argument to the script, not part of its name. Written
    # as 'Install-UpdateEverything.ps1 -force' inside the quotes it becomes the
    # file name, and PowerShell then refuses the path for not ending in .ps1 --
    # after the download has already succeeded.
    It 'passes -Force to the installer rather than naming a file after it' {
        $script:Readme | Should-NotMatchString "Join-Path \`$env:TEMP '[^']*-[Ff]orce'"
    }

    # Written with StartsWith rather than a regex on purpose. The regex form
    # needed a backslash escaped through several layers of tooling, lost one on
    # the way, and silently matched nothing.
    It 'offers no example that a locked-down machine would refuse' {
        $offenders = $script:Readme -split "`r?`n" |
            Where-Object { $_.TrimStart().StartsWith('.\') -and $_ -match '\.ps1' }

        $offenders | Should-BeNull -Because "these are refused under AllSigned:`n$($offenders -join "`n")"
    }

    It 'documents no parameter the function no longer has' {
        $section = [regex]::Match(
            $script:Readme, '(?s)## Parameters\r?\n(.*?)\r?\n## ').Groups[1].Value

        $section | Should-NotBeEmptyString -Because 'the parameter table should still be findable'

        $documented = [regex]::Matches($section, '\| `-(\w+)`') |
            ForEach-Object { $_.Groups[1].Value }

        $real = (Get-Command Update-Everything).Parameters.Keys
        $ghosts = $documented | Where-Object { $_ -notin $real }

        $ghosts | Should-BeNull -Because "the function has no such parameter: $($ghosts -join ', ')"
    }
}

Describe 'Nothing shows a parameter the command does not have' -Tag 'Docs' {

    # The installer printed
    #
    #     Get-Help Update-Everything -Full
    #
    # which is a correct Get-Help call and reads as though -Full were a mode of
    # Update-Everything. Someone typed "update-everything -full" and got "A
    # parameter cannot be found that matches parameter name 'full'" from the
    # first command they ran after installing.
    #
    # Anything that follows the command name in text will be read as belonging
    # to it, whatever the parser thinks, so nothing that is not a real parameter
    # may sit there.

    BeforeAll {
        # Comments are not shown to anyone; Write-Host arguments are. Taking the
        # strings from the AST keeps an explanation of this very bug from
        # tripping it.
        $installPath = Join-Path $script:RepoRoot 'Install.ps1'
        $installAst = [System.Management.Automation.Language.Parser]::ParseFile(
            $installPath, [ref] $null, [ref] $null)

        $printed = $installAst.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.CommandAst] -and
                $node.GetCommandName() -in 'Write-Host', 'Write-Output'
            }, $true) | ForEach-Object {
            $_.CommandElements |
                Where-Object { $_ -is [System.Management.Automation.Language.StringConstantExpressionAst] } |
                ForEach-Object { $_.Value }
        }

        $aboutPath = Join-Path $script:ModuleRoot 'en-us\about_UpdateEverything.help.txt'

        $script:UserFacingText = @(
            ($printed -join "`n")
            $script:Readme
            (Get-Content $aboutPath -Raw)
        ) -join "`n"

        $script:RealParameters = (Get-Command Update-Everything).Parameters.Keys
    }

    It 'shows only real parameters after Update-Everything' {
        $offenders = foreach ($match in [regex]::Matches($script:UserFacingText, 'Update-Everything((?:\s+-[A-Za-z]\w*)+)')) {
            foreach ($p in [regex]::Matches($match.Groups[1].Value, '-([A-Za-z]\w*)')) {
                $name = $p.Groups[1].Value
                if ($name -notin $script:RealParameters) {
                    "-$name (in: $($match.Value -replace '\s+', ' '))"
                }
            }
        }

        $offenders | Should-BeNull -Because "these read as parameters of Update-Everything and are not:`n$($offenders -join "`n")"
    }

    # The command needs no arguments to do its work, and the installer used to
    # show only a help command and a cut-down run -- so the obvious question,
    # "how do I just run it", had no answer on screen.
    It 'tells a new user how to run everything' {
        ($printed -join "`n") | Should-MatchString '(?m)^\s*Update-Everything\s*$'
    }
}

Describe 'The Store-to-MSI mover' -Tag 'Static' {

    BeforeAll {
        $script:MoverSource = Get-Content `
            (Join-Path (Split-Path $PSScriptRoot -Parent) 'Convert-PowerShell7ToMsi.ps1') -Raw
    }

    # The Store package cannot remove the process it is hosting, and a packaged
    # pwsh cannot elevate.
    It 'refuses to run from a packaged host' {
        $script:MoverSource | Should-MatchString 'Test-PackagedHost'
        $script:MoverSource | Should-MatchString ([regex]::Escape("PSEdition -ne 'Desktop'"))
    }

    # winget's Microsoft.PowerShell has installed the MSIX package by default
    # since 7.6. Installing through it would hand back the thing being removed.
    It 'installs from the PowerShell release, never through winget' {
        $script:MoverSource | Should-MatchString 'repos/PowerShell/PowerShell/releases'
        $script:MoverSource | Should-NotMatchString 'winget install'
    }

    It 'verifies the MSI answers before the package is removed' {
        $verified = $script:MoverSource.IndexOf('did not answer; the Store package stays')
        $removed  = $script:MoverSource.IndexOf('Remove-AppxPackage')

        $verified | Should-BeGreaterThan -1
        $removed  | Should-BeGreaterThan $verified
    }

    # 5.1 does not offer TLS 1.2 to every endpoint by default, and the GitHub
    # API requires it.
    It 'speaks TLS 1.2 before asking the release API' {
        $script:MoverSource | Should-MatchString 'Tls12'
    }

    It 'backs settings.json up before pointing the default at the MSI profile' {
        $backupAt = $script:MoverSource.IndexOf('Copy-Item -LiteralPath $settingsPath')
        $writeAt  = $script:MoverSource.IndexOf('WriteAllText($settingsPath')

        $backupAt | Should-BeGreaterThan -1
        $writeAt  | Should-BeGreaterThan $backupAt
    }

    It 'reports scheduled tasks rather than editing them' {
        $script:MoverSource | Should-NotMatchString 'Set-ScheduledTask'
        $script:MoverSource | Should-NotMatchString 'Register-ScheduledTask'
    }

    It 'is documented in the README' {
        $script:Readme | Should-MatchString 'Convert-PowerShell7ToMsi'
    }
}

Describe 'Variable hygiene' -Tag 'Static' {

    # Set-StrictMode would catch undefined variable reads at run time, but it
    # also makes a missing property fatal, and the module legitimately probes for
    # optional keys in settings.json. Static analysis buys the useful half.
    It 'reads no variable it never assigns, in <_>' -ForEach @('Public', 'Private') {
        $folder = Join-Path (Join-Path (Split-Path $PSScriptRoot -Parent) 'src') $_

        $automatic = @(
            'true', 'false', 'null', '_', 'PSItem', 'args', 'input', 'this', 'PSCmdlet',
            'MyInvocation', 'PSScriptRoot', 'PSCommandPath', 'PID', 'Error', 'Matches',
            'LASTEXITCODE', 'PSVersionTable', 'ErrorActionPreference', 'ProgressPreference',
            'WarningPreference', 'VerbosePreference', 'InformationPreference', 'DebugPreference',
            'ConfirmPreference', 'WhatIfPreference', 'PWD', 'HOME', 'Host', 'ExecutionContext',
            'PSBoundParameters', 'PSDefaultParameterValues', 'IsWindows', 'IsLinux', 'IsMacOS',
            'IsCoreCLR', 'env', 'OutputEncoding', 'PSEdition', 'PSCulture', 'PSUICulture',
            'ShellId', 'NestedPromptLevel', 'StackTrace', 'switch', 'foreach',
            # Set by the module loader, and by the caller of a private helper.
            'ModuleRoot', 'Results', 'logDir', 'runStamp', 'isAdmin', 'InstallDecision',
            'NotificationsAvailable', 'WingetNothingToDo', 'TagFilter', 'ExcludeTagFilter'
        )

        $bare = { param($p) ($p -replace '^(script|global|local|private):', '') }

        $findings = foreach ($file in Get-ChildItem $folder -Filter *.ps1) {
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref] $null, [ref] $null)

            $defined = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
            foreach ($n in $ast.FindAll({ param($x) $x -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true)) {
                foreach ($v in $n.Left.FindAll({ param($x) $x -is [System.Management.Automation.Language.VariableExpressionAst] }, $true)) {
                    [void] $defined.Add((& $bare $v.VariablePath.UserPath))
                }
            }
            foreach ($n in $ast.FindAll({ param($x) $x -is [System.Management.Automation.Language.ParameterAst] }, $true)) {
                [void] $defined.Add((& $bare $n.Name.VariablePath.UserPath))
            }
            foreach ($n in $ast.FindAll({ param($x) $x -is [System.Management.Automation.Language.ForEachStatementAst] }, $true)) {
                [void] $defined.Add((& $bare $n.Variable.VariablePath.UserPath))
            }

            foreach ($v in $ast.FindAll({ param($x) $x -is [System.Management.Automation.Language.VariableExpressionAst] }, $true)) {
                $name = & $bare $v.VariablePath.UserPath
                if ($name -in $automatic) { continue }
                if ($v.VariablePath.IsDriveQualified) { continue }
                if ($defined.Contains($name)) { continue }
                "$($file.Name):$($v.Extent.StartLineNumber) `$$name"
            }
        }

        $unique = $findings | Sort-Object -Unique
        $unique | Should-BeNull -Because "a typo'd variable reads as `$null:`n$($unique -join "`n")"
    }
}

Describe 'PSScriptAnalyzer' -Tag 'Lint' -Skip:(-not $HasAnalyzer) {

    It 'reports no errors or warnings in <_>' -ForEach $LintTargets {
        $path = $_

        # Two rules a test file breaks by doing its job. Pester puts -ForEach
        # data in BeforeDiscovery variables the analyzer cannot see being
        # consumed, so every test file trips
        # PSUseDeclaredVarsMoreThanAssignments. Shadowing a cmdlet inside a
        # scoped scriptblock is how a test intercepts a call that Mock cannot
        # reach, which is what PSAvoidOverwritingBuiltInCmdlets is for.
        $extra = @{}
        if ($path -like '*\tests\*') {
            $extra['ExcludeRule'] = @(
                'PSUseDeclaredVarsMoreThanAssignments'
                'PSAvoidOverwritingBuiltInCmdlets'
            )
        }

        $findings = Invoke-ScriptAnalyzer -Path $path `
            -Settings (Join-Path (Split-Path $PSScriptRoot -Parent) 'PSScriptAnalyzerSettings.psd1') @extra

        $detail = ($findings | ForEach-Object { '{0}:{1} {2}' -f $_.RuleName, $_.Line, $_.Message }) -join "`n"
        # Counted rather than compared to null: a failed Should-BeNull prints the
        # whole DiagnosticRecord, burying the rule and line under the extents and
        # script positions hanging off it.
        @($findings).Count | Should-Be 0 -Because "the baseline is clean, so these are new:`n$detail"
    }
}

Describe 'The relaunch imports a manifest, not a folder' -Tag 'Static','Module' {

    # Import-Module given a directory looks for a manifest named after that
    # directory. An installed module sits in <name>\<version>, so pointing at
    # the folder sends it hunting for 1.0.0.psd1 and it reports "no valid module
    # file was found". Every scheduled run opened with that error. It carried on
    # only because invoking the function auto-loaded the module by name, which
    # also means the version that loaded was whichever the module path resolved.
    It 'builds a task command line that imports the .psd1' {
        $arguments = & (Get-Module UpdateEverything) {
            Get-UpdateTaskArgument -ModuleRoot 'C:\Modules\UpdateEverything\1.0.0'
        }

        $arguments | Should-MatchString ([regex]::Escape("Import-Module 'C:\Modules\UpdateEverything\1.0.0\UpdateEverything.psd1'"))
    }

    It 'never imports a bare directory' {
        $source = (Get-ChildItem (Join-Path $script:ModuleRoot 'Private') -Filter *.ps1 | Get-Content -Raw) -join "`n"

        $offenders = [regex]::Matches($source, 'Import-Module \$escModule') |
            ForEach-Object { $_.Value }

        # $escModule must have been built from a path ending in .psd1.
        $source | Should-MatchString "Join-Path .*ModuleRoot 'UpdateEverything\.psd1'"
    }
}

Describe 'The elevated relaunch runs a command that parses' -Tag 'Static','Module' {

    # It did not. The command was built as
    #
    #     exit (Import-Module '...' -Force; Update-Everything).FailedCount
    #
    # and parentheses in PowerShell hold an expression, not a statement list, so
    # that is "Missing closing ')' in expression". The elevated window opened,
    # pwsh exited 1 without running a line, and closed again before anyone could
    # read it -- no transcript, no error, nothing but an exit code. Every
    # non-elevated run hit it, which is to say every ordinary first run.
    #
    # Neither existing relaunch test noticed, because both check what the string
    # contains and neither asks whether it is valid PowerShell.

    BeforeAll {
        # The real function, with the launch mocked out. Building the string is
        # the part under test; starting a process is not.
        $script:Captured = & (Get-Module UpdateEverything) {
            $captured = $null
            $script:ModuleRoot = 'C:\Modules\UpdateEverything\1.0.0'

            function Start-Process {
                param(
                    $FilePath, $Verb, $ArgumentList, [switch] $PassThru, [switch] $Wait, $ErrorAction
                )
                $script:seen = $ArgumentList
                [pscustomobject]@{ ExitCode = 0 }
            }

            $null = Invoke-SelfElevation -BoundParameters ([ordered]@{
                Notify               = [switch]::Present
                IncludeWindowsUpdate = $false
                AllowInstall         = @('PSWindowsUpdate', 'BurntToast')
                PromptTimeoutSeconds = 90
            }) 6>$null 3>$null

            $script:seen
        }

        # The command line is not PowerShell; the string inside -Command is.
        $script:Command = if ($script:Captured -match '-Command\s+"(.*)"\s*$') { $Matches[1] } else { $null }
    }

    It 'passes a -Command string to the elevated host' {
        $script:Command | Should-NotBeNull
    }

    It 'builds a command with no parse errors' {
        $errors = $null
        $null = [System.Management.Automation.Language.Parser]::ParseInput(
            $script:Command, [ref] $null, [ref] $errors)

        $errors | Should-BeNull -Because "the elevated child exits 1 without running anything:`n$($errors.Message -join "`n")"
    }

    # The shape that parses: import as its own statement, then exit on the call
    # alone. Get-UpdateTaskArgument has always built the task command this way.
    It 'imports the module before the exit rather than inside it' {
        $script:Command | Should-MatchString "^Import-Module '[^']+\.psd1' -Force; exit \("
    }

    It 'still hands the caller parameters to the elevated run' {
        $script:Command | Should-MatchString ([regex]::Escape("-AllowInstall 'PSWindowsUpdate','BurntToast'"))
    }
}

Describe 'Enter takes the default' -Tag 'Unit','Prompt' {

    BeforeAll {
        $script:Timed = Get-Content (Join-Path (Join-Path (Split-Path $PSScriptRoot -Parent) 'src') 'Private\Read-TimedChoice.ps1') -Raw
    }

    # Waiting out the timeout already chooses the default, so the obvious
    # keypress meaning the same thing costs nothing and saves the wait.
    It 'treats VK_RETURN as the default choice' {
        $script:Timed | Should-MatchString 'VirtualKeyCode -eq 13'
    }

    # A host that reports no virtual key code still reports the character, so
    # both are checked.
    It 'also accepts a carriage return character' {
        $script:Timed | Should-MatchString '\$key\.Character -eq "`r"'
    }

    It 'maps Enter to DefaultIndex, not to a fixed option' {
        $script:Timed | Should-MatchString '(?s)VirtualKeyCode -eq 13.{0,120}\$DefaultIndex'
    }

    It 'tells the reader Enter is an option' {
        $script:Timed | Should-MatchString 'Enter for the default'
    }
}

Describe 'The summary is displayed, not returned' -Tag 'Static','Module' {

    # Inside a function, unassigned pipeline output is the return value. The
    # summary table stopped being displayed and started being returned, so the
    # caller got an array of formatting objects with the result buried in it and
    # the run log lost its summary entirely.
    # The AST, not a text search. A line search also matches a comment that
    # explains why Format-Table is not used somewhere, which formats nothing.
    It 'sends Format-Table to the host rather than the pipeline' {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile(
            (Join-Path $script:ModuleRoot 'Public\Update-Everything.ps1'), [ref] $null, [ref] $null)

        $formats = @($ast.FindAll({
                    param($n)
                    $n -is [System.Management.Automation.Language.CommandAst] -and
                    $n.GetCommandName() -eq 'Format-Table'
                }, $true))

        $formats.Count | Should-BeGreaterThan 0

        $offenders = foreach ($f in $formats) {
            $pipeline = $f.Parent
            while ($pipeline -and $pipeline -isnot [System.Management.Automation.Language.PipelineAst]) {
                $pipeline = $pipeline.Parent
            }

            $last = $pipeline.PipelineElements[-1]
            if ($last -isnot [System.Management.Automation.Language.CommandAst] -or
                $last.GetCommandName() -ne 'Out-Host') {
                "line $($f.Extent.StartLineNumber): $($pipeline.Extent.Text -replace '\s+', ' ')"
            }
        }

        $offenders | Should-BeNull -Because "these return formatting objects instead of displaying them:`n$($offenders -join "`n")"
    }
}

Describe 'Step output is displayed, not returned' -Tag 'Static','Module' {

    # Same defect as the summary table above, in the other half of the run.
    # Inside a function, unassigned pipeline output is the return value, so every
    # line a step produced was returned to the caller instead of displayed:
    # `$result = Update-Everything` -- the form the README documents -- came back
    # with 63 objects and the result buried among them, and the transcript
    # recorded none of the run it exists to record.

    It 'sends the captured step output to the host' {
        $path = Join-Path $script:ModuleRoot 'Private\Invoke-Step.ps1'
        $ast  = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref] $null, [ref] $null)

        # The pipeline that runs the action, found by the action invocation
        # inside it rather than by line number.
        $pipeline = $ast.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.PipelineAst] -and
                $node.Extent.Text -match '\$Action \*>&1'
            }, $true) | Select-Object -First 1

        $pipeline | Should-NotBeNull -Because 'the step action pipeline should still exist'

        $last = $pipeline.PipelineElements[-1]
        $last.GetCommandName() | Should-Be 'Out-Host'
    }
}

Describe 'No step updates through a tool it has not verified' -Tag 'Static','Module' {

    # The rule: a step must not invoke a package manager it has not confirmed is
    # present. -RequiresCommand does that before the action runs. A step without
    # one has to check for itself and end with Stop-StepAsSkipped, so the summary
    # says skipped rather than OK for something that did nothing.
    It 'checks for its tool, or skips itself explicitly' {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile(
            (Join-Path $script:ModuleRoot 'Public\Update-Everything.ps1'), [ref] $null, [ref] $null)

        # These need no external tool. PowerShell itself is always present, and
        # Windows Update is gated by -RequiresAdmin and the install consent.
        $builtIn = @(
            'Trust PSGallery', 'PowerShell modules', 'PowerShell help',
            'Windows Update', 'Windows Terminal default = PowerShell 7',
            # Invoke-WebRequest is built in and powershell.exe is always there.
            'UpdateEverything (self)',
            # PackageManagement and PowerShellGet ship with every supported
            # Windows, so Get-PackageProvider and Find-Module always resolve.
            # The step reports each component it did not find rather than
            # driving anything it has not confirmed.
            'Gallery tooling',
            # Resolves every tool it reports on, and reports absence as absence.
            # Running nothing it has not found is the whole job.
            'Inventory'
        )

        $offenders = foreach ($call in $ast.FindAll({
                    param($n)
                    $n -is [System.Management.Automation.Language.CommandAst] -and
                    $n.GetCommandName() -eq 'Invoke-Step'
                }, $true)) {

            $elements = $call.CommandElements
            $name = $null
            $hasRequires = $false
            for ($i = 0; $i -lt $elements.Count; $i++) {
                if ($elements[$i] -isnot [System.Management.Automation.Language.CommandParameterAst]) { continue }
                switch ($elements[$i].ParameterName) {
                    'Name'            { if ($i + 1 -lt $elements.Count) { $name = $elements[$i + 1].Value } }
                    'RequiresCommand' { $hasRequires = $true }
                }
            }

            if ($hasRequires -or $name -in $builtIn) { continue }
            if ($call.Extent.Text -match 'Stop-StepAsSkipped') { continue }

            $name
        }

        $offenders | Should-BeNull -Because "these run a tool without confirming it is installed: $($offenders -join ', ')"
    }

    # Self-update is only right when nothing else owns the tool. Running it
    # against a scoop or winget install fights that manager.
    It 'asks who owns <_> before telling it to update itself' -ForEach @('uv', 'Deno', 'Bun', 'pnpm', 'Google Cloud CLI') {
        $source = Get-Content (Join-Path $script:ModuleRoot 'Public\Update-Everything.ps1') -Raw
        $step = [regex]::Match($source, "(?s)Invoke-Step -Name '$_'.*?\r?\n    \}").Value

        $step | Should-MatchString 'Get-ToolInstallSource'
        $step | Should-MatchString 'Stop-StepAsSkipped'
    }

    # The old code excused any non-zero exit from uv as "expected when uv was
    # installed via a package manager". On this machine the real cause was a
    # locked file, and the step reported OK over a genuine failure.
    It 'does not excuse an unexplained failure as a package manager' {
        $source = Get-Content (Join-Path $script:ModuleRoot 'Public\Update-Everything.ps1') -Raw

        $source | Should-NotMatchString 'expected when uv was installed'
    }
}

Describe 'Get-ToolInstallSource' -Tag 'Unit' {

    It 'reports Absent for a command that does not exist' {
        & (Get-Module UpdateEverything) { Get-ToolInstallSource -Name 'definitely-not-a-real-command-xyz' } |
            Should-Be 'Absent'
    }

    It 'recognises a standalone install under .local\bin' {
        $result = & (Get-Module UpdateEverything) {
            Mock Get-Command { [pscustomobject]@{ Source = 'C:\Users\someone\.local\bin\uv.exe' } }
            Get-ToolInstallSource -Name 'uv'
        }
        $result | Should-Be 'Standalone'
    }
}

Describe 'Ready for the PowerShell Gallery' -Tag 'Static','Module','Lint' {

    # The gallery runs PSScriptAnalyzer with its own default rules and shows the
    # result on the package page. This repository's settings suppress several
    # rules deliberately, so the gallery sees more than local linting does.
    # Anything genuinely intentional carries a SuppressMessageAttribute with a
    # justification, which is the sanctioned way to say so in code.
    It 'has no analyzer findings under the default rules the gallery uses' -Skip:(-not $HasAnalyzer) {
        $findings = foreach ($file in Get-ChildItem $script:ModuleRoot -Recurse -Include *.ps1, *.psm1) {
            Invoke-ScriptAnalyzer -Path $file.FullName
        }

        $detail = ($findings | ForEach-Object {
            '{0}:{1} {2}' -f (Split-Path $_.ScriptPath -Leaf), $_.Line, $_.RuleName
        }) -join "`n"

        $findings | Should-BeNull -Because "the gallery would display these:`n$detail"
    }

    It 'justifies every suppression rather than silencing rules blankly' {
        $bare = foreach ($file in Get-ChildItem $script:ModuleRoot -Recurse -Filter *.ps1) {
            Select-String -Path $file.FullName -Pattern 'SuppressMessageAttribute' |
                Where-Object { $_.Line -notmatch "Justification\s*=\s*'.{20,}" } |
                ForEach-Object { "$($file.Name):$($_.LineNumber)" }
        }

        $bare | Should-BeNull -Because "a suppression without a reason is just a hidden warning:`n$($bare -join "`n")"
    }

    It 'declares the editions it supports' {
        (Import-PowerShellDataFile $script:Manifest).CompatiblePSEditions |
            Should-BeCollection -Count 2
    }

    # An empty help folder ships nothing and looks like an oversight.
    It 'ships an about topic' {
        $help = Join-Path $script:ModuleRoot 'en-us\about_UpdateEverything.help.txt'
        Test-Path $help | Should-BeTrue
        (Get-Content $help -Raw).Length | Should-BeGreaterThan 500
    }

    # Publish-Module needs the folder named after the module, and this repository
    # keeps its source in src, so publishing has to stage first. A script that
    # does it the same way every time beats remembering to.
    It 'ships a publish script that stages into a correctly named folder' {
        $publish = Join-Path $script:RepoRoot 'Publish.ps1'
        Test-Path $publish | Should-BeTrue

        $source = Get-Content $publish -Raw
        $source | Should-MatchString 'Join-Path \$staging \$manifest\.Name'
        $source | Should-MatchString 'Publish-Module'
    }

    # -WhatIf must skip the publish, not the checks. It once skipped the staging
    # copy too, and then validated a folder that had never been created.
    It 'still stages under -WhatIf, so the checks have something to validate' {
        $source = Get-Content (Join-Path $script:RepoRoot 'Publish.ps1') -Raw

        $source | Should-MatchString 'New-Item[^\r\n]*-WhatIf:\$false'
        $source | Should-MatchString 'Copy-Item[^\r\n]*-WhatIf:\$false'
    }
}
