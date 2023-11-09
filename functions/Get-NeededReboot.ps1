function Get-NeededReboot {
    [CmdletBinding()]
    param (
        [Switch]$RestartIfNeeded
    )

    $rebootRequired = (Get-CimInstance -ClassName Win32_OperatingSystem).RebootPending
    if ($rebootRequired) {
        Write-Log -Message "Windows requires a reboot"
        if ($RestartIfNeeded) {
            Write-Log -Message "Restarting the system..."
            Restart-Computer -Force
        }
    }
    else {
        Write-Log -Message "Windows does not require a reboot"
    }
}