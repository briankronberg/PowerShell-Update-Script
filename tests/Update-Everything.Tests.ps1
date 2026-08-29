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
        @{ Name = 'LogRetentionDays';       TypeName = 'int';    Type = [int];    Default = '30' }
    )

    # Switches that must stay off by default: each one either reboots the machine
    # or moves pinned toolchains, so turning one on has to be a deliberate act.
    $DefaultOffSwitches = @('AutoReboot', 'IncludePrerelease', 'UpdateGlobalNpm', 'SkipElevation')

    $HasAnalyzer = [bool] (Get-Module PSScriptAnalyzer -ListAvailable)
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
            $declared | Should-BeCollection -Count 8 -Because 'a new parameter needs docs and a test'
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
}

Describe 'PSScriptAnalyzer' -Tag 'Lint' -Skip:(-not $HasAnalyzer) {

    It 'reports no errors or warnings' {
        $findings = Invoke-ScriptAnalyzer -Path $script:ScriptPath `
            -Settings (Join-Path $script:RepoRoot 'PSScriptAnalyzerSettings.psd1')

        $detail = ($findings | ForEach-Object {
                '{0}:{1} {2}' -f $_.RuleName, $_.Line, $_.Message
            }) -join "`n"

        $findings | Should-BeNull -Because "the baseline is clean, so these are new:`n$detail"
    }
}
