function Clear-Console {
    <#
        .SYNOPSIS
            Clears the console viewport **and** scroll‑back buffer.
        .PARAMETER FlushKeys
            Also purge any buffered keyboard input (recommended after long‑running loops).
    #>
    [CmdletBinding()]
    param([switch]$FlushKeys)

    # Remove any lingering progress bar first
    Write-Progress -Activity ' ' -Completed

    # Fast viewport wipe via .NET
    [Console]::Clear()

    # ANSI VT: ESC[3J = erase scroll‑back, ESC[H = cursor home.
    # Use Write-Information to stay within PSAvoidUsingWriteHost rule.
    $esc = [char]27
    Write-Information "$esc[3J$esc[H" -InformationAction Continue

    if ($FlushKeys) {
        $host.UI.RawUI.FlushInputBuffer()
    }
}
