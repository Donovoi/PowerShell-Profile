<#
.SYNOPSIS
    Shows a confirmation dialog in the terminal UI.
.DESCRIPTION
    The Show-TUIConfirmationDialog function shows a confirmation dialog in the terminal UI.
    It takes a title, a question and an info level as input and returns a boolean value.

    The info level is used to determine the color scheme of the dialog.
    The following info levels are supported:
    - INFO
    - WARNING
    - ERROR
    - VERBOSE

.PARAMETER Title
    The title of the dialog.

.PARAMETER Question
    The question that is asked in the dialog.

.PARAMETER InfoLevel
    The info level of the dialog. The following info levels are supported:
    - INFO
    - WARNING
    - ERROR
    - VERBOSE
.NOTES
    Requires PowerShell 5.0 or higher due to the usage of certain advanced features like classes and compression.

.LINK
.EXAMPLE
    Show-TUIConfirmationDialog -Title "Are you sure?" -Question "Are you sure you want to do this?" -InfoLevel "INFO"
    This example shows a confirmation dialog with the title 'Are you sure?' and the question 'Are you sure you want to do this?'.
    The dialog has the info level 'INFO'.
#>



function Show-TUIConfirmationDialog {
    [CmdletBinding()]
    [OutputType([bool])]
    param (
        [string]$Title,
        [string]$Question,
        [string]$InfoLevel
    )

    # Load shared dependency loader if not already available
    if (-not (Get-Command -Name 'Initialize-CmdletDependencies' -ErrorAction SilentlyContinue)) {
        $initScript = Join-Path $PSScriptRoot 'Initialize-CmdletDependencies.ps1'
        if (Test-Path $initScript) {
            . $initScript
        }
        else {
            Write-Warning "Initialize-CmdletDependencies.ps1 not found in $PSScriptRoot"
            Write-Warning 'Falling back to direct download'
            $method = Invoke-RestMethod -Uri 'https://raw.githubusercontent.com/Donovoi/PowerShell-Profile/main/functions/cmdlets/Initialize-CmdletDependencies.ps1'
            $scriptBlock = [scriptblock]::Create($method)
            . $scriptBlock
        }
    }
    
    # Import the required cmdlets
    Initialize-CmdletDependencies -RequiredCmdlets @('Install-Dependencies') -PreferLocal -Force

    # Make sure Microsoft.PowerShell.ConsoleGuiTools is installed
    if (-not(Get-Module 'Microsoft.PowerShell.ConsoleGuiTools' -List)) {
        Install-Dependencies -PSModule 'Microsoft.PowerShell.ConsoleGuiTools'
    }

    # Initialize Terminal.Gui
    $module = (Get-Module Microsoft.PowerShell.ConsoleGuiTools -List).ModuleBase
    Add-Type -Path (Join-Path $module 'Terminal.Gui.dll')
    [Terminal.Gui.Application]::Init()


    # Define the color scheme based on the InfoLevel
    switch ($InfoLevel) {
        'INFO' {
            $colorScheme = [Terminal.Gui.ColorScheme]::new()
            $colorScheme.Normal = [Terminal.Gui.Attribute]::new([ConsoleColor]::White, [ConsoleColor]::Blue)
            $colorScheme.Focus = [Terminal.Gui.Attribute]::new([ConsoleColor]::Blue, [ConsoleColor]::White)
            $colorScheme.HotNormal = [Terminal.Gui.Attribute]::new([ConsoleColor]::White, [ConsoleColor]::Blue)
            $colorScheme.HotFocus = [Terminal.Gui.Attribute]::new([ConsoleColor]::Blue, [ConsoleColor]::White)
            $colorScheme.Disabled = [Terminal.Gui.Attribute]::new([ConsoleColor]::White, [ConsoleColor]::Blue)

        }
        'WARNING' {
            $colorScheme = [Terminal.Gui.ColorScheme]::new()
            $colorScheme.Normal = [Terminal.Gui.Attribute]::new([ConsoleColor]::Black, [ConsoleColor]::Yellow)
            $colorScheme.Focus = [Terminal.Gui.Attribute]::new([ConsoleColor]::Yellow, [ConsoleColor]::Black)
            $colorScheme.HotNormal = [Terminal.Gui.Attribute]::new([ConsoleColor]::Black, [ConsoleColor]::Yellow)
            $colorScheme.HotFocus = [Terminal.Gui.Attribute]::new([ConsoleColor]::Yellow, [ConsoleColor]::Black)
            $colorScheme.Disabled = [Terminal.Gui.Attribute]::new([ConsoleColor]::Black, [ConsoleColor]::Yellow)

        }
        'ERROR' {
            $colorScheme = [Terminal.Gui.ColorScheme]::new()
            $colorScheme.Normal = [Terminal.Gui.Attribute]::new([ConsoleColor]::Black, [ConsoleColor]::Red)
            $colorScheme.Focus = [Terminal.Gui.Attribute]::new([ConsoleColor]::Red, [ConsoleColor]::Black)
            $colorScheme.HotNormal = [Terminal.Gui.Attribute]::new([ConsoleColor]::Black, [ConsoleColor]::Red)
            $colorScheme.HotFocus = [Terminal.Gui.Attribute]::new([ConsoleColor]::Red, [ConsoleColor]::Black)
            $colorScheme.Disabled = [Terminal.Gui.Attribute]::new([ConsoleColor]::Black, [ConsoleColor]::Red)

        }
        'VERBOSE' {
            $colorScheme = [Terminal.Gui.ColorScheme]::new()
            $colorScheme.Normal = [Terminal.Gui.Attribute]::new([ConsoleColor]::Black, [ConsoleColor]::Cyan)
            $colorScheme.Focus = [Terminal.Gui.Attribute]::new([ConsoleColor]::Cyan, [ConsoleColor]::Black)
            $colorScheme.HotNormal = [Terminal.Gui.Attribute]::new([ConsoleColor]::Black, [ConsoleColor]::Cyan)
            $colorScheme.HotFocus = [Terminal.Gui.Attribute]::new([ConsoleColor]::Cyan, [ConsoleColor]::Black)
            $colorScheme.Disabled = [Terminal.Gui.Attribute]::new([ConsoleColor]::Black, [ConsoleColor]::Cyan)

        }
    }

    # Define a dialog
    $dialog = [Terminal.Gui.Dialog]::new()
    $dialog.Title = "$Title`: $InfoLevel"
    $dialog.ColorScheme = $colorScheme

    # Add a label for the question
    $questionLabel = [Terminal.Gui.Label]::new($Question)
    $questionLabel.X = [Terminal.Gui.Pos]::Center()
    $questionLabel.Y = 1 # For simplicity, position it at Y=1
    $dialog.Add($questionLabel)


    # # Add a label for the info level and date/time)
    # $dateTime = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    # $infoLabel = [Terminal.Gui.Label]::new("[$dateTime] $InfoLevel`:")
    # $infoLabel.X = [Terminal.Gui.Pos]::Center()
    # $infoLabel.Y = [Terminal.Gui.Pos]::Top($questionLabel) + 1
    # $infoLabel.TextAlignment = [Terminal.Gui.TextAlignment]::Centered
    # $dialog.Add($infoLabel)



    # # Create a label
    # $label = [Terminal.Gui.Label]::new()
    # $label.X = [Terminal.Gui.Pos]::Center()   # Horizontal center
    # $label.Y = [Terminal.Gui.Pos]::Percent(30) # 20% from the top
    # $label.Width = [Terminal.Gui.Dim]::Fill() # Fill the width of the container
    # $label.Height = 1                         # Height is 1 line
    # # $label.Text = 'Centered Text'
    # $label.TextAlignment = [Terminal.Gui.TextAlignment]::Centered
    # #   $label.ColorScheme = $colorScheme

    # # Add the label to a window or dialog
    # $dialog.Add($label)



    # Add buttons for 'Yes' and 'No' actions
    $yesButton = [Terminal.Gui.Button]::new('Yes')
    $yesButton.X = [Terminal.Gui.Pos]::Percent(30)
    $yesButton.Y = [Terminal.Gui.Pos]::Top($questionLabel) + 2
    $yesButton.Add_Clicked({
            [Terminal.Gui.Application]::RequestStop()
            $dialog.Data = $true
        })
    $dialog.Add($yesButton)

    $noButton = [Terminal.Gui.Button]::new('No')
    $noButton.X = [Terminal.Gui.Pos]::Percent(70)
    $noButton.Y = [Terminal.Gui.Pos]::Top($questionLabel) + 2
    $noButton.Add_Clicked({
            [Terminal.Gui.Application]::RequestStop()
            $dialog.Data = $false
        })
    $dialog.Add($noButton)


    # Display the dialog and run the application
    [Terminal.Gui.Application]::Run($dialog)
    $result = $dialog.Data

    # Clean up
    [Terminal.Gui.Application]::Shutdown()

    # Return the result
    return $result
}