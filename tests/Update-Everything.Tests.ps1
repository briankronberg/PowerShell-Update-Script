#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '6.0' }

<#
    Tests for Update-Everything.ps1.

    SAFETY: nothing here may dot-source or invoke the script. It is a maintenance
    runner that self-elevates, installs software machine-wide, edits Windows
    Terminal's settings.json and can trigger a reboot -- running it to test it
    would wreck the machine doing the testing. Every assertion below inspects the
    script statically: through the AST, or through Get-Command / Get-Help, which
    read the parameter block and help without executing the body.

    That constraint is also why there is no code coverage: coverage requires
    executing the code under test.
#>

BeforeDiscovery {
    $RepoRoot   = Split-Path $PSScriptRoot -Parent
    $ScriptPath = Join-Path $RepoRoot 'Update-Everything.ps1'

    # -ForEach data is consumed during discovery, so it has to be built here.
    # BeforeAll runs too late, and its variables are not visible to -ForEach.
    $ExpectedParameters = @(
        @{ Name = 'IncludeWindowsUpdate';   TypeName = 'bool';   Type = [bool];   Default = '$true' }
        @{ Name = 'IncludePowerShell7';     TypeName = 'bool';   Type = [bool];   Default = '$true' }
        @{ Name = 'SetPwshTerminalDefault'; TypeName = 'bool';   Type = [bool];   Default = '$true' }
        @{ Name = 'AutoReboot';             TypeName = 'switch'; Type = [switch]; Default = $null }
        @{ Name = 'IncludePrerelease';      TypeName = 'switch'; Type = [switch]; Default = $null }
        @{ Name = 'UpdateGlobalNpm';        TypeName = 'switch'; Type = [switch]; Default = $null }
        @{ Name = 'SkipElevation';          TypeName = 'switch'; Type = [switch]; Default = $null }
        @{ Name = 'Notify';                 TypeName = 'switch'; Type = [switch]; Default = $null }
        @{ Name = 'AllowInstall';           TypeName = 'string[]'; Type = [string[]]; Default = '@()' }
        @{ Name = 'LogRetentionDays';       TypeName = 'int';    Type = [int];    Default = '30' }
    )

    # Switches that must stay off by default: each one either reboots the machine
    # or moves pinned toolchains, so turning one on has to be a deliberate act.
    $DefaultOffSwitches = @(
        'AutoReboot', 'IncludePrerelease', 'UpdateGlobalNpm', 'SkipElevation',
        # Notifications are opt-in, and pulling a module off the gallery
        # unasked would be a surprise in an unattended run.
        'Notify'
    )

    # Steps that cannot possibly work unelevated. Each must carry -RequiresAdmin
    # so an unelevated run reports "skipped, needs admin" instead of a
    # permissions error that reads like a bug in the script.
    $AdminOnlySteps = @('Windows Update', 'Defender signatures', 'PowerShell 7 (latest)')

    $HasAnalyzer = [bool] (Get-Module PSScriptAnalyzer -ListAvailable)

    # Every PowerShell file in the repo gets linted, not just the script.
    $LintTargets = @(
        'Update-Everything.ps1'
        'Register-UpdateTask.ps1'
        'test.ps1'
        'tests/Update-Everything.Tests.ps1'
        'tests/Update-Everything.Functions.Tests.ps1'
        'tests/Set-PwshAsWindowsTerminalDefault.Tests.ps1'
        'tests/Register-UpdateTask.Tests.ps1'
        'tests/Notification.Tests.ps1'
        'tests/InstallConsent.Tests.ps1'
    )
}

BeforeAll {
    $script:RepoRoot   = Split-Path $PSScriptRoot -Parent
    $script:ScriptPath = Join-Path $script:RepoRoot 'Update-Everything.ps1'

    $script:Ast = [System.Management.Automation.Language.Parser]::ParseFile(
        $script:ScriptPath, [ref] $null, [ref] $null)

    # Every -Name passed to Invoke-Step, in file order.
    $script:StepNames = $script:Ast.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.CommandAst] -and
            $node.GetCommandName() -eq 'Invoke-Step'
        }, $true) | ForEach-Object {
        $elements = $_.CommandElements
        for ($i = 0; $i -lt $elements.Count - 1; $i++) {
            if ($elements[$i] -is [System.Management.Automation.Language.CommandParameterAst] -and
                $elements[$i].ParameterName -eq 'Name') {
                $elements[$i + 1].Value
            }
        }
    }

    $script:DeclaredParameters = $script:Ast.ParamBlock.Parameters

    # Every Invoke-Step call with the switches it was given, so the suite can ask
    # which steps are marked admin-only.
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

    # Where the dot-source guard sits among the top-level statements.
    $script:TopLevelStatements = $script:Ast.EndBlock.Statements
    $script:GuardIndex = -1
    $script:GuardLine = [int]::MaxValue
    for ($i = 0; $i -lt $script:TopLevelStatements.Count; $i++) {
        $statement = $script:TopLevelStatements[$i]
        if ($statement -is [System.Management.Automation.Language.IfStatementAst] -and
            $statement.Extent.Text -match 'MyInvocation\.InvocationName') {
            $script:GuardIndex = $i
            $script:GuardLine = $statement.Extent.StartLineNumber
            break
        }
    }
}

Describe 'Update-Everything.ps1' -Tag 'Static' {

    Context 'Script integrity' {

        It 'exists at the repository root' {
            Test-Path $script:ScriptPath |
                Should-BeTrue -Because 'the tests locate the script relative to themselves'
        }

        It 'parses without syntax errors' {
            $errors = $null
            [System.Management.Automation.Language.Parser]::ParseFile(
                $script:ScriptPath, [ref] $null, [ref] $errors) | Out-Null
            $errors | Should-BeNull
        }

        It 'declares a minimum PowerShell version' {
            (Get-Content $script:ScriptPath -TotalCount 5) -join "`n" |
                Should-MatchString '#Requires -Version'
        }

        It 'opts into common parameters with [CmdletBinding()]' {
            $script:Ast.ParamBlock.Attributes.TypeName.Name |
                Should-ContainCollection 'CmdletBinding'
        }
    }

    Context 'Parameter contract' {

        It 'declares -<Name> as <TypeName>' -ForEach $ExpectedParameters {
            Get-Command $script:ScriptPath |
                Should-HaveParameter -ParameterName $Name -Type $Type
        }

        It 'defaults -<Name> to <Default>' -ForEach ($ExpectedParameters | Where-Object Default) {
            $declared = $script:DeclaredParameters |
                Where-Object { $_.Name.VariablePath.UserPath -eq $Name }

            $declared.DefaultValue.Extent.Text | Should-Be $Default
        }

        It 'leaves -<_> off unless explicitly passed' -ForEach $DefaultOffSwitches {
            # Capture the -ForEach item first: inside Where-Object, $_ rebinds to
            # the pipeline element, and comparing against that silently matches
            # nothing -- which would make this assertion pass vacuously.
            $switchName = $_

            $declared = $script:DeclaredParameters |
                Where-Object { $_.Name.VariablePath.UserPath -eq $switchName }

            $declared | Should-NotBeNull -Because "-$switchName should still exist"

            # A switch with no default is $false; a default would silently arm it.
            $declared.DefaultValue | Should-BeNull -Because 'switches must stay opt-in'
        }

        It 'declares no parameters beyond the documented contract' {
            $declared = $script:DeclaredParameters.Name.VariablePath.UserPath
            $declared | Should-BeCollection -Count 10 -Because 'a new parameter needs docs and a test'
        }

        It 'bounds -LogRetentionDays with ValidateRange' {
            $declared = $script:DeclaredParameters |
                Where-Object { $_.Name.VariablePath.UserPath -eq 'LogRetentionDays' }

            $declared.Attributes.TypeName.Name | Should-ContainCollection 'ValidateRange'
        }
    }

    Context 'Comment-based help' {

        It 'has a synopsis' {
            (Get-Help $script:ScriptPath).Synopsis | Should-NotBeEmptyString
        }

        It 'documents -<Name>' -ForEach $ExpectedParameters {
            (Get-Help $script:ScriptPath).parameters.parameter.name |
                Should-ContainCollection $Name -Because 'undocumented parameters drift into surprises'
        }
    }

    Context 'Step definitions' {

        It 'defines every update step through Invoke-Step' {
            $script:StepNames.Count | Should-BeGreaterThan 10
        }

        It 'gives every step a unique name' {
            # Step names become log file names; duplicates would overwrite each other.
            $duplicates = $script:StepNames |
                Group-Object |
                Where-Object Count -gt 1 |
                Select-Object -ExpandProperty Name

            $duplicates | Should-BeNull -Because "these step names repeat: $($duplicates -join ', ')"
        }

        It 'names every step with a non-empty string' {
            $script:StepNames | Should-All { $_ -is [string] -and $_.Trim() }
        }

        It 'marks <_> as requiring administrator' -ForEach $AdminOnlySteps {
            $stepName = $_
            $call = $script:StepCalls | Where-Object { $_.Name -eq $stepName }

            $call | Should-NotBeNull -Because "the step '$stepName' should still exist"
            $call.RequiresAdmin | Should-BeTrue -Because 'it cannot work unelevated'
        }
    }

    # The two behavioural test files dot-source this script. That is only safe
    # while the guard holds, so the guard itself is asserted here rather than
    # assumed.
    Context 'Safe to dot-source' {

        It 'has a dot-source guard' {
            $script:GuardIndex | Should-BeGreaterThanOrEqual 0 -Because 'dot-sourcing must not start a maintenance run'
        }

        It 'defines nothing but functions before the guard' {
            # A single stray statement above the guard would execute on every
            # dot-source, which is how a test run ends up installing software.
            $before = $script:TopLevelStatements[0..($script:GuardIndex - 1)]
            $offenders = $before |
                Where-Object { $_ -isnot [System.Management.Automation.Language.FunctionDefinitionAst] } |
                ForEach-Object { "line $($_.Extent.StartLineNumber): $($_.Extent.Text.Split([Environment]::NewLine)[0])" }

            $offenders | Should-BeNull -Because "these run on every dot-source:`n$($offenders -join "`n")"
        }

        It 'runs no update step before the guard' {
            $firstStepLine = $script:Ast.FindAll({
                    param($node)
                    $node -is [System.Management.Automation.Language.CommandAst] -and
                    $node.GetCommandName() -eq 'Invoke-Step'
                }, $true) |
                ForEach-Object { $_.Extent.StartLineNumber } |
                Sort-Object |
                Select-Object -First 1

            $firstStepLine | Should-BeGreaterThan $script:GuardLine
        }
    }

    # Set-StrictMode would catch undefined variable reads at runtime, but it also
    # makes a missing property fatal, and this script legitimately probes for
    # optional keys in settings.json. Static analysis buys the useful half
    # without the breakage.
    Context 'Variable hygiene' {

        It 'reads no variable it never assigns' {
            $automatic = @(
                'true', 'false', 'null', '_', 'PSItem', 'args', 'input', 'this', 'PSCmdlet',
                'MyInvocation', 'PSScriptRoot', 'PSCommandPath', 'PID', 'Error', 'Matches',
                'LASTEXITCODE', 'PSVersionTable', 'ErrorActionPreference', 'ProgressPreference',
                'WarningPreference', 'VerbosePreference', 'InformationPreference', 'DebugPreference',
                'ConfirmPreference', 'WhatIfPreference', 'PWD', 'HOME', 'Host', 'ExecutionContext',
                'PSBoundParameters', 'PSDefaultParameterValues', 'IsWindows', 'IsLinux', 'IsMacOS',
                'IsCoreCLR', 'env', 'OutputEncoding', 'PSEdition', 'PSCulture', 'PSUICulture',
                'ShellId', 'NestedPromptLevel', 'StackTrace', 'switch', 'foreach'
            )

            $bare = { param($p) ($p -replace '^(script|global|local|private):', '') }

            $defined = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
            foreach ($n in $script:Ast.FindAll({ param($x) $x -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true)) {
                foreach ($v in $n.Left.FindAll({ param($x) $x -is [System.Management.Automation.Language.VariableExpressionAst] }, $true)) {
                    [void] $defined.Add((& $bare $v.VariablePath.UserPath))
                }
            }
            foreach ($n in $script:Ast.FindAll({ param($x) $x -is [System.Management.Automation.Language.ParameterAst] }, $true)) {
                [void] $defined.Add((& $bare $n.Name.VariablePath.UserPath))
            }
            foreach ($n in $script:Ast.FindAll({ param($x) $x -is [System.Management.Automation.Language.ForEachStatementAst] }, $true)) {
                [void] $defined.Add((& $bare $n.Variable.VariablePath.UserPath))
            }

            $undefined = @(
                foreach ($v in $script:Ast.FindAll({ param($x) $x -is [System.Management.Automation.Language.VariableExpressionAst] }, $true)) {
                    $name = & $bare $v.VariablePath.UserPath
                    if ($name -in $automatic) { continue }
                    if ($v.VariablePath.IsDriveQualified) { continue }
                    if ($defined.Contains($name)) { continue }
                    "line $($v.Extent.StartLineNumber): `$$name"
                }
            ) | Sort-Object -Unique

            $undefined | Should-BeNull -Because "a typo'd variable reads as `$null:`n$($undefined -join "`n")"
        }
    }
}

Describe 'Repository documentation' -Tag 'Docs' {

    BeforeAll {
        $script:Readme = Get-Content (Join-Path $script:RepoRoot 'README.md') -Raw
    }

    It 'README documents -<Name>' -ForEach $ExpectedParameters {
        $script:Readme | Should-MatchString ([regex]::Escape("-$Name"))
    }

    It 'ships a LICENSE file' {
        Test-Path (Join-Path $script:RepoRoot 'LICENSE') | Should-BeTrue
    }

    It 'licenses under MIT' {
        Get-Content (Join-Path $script:RepoRoot 'LICENSE') -Raw |
            Should-MatchString 'MIT License'
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

    # Every example has to survive an AllSigned or Restricted machine, where a
    # bare .\script.ps1 is refused before it runs. This caught real breakage:
    # the README's own quick start could not be pasted onto the machine it was
    # written on.
    It 'offers no example that a locked-down machine would refuse' {
        $offenders = $script:Readme -split "`r?`n" |
            Where-Object { $_ -match '^\s*\.\[A-Za-z][A-Za-z0-9-]*\.ps1' }

        $offenders | Should-BeNull -Because "these are refused under AllSigned:`n$($offenders -join "`n")"
    }
}

Describe 'PSScriptAnalyzer' -Tag 'Lint' -Skip:(-not $HasAnalyzer) {

    It 'reports no errors or warnings in <_>' -ForEach $LintTargets {
        $relative = $_
        $path = Join-Path $script:RepoRoot $relative

        # Pester puts -ForEach data in BeforeDiscovery variables that the
        # analyzer cannot see being consumed, so every test file trips
        # PSUseDeclaredVarsMoreThanAssignments. Excluded for tests only -- in the
        # script itself an unused variable is still worth knowing about.
        # Splatted, because -ExcludeRule rejects an empty array outright.
        $extra = @{}
        if ($relative -like 'tests*') {
            $extra['ExcludeRule'] = @('PSUseDeclaredVarsMoreThanAssignments')
        }

        $findings = Invoke-ScriptAnalyzer -Path $path `
            -Settings (Join-Path $script:RepoRoot 'PSScriptAnalyzerSettings.psd1') @extra

        $detail = ($findings | ForEach-Object {
                '{0}:{1} {2}' -f $_.RuleName, $_.Line, $_.Message
            }) -join "`n"

        $findings | Should-BeNull -Because "the baseline is clean, so these are new:`n$detail"
    }
}
