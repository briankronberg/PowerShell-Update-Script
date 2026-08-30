function Test-NotificationModuleAvailable {
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    [bool] (Get-Module BurntToast -ListAvailable)
}
