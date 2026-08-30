function Test-ParameterSupport {
    <#
        .SYNOPSIS
        Whether the command that resolves in this session has the named parameter.

        .DESCRIPTION
        Windows PowerShell ships PowerShellGet 1.0.0.1, which predates
        -AcceptLicense on Install-Module and Update-Module. Splatting it there is
        a terminating error, and it took out both the "PowerShell modules" and
        "Windows Update" steps on a 5.1 run.

        Comparing module versions would be the wrong test. What matters is the
        command that actually binds in this session, and that follows
        PSModulePath order rather than the highest version installed.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string] $Command,

        [Parameter(Mandatory)]
        [string] $Parameter
    )

    $resolved = Get-Command $Command -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $resolved) { return $false }

    $resolved.Parameters.ContainsKey($Parameter)
}
