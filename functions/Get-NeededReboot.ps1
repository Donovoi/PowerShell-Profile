function Get-NeededReboot {
    [CmdletBinding()]
    param (
        [Switch]$RestartIfNeeded
    )

    $rebootRequired = (Get-CimInstance -ClassName Win32_OperatingSystem).RebootPending
    if ($rebootRequired) {
        Write-Logg -Message "Windows requires a reboot"
        if ($RestartIfNeeded) {
            Write-Logg -Message "Restarting the system..."
            Restart-Computer -Force
        }
    }
    else {
        Write-Logg -Message "Windows does not require a reboot"
    }
}