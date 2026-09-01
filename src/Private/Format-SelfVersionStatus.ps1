function Format-SelfVersionStatus {
    <#
        .SYNOPSIS
        One line saying how the running version compares to the published one.

        .DESCRIPTION
        The version that matters is the one *running*, which is not always the
        highest installed: a session imported by path, or one that loaded before
        an update replaced the files on disk, is running something else. So the
        running version is passed in rather than looked up.

        Three answers must not be confused with each other, and each has been a
        wrong message somewhere before:

          behind          the gallery is ahead, and -UpdateSelf will fetch it
          ahead / equal   nothing to do
          cannot tell     the gallery was not reachable

        A copy PowerShellGet did not install -- one the GitHub installer placed,
        for instance -- is frequently *ahead* of the gallery rather than behind,
        so it is named separately and never called out of date.

        .PARAMETER Running
        The version of the module actually executing.

        .PARAMETER Status
        Get-GalleryModuleStatus output, or $null when it was not asked.

        .EXAMPLE
        Format-SelfVersionStatus -Running '1.1.0' -Status (Get-GalleryModuleStatus -Name UpdateEverything)
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [version] $Running,

        [object] $Status
    )

    if (-not $Status -or -not $Status.Available) {
        return "UpdateEverything $Running is running; the gallery could not be asked for a newer version."
    }

    $available = [version] $Status.Available

    if ($Running -lt $available) {
        $how = if ($Status.Installed -and -not $Status.Updatable) {
            'This copy did not come from the gallery, so use "Install-Module UpdateEverything -Force", or -UpdateSelf -UpdateSelfSource Main to track the branch it came from.'
        } else {
            'Run with -UpdateSelf to install it.'
        }
        return "UpdateEverything $Running is running; $available is published. $how"
    }

    if ($Running -gt $available) {
        # Normal for a clone or a GitHub install, and not a fault.
        return "UpdateEverything $Running is running, ahead of the published $available."
    }

    return "UpdateEverything $Running is running, which is the newest published version."
}
