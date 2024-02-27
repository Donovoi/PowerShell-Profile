function Write-Logg {
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

    try {
        # make sure we have pansies to override write-host
        $cmdlets = @('Install-Dependencies')
        if (-not (Get-Command -Name 'Install-Dependencies' -ErrorAction SilentlyContinue)) {
            if (-not (Get-Command -Name 'Install-Cmdlet' -ErrorAction SilentlyContinue)) {
                $method = Invoke-RestMethod -Uri 'https://raw.githubusercontent.com/Donovoi/PowerShell-Profile/main/functions/Install-Cmdlet.ps1'
                $finalstring = [scriptblock]::Create($method.ToString() + "`nExport-ModuleMember -Function * -Alias *")
                New-Module -Name 'InstallCmdlet' -ScriptBlock $finalstring | Import-Module
            }
            Write-Verbose -Message "Importing cmdlets: $cmdlets"
            $Cmdletstoinvoke = Install-Cmdlet -donovoicmdlets $cmdlets
            $Cmdletstoinvoke | Import-Module -Force
            if (-not(Get-Module -Name 'pansies' -ListAvailable -ErrorAction SilentlyContinue)) {
                Install-Dependencies -PSModule 'pansies' -NoNugetPackages
            }
        }
        Import-Module -Name 'pansies' -Force
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

        # Output to console if not suppressed
        if (-not ($NoConsoleOutput)) {
            switch ($Level) {
                'INFO' {
                    Write-Host -Object $logMessage -ForegroundColor Green
                }
                'WARNING' {
                    Write-Host -Object $logMessage -ForegroundColor Yellow
                }
                'ERROR' {
                    Write-Host -Object $logMessage -ForegroundColor Red
                }
                'VERBOSE' {
                    Write-Verbose -Message $logMessage
                }
            }
        }

        # Show WPF pop-up message if specified
        if ($WPFPopUpMessage) {
            New-WPFMessageBox -Content $Message -Title $Level -ButtonType 'OK-Cancel' -ContentFontSize 20 -TitleFontSize 40
        }

        # Show Terminal.Gui pop-up message if specified
        if ($TUIPopUpMessage) {
            # Initialize Terminal.Gui
            [Terminal.Gui.Application]::Init()

            # Display the confirmation dialog
            $confirmationResult = Show-TUIConfirmationDialog -Title $TUIPopUpTitle -Question $Message -InfoLevel $Level

            # Shutdown Terminal.Gui after displaying the dialog
            [Terminal.Gui.Application]::Shutdown()

            # Return the confirmation result
            return $confirmationResult
        }
    }
    catch {
        Write-Error "An error occurred: $_"
        Write-Error "Error details: $($_.Exception)"
    }
}