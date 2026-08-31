function Get-ModuleVersionMap {
    <#
        .SYNOPSIS
        The highest installed version of every module on this machine, by name.

        .DESCRIPTION
        Taken before and after an update pass and compared, this is what turns
        "OK (94 s)" into a list of what actually moved. Update-Module and
        Update-PSResource are both silent on success, so without the comparison a
        run that updated forty modules and one that updated none read the same.

        Returns a hashtable keyed on module name, so a caller can diff two of
        them without sorting or matching. Case-insensitive, because module names
        are.

        .EXAMPLE
        $before = Get-ModuleVersionMap
        Update-Module -Force
        $after = Get-ModuleVersionMap
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()

    $map = @{}

    foreach ($module in Get-Module -ListAvailable -ErrorAction SilentlyContinue) {
        $name = $module.Name
        $version = $module.Version

        # A module is installed side by side, one folder per version, so the same
        # name arrives more than once. The highest is the one that binds.
        if (-not $map.ContainsKey($name) -or $version -gt $map[$name]) {
            $map[$name] = $version
        }
    }

    $map
}
