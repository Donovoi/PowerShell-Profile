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
        if (-not (Get-Command -Name 'Install-Dependencies' -ErrorAction SilentlyContinue)) {
            function Install-Dependencies {
                # URL of the PowerShell script to import.
                $uri = 'https://raw.githubusercontent.com/Donovoi/PowerShell-Profile/main/functions/Install-Dependencies.ps1'

                # Create a new PowerShell module from the content obtained from the URI.
                # 'Invoke-RestMethod' is used to download the script content.
                # The script content is encapsulated in a script block and a new module is created from it.
                # 'Export-ModuleMember' exports all functions and aliases from the module.
                $script:dynMod = New-Module ([scriptblock]::Create(
                    ((Invoke-RestMethod $uri)) + "`nExport-ModuleMember -Function * -Alias *"
                    )) | Import-Module -PassThru

                # Check if this function ('Install-Dependencies') is shadowing the function from the imported module.
                # If it is, remove this function so that the newly imported function can be used.
                $myName = $MyInvocation.MyCommand.Name
                if ((Get-Command -Type Function $myName).ModuleName -ne $dynMod.Name) {
                    Remove-Item -LiteralPath "function:$myName"
                }

                # Invoke the newly imported function with the same name ('Install-Dependencies').
                # Pass all arguments received by this stub function to the imported function.
                & $myName @args
            }
        }
        Install-Dependencies -PSModule 'pansies' -NoPSModules -NoNugetPackages
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