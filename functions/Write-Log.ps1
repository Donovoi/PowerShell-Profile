function Write-Log {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]
        $Message,
        [Parameter(Mandatory = $false)]
        [ValidateSet('INFO', 'WARNING', 'ERROR')]
        [string]
        $Level = 'INFO',
        [Parameter(Mandatory = $false)]
        [string]
        $LogFile = "$PWD\log.txt",
        [Parameter(Mandatory = $false)]
        [switch]
        $NoConsoleOutput
    )

    if (($Level -like 'WARNING') -or ($Level -like 'ERROR')) {
        $Level = $Level.ToUpper()
    }
    else {
        $Level = $Level.ToLower()
        $Level = $Level.Substring(0, 1).ToUpper() + $Level.Substring(1).ToLower()
    }

    $logMessage = '[{0}] {1}: {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Add-Content -Path $LogFile -Value $logMessage

    if (-not ($NoConsoleOutput)) {
        switch ($Level) {
            'INFO' {
                Write-Host $logMessage -ForegroundColor Green
            }
            'WARNING' {
                #  Warning text needs to be orange

                Write-Warning -Message $logMessage
            }
            'ERROR' {
                Write-Error -Message $logMessage
            }
        }
    }
}