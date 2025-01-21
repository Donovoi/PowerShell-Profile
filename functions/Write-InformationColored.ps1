function Write-InformationColored {
    [CmdletBinding(DefaultParameterSetName = 'DisplayMessage')]
    param (
        # Parameter set for displaying the message with colors
        [Parameter(Mandatory = $true, Position = 0, ParameterSetName = 'DisplayMessage')]
        [string]$MessageData,

        [Parameter(Position = 1, ParameterSetName = 'DisplayMessage')]
        [string]$ForegroundColor = 'White',

        [Parameter(Position = 2, ParameterSetName = 'DisplayMessage')]
        [string]$BackgroundColor = 'Black',

        [Parameter(ParameterSetName = 'DisplayMessage')]
        [switch]$NoNewline,

        # Parameter set for listing available colors
        [Parameter(Mandatory = $true, ParameterSetName = 'ListColors')]
        [switch]$ListColors
    )

    # Retrieve all available console colors
    $availableColors = [System.Enum]::GetNames([System.ConsoleColor])

    if ($ListColors) {
        # Display all available colors with visual samples
        foreach ($color in $availableColors) {
            Write-Host "$color" -ForegroundColor $color
        }
        return
    }

    # Validate ForegroundColor
    if (-not $availableColors -contains $ForegroundColor) {
        Write-Error "Invalid ForegroundColor: '$ForegroundColor'. Use -ListColors to see available options."
        return
    }

    # Validate BackgroundColor
    if (-not $availableColors -contains $BackgroundColor) {
        Write-Error "Invalid BackgroundColor: '$BackgroundColor'. Use -ListColors to see available options."
        return
    }

    # Convert color names to ConsoleColor enum
    $fgColor = [System.Enum]::Parse([System.ConsoleColor], $ForegroundColor)
    $bgColor = [System.Enum]::Parse([System.ConsoleColor], $BackgroundColor)

    # Create HostInformationMessage object
    $msg = [System.Management.Automation.HostInformationMessage]@{
        Message         = $MessageData
        ForegroundColor = $fgColor
        BackgroundColor = $bgColor
        NoNewline       = $NoNewline.IsPresent
    }

    # Write the informational message
    Write-Information -MessageData $msg
}
