function Test-PendingReboot {
    # Reports whether Windows is waiting on a restart, and why. Every probe is a
    # Test-Path or Get-ItemProperty call, so a test can mock the registry instead
    # of needing a machine that genuinely owes a reboot.
    [CmdletBinding()]
    param()

    $pendingReboot  = $false
    $rebootReasons  = [System.Collections.Generic.List[string]]::new()

$rebootKeys = [ordered]@{
    'Component Based Servicing'  = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'
    'CBS reboot in progress'     = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootInProgress'
    'Windows Update'             = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
    'Windows Update post-reboot' = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\PostRebootReporting'
}
foreach ($entry in $rebootKeys.GetEnumerator()) {
    if (Test-Path -LiteralPath $entry.Value) {
        $pendingReboot = $true
        $rebootReasons.Add($entry.Key)
    }
}

# PendingFileRenameOperations exists as an empty value on plenty of healthy
# machines, so test the value rather than the presence of the property.
# Read the key and look for the value, rather than asking for the value and
# catching the failure. -Name with -ErrorAction Stop throws when the property is
# absent -- the normal, healthy case -- and Start-Transcript dutifully records
# that as "TerminatingError(Get-ItemProperty)" in the run log, where it reads
# like something went wrong on a machine where nothing did.
$sessionManager = Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' `
    -ErrorAction SilentlyContinue
if ($sessionManager -and
    $sessionManager.PSObject.Properties.Name -contains 'PendingFileRenameOperations') {
    # The value is a REG_MULTI_SZ of [source, destination] pairs. A pair with a
    # destination is a real rename: Windows is holding a replacement for a file
    # that is in use, and the restart is what completes it. A pair with an empty
    # destination is a scheduled *deletion*, which installers queue constantly
    # for their own temp files and which needs no restart to be meaningful.
    #
    # Counting every entry made a single leftover
    #   *1\??\C:\Users\...\AppData\Local\Temp\DEL396A.tmp
    # announce "[!] A reboot is pending" on every run, while Component Based
    # Servicing and Windows Update both reported nothing pending at all. A
    # restart prompt nobody needs is one people learn to ignore.
    $entries   = @($sessionManager.PendingFileRenameOperations)
    $renames   = 0
    $deletions = 0

    for ($i = 0; $i -lt $entries.Count; $i += 2) {
        $source = $entries[$i]
        if (-not $source) { continue }

        # A trailing source with no partner is malformed; treat it as a deletion
        # rather than inventing a rename out of it.
        $destination = if ($i + 1 -lt $entries.Count) { $entries[$i + 1] } else { '' }

        if ($destination) { $renames++ } else { $deletions++ }
    }

    if ($renames -gt 0) {
        $pendingReboot = $true
        $rebootReasons.Add("Pending file renames ($renames)")
    }

    if ($deletions -gt 0) {
        Write-Verbose "$deletions scheduled file deletion(s) are queued; those do not require a restart."
    }
}

# A queued computer rename also needs a restart to take effect.
try {
    $activeName = (Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ActiveComputerName' -Name ComputerName -ErrorAction Stop).ComputerName
    $targetName = (Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ComputerName'       -Name ComputerName -ErrorAction Stop).ComputerName
    if ($activeName -ne $targetName) {
        $pendingReboot = $true
        $rebootReasons.Add("Computer rename pending ($activeName -> $targetName)")
    }
} catch { Write-Verbose "Could not read the computer name keys: $($_.Exception.Message)" }

    [pscustomobject]@{
        IsPending = $pendingReboot
        Reasons   = $rebootReasons.ToArray()
    }
}
