function Get-NextAvailablePort {
    <#
    .SYNOPSIS
    Finds the next available port within a specified range.

    .DESCRIPTION
    This function iterates through a range of ports and returns the first available port.

    .PARAMETER StartPort
    The starting port number of the range. Default is 1024.

    .PARAMETER EndPort
    The ending port number of the range. Default is 65535.

    .EXAMPLE
    PS> Get-NextAvailablePort -StartPort 2000 -EndPort 3000
    2000

    .NOTES
    Author: Your Name
    Date:   Current Date
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param (
        [ValidateRange(1, 65535)]
        [int]$StartPort = 1024,

        [ValidateRange(1, 65535)]
        [int]$EndPort = 65535
    )

    try {
        for ($port = $StartPort; $port -le $EndPort; $port++) {
            if (-not (Test-NetConnection -ComputerName localhost -Port $port -InformationLevel Quiet)) {
                return $port
            }
        }

        throw "No available port found in the range $StartPort-$EndPort."
    }
    catch {
        Write-Error $_.Exception.Message
    }
}
