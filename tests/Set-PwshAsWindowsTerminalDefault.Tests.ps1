#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '6.0' }

<#
    Tests for the one function that rewrites a file the user owns, so it gets the
    most scrutiny of anything in the suite.

    LOCALAPPDATA is redirected into TestDrive for the duration, so the real
    Windows Terminal settings.json is never opened, let alone written.
#>

BeforeAll {
    # Load the module's functions individually rather than importing the module,
    # so tests can reach the private ones directly. $ModuleRoot is what
    # Invoke-SelfElevation and the task builder hand to an elevated child.
    $script:ModuleRoot = Join-Path (Split-Path $PSScriptRoot -Parent) 'src'
    Get-ChildItem "$script:ModuleRoot\Private\*.ps1", "$script:ModuleRoot\Public\*.ps1" |
        ForEach-Object { . $_.FullName }

    $script:RealLocalAppData = $env:LOCALAPPDATA
    $script:PwshGuid = '{574e775e-4f2a-5b96-ac1e-a2962a402336}'
}

AfterAll {
    $env:LOCALAPPDATA = $script:RealLocalAppData
}

Describe 'Set-PwshAsWindowsTerminalDefault' -Tag 'Unit' {

    BeforeEach {
        $script:Sandbox     = Join-Path $TestDrive ('wt-' + [guid]::NewGuid().ToString('N'))
        $script:SettingsDir = Join-Path $script:Sandbox 'Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState'
        $null = New-Item -ItemType Directory -Path $script:SettingsDir -Force
        $script:SettingsPath = Join-Path $script:SettingsDir 'settings.json'

        $script:LogDir = Join-Path $script:Sandbox 'logs'
        $null = New-Item -ItemType Directory -Path $script:LogDir -Force

        $env:LOCALAPPDATA = $script:Sandbox

        # Terminal being open only produces a warning, but leaving this unmocked
        # would make results depend on whether the tester had Terminal running.
        Mock Get-Process { }
    }

    Context 'A settings file that names another default' {

        BeforeEach {
            $content = '{' + [Environment]::NewLine +
                '    "defaultProfile": "{11111111-1111-1111-1111-111111111111}",' + [Environment]::NewLine +
                '    "theme": "dark",' + [Environment]::NewLine +
                '    "profiles": { "list": [ { "guid": "' + $script:PwshGuid + '", "source": "Windows.Terminal.PowershellCore" } ] }' + [Environment]::NewLine +
                '}'
            Set-Content -LiteralPath $script:SettingsPath -Value $content -Encoding utf8
        }

        It 'points defaultProfile at the PowerShell 7 profile' {
            Set-PwshAsWindowsTerminalDefault -LogDir $script:LogDir 6>$null

            $result = Get-Content $script:SettingsPath -Raw | ConvertFrom-Json
            $result.defaultProfile | Should-Be $script:PwshGuid
        }

        # Terminal rewrites settings.json from memory when it exits, so an edit
        # made while it is open can silently revert. The person gets told.
        It 'warns when Windows Terminal is running' {
            Mock Get-Process { [pscustomobject]@{ Name = 'WindowsTerminal' } }

            $everything = @(Set-PwshAsWindowsTerminalDefault -LogDir $script:LogDir 3>&1 6>$null)

            "$($everything -join ' ')" | Should-MatchString 'may revert this change'
        }

        It 'names the likely lock holder when the file cannot be written' {
            # Read sharing only: the function can read and back the file up, and
            # the write is what fails -- the same shape as Terminal holding it.
            $handle = [System.IO.File]::Open($script:SettingsPath, 'Open', 'Read', 'Read')
            try {
                { $null = Set-PwshAsWindowsTerminalDefault -LogDir $script:LogDir 3>$null 6>$null } |
                    Should-Throw -ExceptionMessage '*Could not write settings.json*'
            } finally {
                $handle.Dispose()
            }
        }

        It 'leaves every other setting alone' {
            Set-PwshAsWindowsTerminalDefault -LogDir $script:LogDir 6>$null

            $result = Get-Content $script:SettingsPath -Raw | ConvertFrom-Json
            $result.theme | Should-Be 'dark'
        }

        It 'backs the file up before touching it' {
            Set-PwshAsWindowsTerminalDefault -LogDir $script:LogDir 6>$null

            @(Get-ChildItem $script:LogDir -Filter '*.json.bak') | Should-BeCollection -Count 1
        }

        It 'leaves exactly one defaultProfile key' {
            Set-PwshAsWindowsTerminalDefault -LogDir $script:LogDir 6>$null

            $raw = Get-Content $script:SettingsPath -Raw
            ([regex]::Matches($raw, '"defaultProfile"\s*:')).Count | Should-Be 1
        }

        It 'writes UTF-8 without a BOM' {
            Set-PwshAsWindowsTerminalDefault -LogDir $script:LogDir 6>$null

            $bytes = [System.IO.File]::ReadAllBytes($script:SettingsPath)
            $hasBom = ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
            $hasBom | Should-BeFalse
        }

        It 'produces a backup that still parses as JSON' {
            Set-PwshAsWindowsTerminalDefault -LogDir $script:LogDir 6>$null

            $backup = Get-ChildItem $script:LogDir -Filter '*.json.bak' | Select-Object -First 1
            $restored = Remove-JsonComment -Text (Get-Content $backup.FullName -Raw) | ConvertFrom-Json
            $restored.defaultProfile | Should-Be '{11111111-1111-1111-1111-111111111111}'
        }
    }

    Context 'A settings file that is already correct' {

        BeforeEach {
            $content = '{' + [Environment]::NewLine +
                '    "defaultProfile": "' + $script:PwshGuid + '",' + [Environment]::NewLine +
                '    "profiles": { "list": [ { "guid": "' + $script:PwshGuid + '", "source": "Windows.Terminal.PowershellCore" } ] }' + [Environment]::NewLine +
                '}'
            Set-Content -LiteralPath $script:SettingsPath -Value $content -Encoding utf8
        }

        It 'makes no backup, because it makes no change' {
            Set-PwshAsWindowsTerminalDefault -LogDir $script:LogDir 6>$null

            @(Get-ChildItem $script:LogDir -Filter '*.json.bak') | Should-BeCollection -Count 0
        }

        It 'leaves the file byte-for-byte identical' {
            $before = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($script:SettingsPath))
            Set-PwshAsWindowsTerminalDefault -LogDir $script:LogDir 6>$null
            $after = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($script:SettingsPath))

            $after | Should-Be $before
        }
    }

    Context 'A settings file carrying JSONC comments' {

        BeforeEach {
            $content = '{' + [Environment]::NewLine +
                '    // Terminal writes these' + [Environment]::NewLine +
                '    "defaultProfile": "{22222222-2222-2222-2222-222222222222}",' + [Environment]::NewLine +
                '    /* and these */' + [Environment]::NewLine +
                '    "profiles": { "list": [ { "guid": "' + $script:PwshGuid + '", "source": "Windows.Terminal.PowershellCore" } ] }' + [Environment]::NewLine +
                '}'
            Set-Content -LiteralPath $script:SettingsPath -Value $content -Encoding utf8
        }

        It 'still updates the default profile' {
            Set-PwshAsWindowsTerminalDefault -LogDir $script:LogDir 6>$null

            Get-Content $script:SettingsPath -Raw | Should-MatchString ([regex]::Escape($script:PwshGuid))
        }

        # Comments are stripped only to parse. Destroying the user's comments on
        # disk would be an unpleasant surprise.
        It 'keeps the comments in the file' {
            Set-PwshAsWindowsTerminalDefault -LogDir $script:LogDir 6>$null

            Get-Content $script:SettingsPath -Raw | Should-MatchString 'Terminal writes these'
        }
    }

    Context 'A settings file that only the regex can read' {

        BeforeEach {
            # A missing comma between members: not JSON, and not rescued by the
            # comment stripper. The regex fallback still finds and moves the
            # default, and the parse failure is said out loud.
            $content = '{' + [Environment]::NewLine +
                '    "defaultProfile": "{11111111-1111-1111-1111-111111111111}"' + [Environment]::NewLine +
                '    "theme": "dark"' + [Environment]::NewLine +
                '}'
            Set-Content -LiteralPath $script:SettingsPath -Value $content -Encoding utf8
        }

        It 'says the file did not parse, out loud' {
            $everything = @(Set-PwshAsWindowsTerminalDefault -LogDir $script:LogDir 3>&1 6>$null)

            "$($everything -join ' ')" | Should-MatchString 'did not parse even after stripping comments'
        }

        It 'still moves the default, through the raw text' {
            $null = Set-PwshAsWindowsTerminalDefault -LogDir $script:LogDir 3>$null 6>$null

            $raw = Get-Content -LiteralPath $script:SettingsPath -Raw
            $raw | Should-MatchString ('"defaultProfile"\s*:\s*"' + [regex]::Escape($script:PwshGuid) + '"')
            $raw | Should-NotMatchString '11111111'
        }
    }

    Context 'A settings file with no defaultProfile key' {

        BeforeEach {
            $content = '{' + [Environment]::NewLine +
                '    "profiles": { "list": [ { "guid": "' + $script:PwshGuid + '", "source": "Windows.Terminal.PowershellCore" } ] }' + [Environment]::NewLine +
                '}'
            Set-Content -LiteralPath $script:SettingsPath -Value $content -Encoding utf8
        }

        It 'inserts the key' {
            Set-PwshAsWindowsTerminalDefault -LogDir $script:LogDir 6>$null

            $result = Get-Content $script:SettingsPath -Raw | ConvertFrom-Json
            $result.defaultProfile | Should-Be $script:PwshGuid
        }

        It 'inserts it exactly once' {
            Set-PwshAsWindowsTerminalDefault -LogDir $script:LogDir 6>$null

            $raw = Get-Content $script:SettingsPath -Raw
            ([regex]::Matches($raw, '"defaultProfile"\s*:')).Count | Should-Be 1
        }

        # An insert that produced a trailing comma or a stray brace would still
        # match the key count above, so parse the result to be sure.
        It 'leaves the result parseable, with the original settings intact' {
            Set-PwshAsWindowsTerminalDefault -LogDir $script:LogDir 6>$null

            $result = Get-Content $script:SettingsPath -Raw | ConvertFrom-Json
            $result.profiles.list[0].source | Should-Be 'Windows.Terminal.PowershellCore'
        }
    }

    Context 'No PowerShell 7 profile in the file yet' {

        BeforeEach {
            $content = '{' + [Environment]::NewLine +
                '    "defaultProfile": "{33333333-3333-3333-3333-333333333333}",' + [Environment]::NewLine +
                '    "profiles": { "list": [ { "guid": "{33333333-3333-3333-3333-333333333333}", "name": "cmd" } ] }' + [Environment]::NewLine +
                '}'
            Set-Content -LiteralPath $script:SettingsPath -Value $content -Encoding utf8
        }

        It 'falls back to the well-known PowerShell Core GUID' {
            Set-PwshAsWindowsTerminalDefault -LogDir $script:LogDir 6>$null

            $result = Get-Content $script:SettingsPath -Raw | ConvertFrom-Json
            $result.defaultProfile | Should-Be $script:PwshGuid
        }
    }

    Context 'Refusing to damage a file it cannot understand' {

        # Terminal takes the last of two defaultProfile keys, so an edit that
        # left two would look applied while doing nothing predictable. The
        # count guard refuses, and the file is not touched.
        It 'refuses a file that already carries two defaultProfile keys' {
            $content = '{ "defaultProfile": "{11111111-1111-1111-1111-111111111111}", ' +
                '"defaultProfile": "{22222222-2222-2222-2222-222222222222}", ' +
                '"profiles": { "list": [] } }'
            Set-Content -LiteralPath $script:SettingsPath -Value $content -Encoding utf8
            $before = Get-Content -LiteralPath $script:SettingsPath -Raw

            { $null = Set-PwshAsWindowsTerminalDefault -LogDir $script:LogDir 3>$null 6>$null } |
                Should-Throw -ExceptionMessage '*expected exactly 1*'
            Get-Content -LiteralPath $script:SettingsPath -Raw | Should-Be $before
        }

        It 'throws rather than rewriting an empty settings.json' {
            Set-Content -LiteralPath $script:SettingsPath -Value '' -Encoding utf8

            { Set-PwshAsWindowsTerminalDefault -LogDir $script:LogDir 6>$null } |
                Should-Throw -ExceptionMessage '*refusing to edit*'
        }

        It 'does not write when it cannot back the file up' {
            $content = '{ "defaultProfile": "{44444444-4444-4444-4444-444444444444}" }'
            Set-Content -LiteralPath $script:SettingsPath -Value $content -Encoding utf8
            Mock Copy-Item { throw 'backup failed' }

            { Set-PwshAsWindowsTerminalDefault -LogDir $script:LogDir 6>$null } |
                Should-Throw -ExceptionMessage '*refusing to edit without a backup*'

            Get-Content $script:SettingsPath -Raw | Should-MatchString '44444444'
        }
    }

    Context 'Windows Terminal not installed' {

        BeforeEach {
            Remove-Item -LiteralPath $script:SettingsPath -Force -ErrorAction SilentlyContinue
        }

        It 'returns quietly instead of failing the step' {
            Set-PwshAsWindowsTerminalDefault -LogDir $script:LogDir 6>$null

            @(Get-ChildItem $script:LogDir -Filter '*.json.bak') | Should-BeCollection -Count 0
        }
    }
}
