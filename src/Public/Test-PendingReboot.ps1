function Test-PendingReboot {
    # Reports whether Windows is waiting on a restart, and why. Every probe is a
    # Test-Path or Get-ItemProperty call, so a test can mock the registry instead
    # of needing a machine that genuinely owes a reboot.
    [CmdletBinding()]
    param()

    $pendingReboot  = $false
    $rebootReasons  = [System.Collections.Generic.List[string]]::new()

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
    $pendingRenames = @($sessionManager.PendingFileRenameOperations | Where-Object { $_ })
    if ($pendingRenames.Count -gt 0) {
        $pendingReboot = $true
        $rebootReasons.Add("Pending file renames ($($pendingRenames.Count))")
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
} catch { }

    [pscustomobject]@{
        IsPending = $pendingReboot
        Reasons   = $rebootReasons.ToArray()
    }
}
