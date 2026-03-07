<#
.SYNOPSIS
Writes structured log messages and can colorize piped text.

.DESCRIPTION
The Write-Logg function writes structured log messages with different options
such as log level, log file, console output, WPF pop-up message, and
Terminal.Gui pop-up message.

Write-Logg also accepts pipeline input. When pipeline input is used together
with `-Level LOLCAT`, the raw incoming text is colorized without adding the
usual timestamp and level prefix. For non-LOLCAT pipeline usage, Write-Logg
still emits one structured log line per input item.

.PARAMETER Message
The log message to be written when calling Write-Logg directly.

.PARAMETER InputObject
An object received from the pipeline. Pipeline input is converted to text
using PowerShell's normal string conversion behavior.

.PARAMETER Level
The log level of the message. Valid values are 'INFO', 'WARNING', 'ERROR',
'VERBOSE', and 'LOLCAT'. The default value is 'INFO'.

.PARAMETER LogFile
The path to the log file. The default value is "$PWD\log.log".

.PARAMETER NoConsoleOutput
Specifies whether to suppress console output. If this switch is used, the log
message will not be displayed in the console.

.PARAMETER WPFPopUpMessage
Specifies whether to show a WPF pop-up message with the log message.

.PARAMETER TUIPopUpMessage
Specifies whether to show a Terminal.Gui pop-up message with the log message.

.PARAMETER TUIPopUpTitle
The title of the Terminal.Gui pop-up message. The default value is
'Confirmation'.

.PARAMETER LogToFile
Specifies whether to log the message to the specified log file.

.EXAMPLE
Write-Logg -Message "This is an informational message" -Level INFO

Writes an informational message and displays it in the console with green
color.

.EXAMPLE
Write-Logg -Message "This is a warning message" -Level WARNING -LogFile "C:\Logs\log.log" -NoConsoleOutput -LogToFile

Writes a warning message to the specified log file without displaying it in
the console.

.EXAMPLE
'hello world' | Write-Logg -Level LOLCAT

Colorizes raw piped text with lolcat without adding a timestamp or level
prefix.

.EXAMPLE
Get-Content .\app.log | Write-Logg -Level INFO

Writes one structured INFO log line for each piped line.

.NOTES
Popup switches are intended for direct `-Message` usage. When pipeline input
is used, popup switches are disabled to avoid creating one dialog per piped
item.
#>
function Write-Logg {
    [CmdletBinding(DefaultParameterSetName = 'Message')]
    [OutputType([void])]
    param(
        [Parameter(Mandatory = $true, Position = 0, ParameterSetName = 'Message')]
        [AllowEmptyString()]
        [string]
        $Message,

        [Parameter(Mandatory = $true, ValueFromPipeline = $true, ParameterSetName = 'Pipeline')]
        [AllowNull()]
        [object]
        $InputObject,

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

    begin {
        $useWPFPopUpMessage = $WPFPopUpMessage
        $useTUIPopUpMessage = $TUIPopUpMessage

        if ($PSCmdlet.ParameterSetName -eq 'Pipeline' -and ($useWPFPopUpMessage -or $useTUIPopUpMessage)) {
            Write-Warning 'Popup switches are not supported when using pipeline input. Falling back to console/file output only.'
            $useWPFPopUpMessage = $false
            $useTUIPopUpMessage = $false
        }

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

        # Load all required cmdlets once per invocation
        try {
            Initialize-CmdletDependencies -RequiredCmdlets @('Install-Dependencies', 'Show-TUIConfirmationDialog') -PreferLocal -ErrorAction Stop
        }
        catch {
            Write-Warning "Failed to load some dependencies: $($_.Exception.Message)"
            Write-Warning 'Write-Logg will continue with reduced functionality'
        }

        if ($useTUIPopUpMessage) {
            if (-not (Get-Module -Name 'Microsoft.PowerShell.ConsoleGuiTools' -ListAvailable -ErrorAction SilentlyContinue)) {
                if (Get-Command -Name 'Install-Dependencies' -ErrorAction SilentlyContinue) {
                    try {
                        Install-Dependencies -PSModule 'Microsoft.PowerShell.ConsoleGuiTools' -NoNugetPackage
                    }
                    catch {
                        Write-Warning "Failed to install Microsoft.PowerShell.ConsoleGuiTools: $($_.Exception.Message)"
                        Write-Warning 'TUI popup will not be available'
                        $useTUIPopUpMessage = $false
                    }
                }
                else {
                    Write-Warning 'Install-Dependencies not available, cannot install Microsoft.PowerShell.ConsoleGuiTools'
                    Write-Warning 'TUI popup will not be available'
                    $useTUIPopUpMessage = $false
                }
            }
        }

        # Capitalize the level for WARNING and ERROR for consistency
        if (($Level -like 'WARNING') -or ($Level -like 'ERROR') -or ($Level -like 'VERBOSE')) {
            $resolvedLevel = $Level.ToUpper()
        }
        else {
            $resolvedLevel = $Level.Substring(0, 1).ToUpper() + $Level.Substring(1).ToLower()
        }

        if ($resolvedLevel -like 'LOLCAT') {
            if (-not (Get-Command -Name 'lolcat' -ErrorAction SilentlyContinue)) {
                if (Get-Command -Name 'Install-Dependencies' -ErrorAction SilentlyContinue) {
                    try {
                        Install-Dependencies -PSModule 'lolcat' -NoNugetPackage
                    }
                    catch {
                        Write-Warning "Failed to install lolcat: $($_.Exception.Message)"
                        Write-Warning 'Falling back to standard output'
                        $resolvedLevel = 'INFO'
                    }
                }
                else {
                    Write-Warning 'Install-Dependencies not available, cannot install lolcat'
                    Write-Warning 'Falling back to standard output'
                    $resolvedLevel = 'INFO'
                }
            }
        }

        function ConvertTo-WriteLoggText {
            param(
                [AllowNull()]
                [object]$Value
            )

            if ($null -eq $Value) {
                return ''
            }

            if ($Value -is [string]) {
                return $Value
            }

            return [string]$Value
        }

        function New-WriteLoggMessage {
            param(
                [AllowEmptyString()]
                [string]$Text
            )

            return '[{0}] {1}: {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $resolvedLevel, $Text
        }

        function Write-WriteLoggConsoleOutput {
            param(
                [AllowEmptyString()]
                [string]$Text,

                [AllowEmptyString()]
                [string]$StructuredMessage,

                [bool]$UseRawLolcat
            )

            if ($NoConsoleOutput -or $useTUIPopUpMessage) {
                return
            }

            switch ($resolvedLevel) {
                'INFO' {
                    Write-Host "$StructuredMessage`n" -ForegroundColor Green
                }
                'WARNING' {
                    Write-Host "$StructuredMessage`n" -ForegroundColor Yellow
                }
                'ERROR' {
                    Write-Host "$StructuredMessage`n" -ForegroundColor Red
                }
                'VERBOSE' {
                    Write-Verbose -Message "$StructuredMessage`n"
                }
                'LOLCAT' {
                    if ($UseRawLolcat) {
                        "$Text`n" | lolcat -a
                    }
                    else {
                        "$StructuredMessage`n" | lolcat -a
                    }
                }
            }
        }
    }

    process {
        $isPipelineInput = $PSCmdlet.ParameterSetName -eq 'Pipeline'
        $textToWrite = if ($isPipelineInput) {
            ConvertTo-WriteLoggText -Value $InputObject
        }
        else {
            $Message
        }

        $logMessage = New-WriteLoggMessage -Text $textToWrite

        if ($LogToFile) {
            Add-Content -Path $LogFile -Value $logMessage
        }

        $useRawLolcat = $isPipelineInput -and ($resolvedLevel -like 'LOLCAT')
        Write-WriteLoggConsoleOutput -Text $textToWrite -StructuredMessage $logMessage -UseRawLolcat:$useRawLolcat

        if (-not $isPipelineInput) {
            if ($useWPFPopUpMessage) {
                New-WPFMessageBox -Content $textToWrite -Title $resolvedLevel -ButtonType 'OK-Cancel' -ContentFontSize 20 -TitleFontSize 40
            }

            if ($useTUIPopUpMessage) {
                if (Get-Command -Name 'Show-TUIConfirmationDialog' -ErrorAction SilentlyContinue) {
                    try {
                        $confirmationResult = Show-TUIConfirmationDialog -Title $TUIPopUpTitle -Question $logMessage -InfoLevel $resolvedLevel
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
    }
}