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

    $FileScriptBlock = ''
    # make sure we have pansies to override write-host
    $neededcmdlets = @('Install-Dependencies', 'Show-TUIConfirmationDialog')
    foreach ($cmd in $neededcmdlets) {
        if (-not (Get-Command -Name $cmd -ErrorAction SilentlyContinue)) {
            if (-not (Get-Command -Name 'Install-Cmdlet' -ErrorAction SilentlyContinue)) {
                $method = Invoke-RestMethod -Uri 'https://raw.githubusercontent.com/Donovoi/PowerShell-Profile/main/functions/Install-Cmdlet.ps1'
                $finalstring = [scriptblock]::Create($method.ToString() + "`nExport-ModuleMember -Function * -Alias *")
                New-Module -Name 'InstallCmdlet' -ScriptBlock $finalstring | Import-Module
            }
            Write-Verbose "Importing cmdlet: $cmd"
            $scriptBlock = Install-Cmdlet -RepositoryCmdlets $cmd -PreferLocal -Force

            # Check if the returned value is a ScriptBlock and import it properly
            if ($scriptBlock -is [scriptblock]) {
                $moduleName = "Dynamic_$cmd"
                New-Module -Name $moduleName -ScriptBlock $scriptBlock | Import-Module -Force
                Write-Verbose "Imported $cmd as dynamic module: $moduleName"
            }
            elseif ($scriptBlock -is [System.Management.Automation.PSModuleInfo]) {
                # If a module info was returned, it's already imported
                Write-Verbose "Module for $cmd was already imported: $($scriptBlock.Name)"
            }
            elseif ($($scriptBlock | Get-Item) -is [System.IO.FileInfo]) {
                # If a file path was returned, import it
                $FileScriptBlock += $(Get-Content -Path $scriptBlock -Raw) + "`n"
                Write-Verbose "Imported $cmd from file: $scriptBlock"
            }
            else {
                Write-Warning "Could not import $cmd`: Unexpected return type from Install-Cmdlet"
                Write-Warning "Returned: $($scriptBlock)"
            }
        }
    }
    $finalFileScriptBlock = [scriptblock]::Create($FileScriptBlock.ToString() + "`nExport-ModuleMember -Function * -Alias *")
    New-Module -Name 'cmdletCollection' -ScriptBlock $finalFileScriptBlock | Import-Module -Force
    # if (-not(Get-Module -Name 'Pansies' -ListAvailable -ErrorAction SilentlyContinue)) {
    #     Install-Dependencies -PSModule 'Pansies' -NoNugetPackage
    # }
    # Import-Module -Name 'Pansies' -Force -ErrorAction SilentlyContinue

    if ($TUIPopUpMessage) {
        if (-not (Get-Module -Name 'Microsoft.PowerShell.ConsoleGuiTools' -ListAvailable -ErrorAction SilentlyContinue)) {
            Install-Dependencies -PSModule 'Microsoft.PowerShell.ConsoleGuiTools' -NoNugetPackage

        }
    }

    # Capitalize the level for WARNING and ERROR for consistency
    if (($Level -like 'WARNING') -or ($Level -like 'ERROR')) {
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
            Install-Dependencies -PSModule 'lolcat' -NoNugetPackage
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

        # Display the confirmation dialog
        $confirmationResult = Show-TUIConfirmationDialog -Title $TUIPopUpTitle -Question $logMessage -InfoLevel $Level

        # Return the confirmation result
        return $confirmationResult
    }
}