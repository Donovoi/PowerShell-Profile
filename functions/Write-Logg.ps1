<#
.SYNOPSIS
Writes log messages with various options.

.DESCRIPTION
The Write-Logg function is used to write log messages with different options such as log level, log file, console output, WPF pop-up message, and Terminal.Gui pop-up message.

.PARAMETER Message
The log message to be written.

.PARAMETER Level
The log level of the message. Valid values are 'INFO', 'WARNING', 'ERROR', and 'VERBOSE'. The default value is 'INFO'.

.PARAMETER LogFile
The path to the log file. The default value is "$PWD\log.log".

.PARAMETER NoConsoleOutput
Specifies whether to suppress console output. If this switch is used, the log message will not be displayed in the console.

.PARAMETER WPFPopUpMessage
Specifies whether to show a WPF pop-up message with the log message.

.PARAMETER TUIPopUpMessage
Specifies whether to show a Terminal.Gui pop-up message with the log message.

.PARAMETER TUIPopUpTitle
The title of the Terminal.Gui pop-up message. The default value is 'Confirmation'.

.PARAMETER LogToFile
Specifies whether to log the message to the specified log file.

.EXAMPLE
Write-Logg -Message "This is an informational message" -Level "INFO"

This example writes an informational message to the log file and displays it in the console with green color.

.EXAMPLE
Write-Logg -Message "This is a warning message" -Level "WARNING" -LogFile "C:\Logs\log.log" -NoConsoleOutput

This example writes a warning message to the specified log file but does not display it in the console.

#>
function Write-Logg {
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory = $true)]
        [string]
        $Message,

        [Parameter(Mandatory = $false)]
        [ValidateSet('INFO', 'WARNING', 'ERROR', 'VERBOSE', 'LOLCAT')]
        [string]
        $Level = 'INFO',

        [Parameter(Mandatory = $false)]
        [string]
        $LogFile = "$PWD\log.log",

        [Parameter(Mandatory = $false)]
        [switch]
        $NoConsoleOutput,

        [Parameter(Mandatory = $false)]
        [switch]
        $WPFPopUpMessage,

        [Parameter(Mandatory = $false)]
        [switch]
        $TUIPopUpMessage,


        [Parameter(Mandatory = $false)]
        [string]
        $TUIPopUpTitle = 'Confirmation',


        [Parameter(Mandatory = $false)]
        [switch]
        $LogToFile
    )

    # Set TLS 1.2 for secure connections
    if ($PSVersionTable.PSVersion.Major -le 5) {
        try {
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13
        }
        catch {
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        }
    }
    
    # Load shared dependency loader if not already available
    if (-not (Get-Command -Name 'Initialize-CmdletDependencies' -ErrorAction SilentlyContinue)) {
        $initScript = Join-Path $PSScriptRoot 'Initialize-CmdletDependencies.ps1'
        if (Test-Path $initScript) {
            . $initScript
        }
        else {
            Write-Warning "Initialize-CmdletDependencies.ps1 not found in $PSScriptRoot"
            Write-Warning 'Falling back to direct download'
            try {
                $method = Invoke-RestMethod -Uri 'https://raw.githubusercontent.com/Donovoi/PowerShell-Profile/main/functions/Initialize-CmdletDependencies.ps1' -TimeoutSec 30 -UseBasicParsing
                $scriptBlock = [scriptblock]::Create($method)
                . $scriptBlock
            }
            catch {
                Write-Error "Failed to load Initialize-CmdletDependencies: $($_.Exception.Message)"
                Write-Warning 'Write-Logg will run with reduced functionality'
                return
            }
        }
    }
    
    # Load all required cmdlets (replaces 60+ lines of boilerplate)
    try {
        Initialize-CmdletDependencies -RequiredCmdlets @('Install-Dependencies', 'Show-TUIConfirmationDialog') -PreferLocal -ErrorAction Stop
    }
    catch {
        Write-Warning "Failed to load some dependencies: $($_.Exception.Message)"
        Write-Warning 'Write-Logg will continue with reduced functionality'
    }
    # if (-not(Get-Module -Name 'Pansies' -ListAvailable -ErrorAction SilentlyContinue)) {
    #     Install-Dependencies -PSModule 'Pansies' -NoNugetPackage
    # }
    # Import-Module -Name 'Pansies' -Force -ErrorAction SilentlyContinue

    if ($TUIPopUpMessage) {
        if (-not (Get-Module -Name 'Microsoft.PowerShell.ConsoleGuiTools' -ListAvailable -ErrorAction SilentlyContinue)) {
            if (Get-Command -Name 'Install-Dependencies' -ErrorAction SilentlyContinue) {
                try {
                    Install-Dependencies -PSModule 'Microsoft.PowerShell.ConsoleGuiTools' -NoNugetPackage
                }
                catch {
                    Write-Warning "Failed to install Microsoft.PowerShell.ConsoleGuiTools: $($_.Exception.Message)"
                    Write-Warning 'TUI popup will not be available'
                    $TUIPopUpMessage = $false
                }
            }
            else {
                Write-Warning 'Install-Dependencies not available, cannot install Microsoft.PowerShell.ConsoleGuiTools'
                Write-Warning 'TUI popup will not be available'
                $TUIPopUpMessage = $false
            }
        }
    }

    # Capitalize the level for WARNING and ERROR for consistency
    if (($Level -like 'WARNING') -or ($Level -like 'ERROR') -or ($Level -like 'VERBOSE')) {
        $Level = $Level.ToUpper()
    }
    else {
        $Level = $Level.Substring(0, 1).ToUpper() + $Level.Substring(1).ToLower()
    }

    # Format the log message
    $logMessage = '[{0}] {1}: {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message

    # Log to file if specified
    if ($LogToFile) {
        Add-Content -Path $LogFile -Value $logMessage
    }

    if ($level -like 'LOLCAT') {
        if (-not (Get-Command -Name 'lolcat' -ErrorAction SilentlyContinue)) {
            if (Get-Command -Name 'Install-Dependencies' -ErrorAction SilentlyContinue) {
                try {
                    Install-Dependencies -PSModule 'lolcat' -NoNugetPackage
                }
                catch {
                    Write-Warning "Failed to install lolcat: $($_.Exception.Message)"
                    Write-Warning 'Falling back to standard output'
                    $level = 'INFO'
                }
            }
            else {
                Write-Warning 'Install-Dependencies not available, cannot install lolcat'
                Write-Warning 'Falling back to standard output'
                $level = 'INFO'
            }
        }
    }

    # Output to console if not suppressed
    if ((-not ($NoConsoleOutput)) -and (-not($TUIPopUpMessage))) {
        switch ($Level) {
            'INFO' {
                Write-Host "$logMessage`n" -ForegroundColor Green
            }
            'WARNING' {
                Write-Host "$logMessage`n" -ForegroundColor Yellow
            }
            'ERROR' {
                Write-Host "$logMessage`n" -ForegroundColor Red
            }
            'VERBOSE' {
                Write-Verbose -Message "$logMessage`n"
            }
            'LOLCAT' {
                "$logMessage`n" | lolcat -a
            }
        }
    }

    # Show WPF pop-up message if specified
    if ($WPFPopUpMessage) {
        New-WPFMessageBox -Content $Message -Title $Level -ButtonType 'OK-Cancel' -ContentFontSize 20 -TitleFontSize 40
    }

    # Show Terminal.Gui pop-up message if specified
    if ($TUIPopUpMessage) {
        if (Get-Command -Name 'Show-TUIConfirmationDialog' -ErrorAction SilentlyContinue) {
            try {
                # Display the confirmation dialog
                $confirmationResult = Show-TUIConfirmationDialog -Title $TUIPopUpTitle -Question $logMessage -InfoLevel $Level

                # Return the confirmation result
                return $confirmationResult
            }
            catch {
                Write-Warning "Failed to show TUI dialog: $($_.Exception.Message)"
                Write-Host $logMessage -ForegroundColor Yellow
            }
        }
        else {
            Write-Warning 'Show-TUIConfirmationDialog not available, falling back to console output'
            Write-Host $logMessage -ForegroundColor Yellow
        }
    }
}