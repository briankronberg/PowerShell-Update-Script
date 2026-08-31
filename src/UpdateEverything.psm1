# The OperatingSystem object, not its Version: .Platform is a property of the
# former and is always $null on the latter. Windows PowerShell has no $IsWindows
# to fall back on, so a $null here would fail the guard below on a supported
# edition.
$OS = [System.Environment]::OSVersion

if ($OS.Platform -ne [System.PlatformID]::Win32NT) {
    throw 'UpdateEverything drives Windows update channels (winget, Windows Update, Defender, Windows Terminal) and only runs on Windows.'
}

if ($OS.Version.Major -lt 10) {
    throw "UpdateEverything requires Windows 10 or a matching Windows Server release. This machine reports $($OS.Version.ToString())."
}

# Where the module lives on disk. Invoke-SelfElevation hands this to the elevated
# child so it imports this copy rather than resolving the name and possibly
# finding another, or nothing at all when the module is installed per-user.
$script:ModuleRoot = $PSScriptRoot

$Public = @(Get-ChildItem -Path "$PSScriptRoot\Public\*.ps1" -ErrorAction SilentlyContinue)
$Private = @(Get-ChildItem -Path "$PSScriptRoot\Private\*.ps1" -ErrorAction SilentlyContinue)

foreach ($Import in @($Public + $Private)) {
    try {
        . $Import.FullName
    } catch {
        Write-Error -Message "Failed to import function $($Import.FullName): $_"
    }
}

Set-Alias -Name Update-All -Value Update-Everything

Export-ModuleMember -Function $Public.BaseName
Export-ModuleMember -Alias 'Update-All'
