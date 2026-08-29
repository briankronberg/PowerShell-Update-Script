#Requires -Modules Pester

BeforeAll {
    $script:ScriptPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'Update-Everything.ps1'
    $script:RepoRoot   = Split-Path $PSScriptRoot -Parent
}

Describe 'Update-Everything.ps1' {

    It 'exists' {
        Test-Path $script:ScriptPath | Should -Be $true
    }

    It 'parses without syntax errors' {
        $errors = $null
        [System.Management.Automation.Language.Parser]::ParseFile(
            $script:ScriptPath, [ref] $null, [ref] $errors) | Out-Null
        $errors | Should -BeNullOrEmpty
    }

    It 'declares a minimum PowerShell version' {
        (Get-Content $script:ScriptPath -TotalCount 5) -join "`n" |
            Should -Match '#Requires -Version'
    }

    It 'exposes the documented parameters' {
        $cmd = Get-Command $script:ScriptPath
        foreach ($name in @(
                'IncludeWindowsUpdate', 'IncludePowerShell7', 'SetPwshTerminalDefault',
                'AutoReboot', 'IncludePrerelease', 'UpdateGlobalNpm',
                'SkipElevation', 'LogRetentionDays')) {
            $cmd.Parameters.Keys | Should -Contain $name
        }
    }

    It 'defaults the destructive switches to off' {
        $cmd = Get-Command $script:ScriptPath
        # AutoReboot and UpdateGlobalNpm are switches, so absent means off.
        $cmd.Parameters['AutoReboot'].SwitchParameter      | Should -Be $true
        $cmd.Parameters['UpdateGlobalNpm'].SwitchParameter | Should -Be $true
    }

    It 'has comment-based help with a synopsis' {
        $help = Get-Help $script:ScriptPath
        $help.Synopsis | Should -Not -BeNullOrEmpty
    }
}

Describe 'PSScriptAnalyzer' -Skip:(-not (Get-Module PSScriptAnalyzer -ListAvailable)) {

    It 'reports no errors or warnings' {
        $findings = Invoke-ScriptAnalyzer -Path $script:ScriptPath `
            -Settings (Join-Path $script:RepoRoot 'PSScriptAnalyzerSettings.psd1')

        if ($findings) {
            $findings | Format-Table RuleName, Line, Message -AutoSize |
                Out-String | Write-Host
        }
        $findings.Count | Should -Be 0
    }
}
