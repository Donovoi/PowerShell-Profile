<#
.SYNOPSIS
A script to bootstrap the rcloned module.

.DESCRIPTION
This script bootstraps the rcloned module and performs necessary setup tasks.
It installs NuGet dependencies, external dependencies, and sets up the
Windows Terminal profile with PowerShell 7 as the default.

.NOTES
- Author: [Your Name]
- Date: [Current Date]

.PARAMETER Message
The message to be logged.

.PARAMETER Level
The level of the log message. Valid values are "INFO", "WARNING", "ERROR", and "VERBOSE".
The default value is "INFO".

.PARAMETER LogFile
The path to the log file. The default value is the current working directory appended with "log.txt".

.PARAMETER NoConsoleOutput
Specifies whether to suppress console output for the log message. By default, console output is enabled.

.PARAMETER WPFPopUpMessage
Specifies whether to display a WPF popup message with the log message. By default, this is disabled.
#>
function Write-Log {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]
        $Message,

        [Parameter(Mandatory = $false)]
        [ValidateSet('INFO', 'WARNING', 'ERROR', 'VERBOSE')]
        [string]
        $Level = 'INFO',

        [Parameter(Mandatory = $false)]
        [string]
        $LogFile = "$PWD\log.txt",

        [Parameter(Mandatory = $false)]
        [switch]
        $NoConsoleOutput,

        [Parameter(Mandatory = $false)]
        [switch]
        $WPFPopUpMessage,

        [Parameter(Mandatory = $false)]
        [switch]
        $NoLogFile
    )

    try {
        if (($Level -like 'WARNING') -or ($Level -like 'ERROR')) {
            $Level = $Level.ToUpper()
        }
        else {
            $Level = $Level.ToLower()
            $Level = $Level.Substring(0, 1).ToUpper() + $Level.Substring(1).ToLower()
        }

        $logMessage = '[{0}] {1}: {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message       
        if (-not($NoLogFile)) {
            Add-Content -Path $LogFile -Value $logMessage
        }
        

        if (-not ($NoConsoleOutput)) {
            switch ($Level) {
                'INFO' {
                    Write-Host -Object $logMessage -ForegroundColor Green
                }
                'WARNING' {
                    #  Warning text needs to be orange
                    Write-Host -Object $logMessage -ForegroundColor Orange
                }
                'ERROR' {
                    Write-Error -Message $logMessage
                }
                'VERBOSE' {
                    Write-Verbose -Message $logMessage
                }
            }
        }
        if ($WPFPopUpMessage) {
            New-WPFMessageBox -Content $Message -Title $Level -ButtonType 'OK-Cancel' -ContentFontSize 20 -TitleFontSize 40
        }
    }
    catch {
        Write-Error "An error occurred: $_"
        Write-Error "Error details: $($_.Exception)"
    }
}