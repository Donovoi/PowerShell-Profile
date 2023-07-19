function Get-NeededReboot {
    [CmdletBinding()]
    param (
        [Switch]$RestartIfNeeded
    )

    $rebootRequired = (Get-CimInstance -ClassName Win32_OperatingSystem).RebootPending
    if ($rebootRequired) {
        Write-Host "Windows requires a reboot"
        if ($RestartIfNeeded) {
            Write-Host "Restarting the system..."
            Restart-Computer -Force
        }
    } else {
        Write-Host "Windows does not require a reboot"
    }
}