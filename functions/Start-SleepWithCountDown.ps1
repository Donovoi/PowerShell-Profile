<#
.SYNOPSIS
Performs a countdown using the Start-Sleep cmdlet.

.DESCRIPTION
This function performs a countdown and writes a log message every 5 seconds using the Start-Sleep cmdlet.

.PARAMETER Seconds
The number of seconds for the countdown.

.PARAMETER NoConsoleOutput
Specifies whether to suppress console output for the countdown. By default, console output is enabled.
#>
function Start-SleepWithCountdown {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [int]
        $Seconds,

        [Parameter(Mandatory = $false)]
        [switch]
        $NoConsoleOutput
    )

    try {
        for ($i = $Seconds; $i -gt 0; $i--) {
            if ($i % 5 -eq 0) {
                # Log a message every 5 seconds
                Write-Logg -Message "Sleeping for $i more second(s)" -Level INFO -NoConsoleOutput:$NoConsoleOutput
            }
            Start-Sleep -Seconds 1
        }
    }
    catch {
        Write-Error "An error occurred: $_"
        Write-Error "Error details: $($_.Exception)"
    }
}