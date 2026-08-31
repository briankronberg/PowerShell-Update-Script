function Invoke-SetupChoice {
    <#
        .SYNOPSIS
        Carries out one option from the setup menu.

        .DESCRIPTION
        Split out from Initialize-UpdateEverything so each option can be tested
        on its own, and so the menu loop stays a menu loop.

        Every option says what it is about to do before it does it. The menu is
        the confirmation for reaching the option; it is not a confirmation for
        installing anything, which still goes through Approve-Install.

        .EXAMPLE
        Invoke-SetupChoice -Key Prerequisites
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Write-Host is the user interface of a console maintenance tool. This runs from an interactive menu, not inside a step.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Reached only from the setup menu, which is itself the choice. Installs go through Approve-Install and the task registration reports what it made.')]
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Prerequisites', 'ScheduledTask', 'DeveloperTools', 'FirstRun')]
        [string] $Key
    )

    switch ($Key) {

        'Prerequisites' {
            Write-Host ''
            Write-Host 'Running the prerequisite steps only: PowerShell 7, the gallery tooling and' -ForegroundColor Cyan
            Write-Host 'the package managers. Nothing else is touched, and each install still asks.' -ForegroundColor Cyan
            Write-Host ''

            # -Notify because BurntToast is one of the prerequisites, and a toast
            # at the end is the only proof it works. The tags keep this to the
            # PowerShell and package-manager steps.
            $null = Update-Everything -Tag PowerShell, PackageManager -Notify `
                -IncludePowerShellModules $false
        }

        'ScheduledTask' { Invoke-TaskSetup }

        'DeveloperTools' {
            $catalogue = @(Get-DeveloperToolCatalogue)

            Write-Host ''
            Write-Host 'Developer tools' -ForegroundColor Cyan
            Write-Host 'This module updates; it does not install. These are the exception, and' -ForegroundColor DarkGray
            Write-Host 'nothing is installed that you do not pick.' -ForegroundColor DarkGray
            Write-Host ''

            for ($i = 0; $i -lt $catalogue.Count; $i++) {
                $tool = $catalogue[$i]
                $mark = if ($tool.Present) { 'installed' } else { '' }
                Write-Host ("  {0,2}. {1,-18} {2,-10} {3}" -f ($i + 1), $tool.Name, $mark, $tool.Description)
            }

            Write-Host ''
            Write-Host 'Numbers separated by commas, or blank to go back.' -ForegroundColor DarkGray
            $answer = (Read-Host 'Install').Trim()

            if (-not $answer) { return }

            $wanted = foreach ($part in ($answer -split ',')) {
                $trimmed = $part.Trim()
                if (-not $trimmed) { continue }

                $index = 0
                if (-not [int]::TryParse($trimmed, [ref] $index) -or
                    $index -lt 1 -or $index -gt $catalogue.Count) {
                    Write-Warning "'$trimmed' is not one of the numbers listed."
                    continue
                }

                $catalogue[$index - 1].Name
            }

            $wanted = @($wanted)
            if (-not $wanted.Count) { return }

            Write-Host ''
            $result = Install-DeveloperTool -Name $wanted
            if ($result) {
                Write-Host ''
                Write-Host "Installed $($result.Installed), skipped $($result.Skipped), failed $($result.Failed)." -ForegroundColor Cyan
            }
        }

        'FirstRun' {
            Write-Host ''
            Write-Host 'Running Update-Everything. This is the ordinary run, and it will ask before' -ForegroundColor Cyan
            Write-Host 'installing anything it does not already have.' -ForegroundColor Cyan
            Write-Host ''

            $null = Update-Everything
        }
    }
}
