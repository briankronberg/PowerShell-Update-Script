function Initialize-ConsoleEncoding {
    # Native CLIs emit UTF-8 (winget) or UTF-16LE (wsl); without this the console
    # codepage turns their output into mojibake in the logs. Returns the previous
    # encoding so the caller can put the host back the way it found it.
    [CmdletBinding()]
    param()

    $previous = [Console]::OutputEncoding
    try { [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false) } catch { }
    $env:WSL_UTF8 = '1'
    $previous
}
