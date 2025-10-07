<#
.SYNOPSIS
    Writes colored information messages to the information stream.

.DESCRIPTION
    Writes messages to the PowerShell information stream with custom foreground and background colors.
    Provides better visibility than standard Write-Information by supporting colored output.
    Can also list all available console colors.

.PARAMETER MessageData
    The message text to display. This is the actual content that will be written.

.PARAMETER ForegroundColor
    The text color. Valid values are standard console colors (e.g., 'White', 'Green', 'Red', 'Yellow').
    Default is 'White'.

.PARAMETER BackgroundColor
    The background color. Valid values are standard console colors.
    Default is 'Black'.

.PARAMETER NoNewline
    If specified, does not add a newline character after the message.
    Useful for building output on a single line.

.PARAMETER ListColors
    When specified, displays a list of all available console colors with examples.
    This parameter belongs to a separate parameter set and cannot be used with MessageData.

.EXAMPLE
    Write-InformationColored -MessageData 'Success!' -ForegroundColor Green
    
    Writes 'Success!' in green text on black background.

.EXAMPLE
    Write-InformationColored -MessageData 'Warning!' -ForegroundColor Yellow -BackgroundColor Red
    
    Writes 'Warning!' in yellow text on red background.

.EXAMPLE
    Write-InformationColored -ListColors
    
    Displays all available console colors.

.EXAMPLE
    Write-InformationColored 'Processing' -NoNewline
    # Do some work...
    Write-InformationColored ' Complete!' -ForegroundColor Green
    
    Builds output on single line: 'Processing Complete!' (with 'Complete!' in green).

.OUTPUTS
    System.Management.Automation.InformationRecord
    
    Writes to the information stream which can be captured with -InformationVariable.

.NOTES
    Uses VT100 escape sequences for color formatting.
    Requires PowerShell 5.1+ for information stream support.
#>
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
            [System.Console]::ForegroundColor = [System.ConsoleColor]::Parse([System.ConsoleColor], $color)
            [System.Console]::WriteLine("$color")
        }
        [System.Console]::ResetColor()
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

    # Set console colors
    [System.Console]::ForegroundColor = $fgColor
    [System.Console]::BackgroundColor = $bgColor

    # Write the message
    if ($NoNewline) {
        Clear-CurrentLine
        [System.Console]::Write($MessageData)
    }
    else {
        Clear-CurrentLine
        [System.Console]::WriteLine($MessageData)
    }

    # Reset console colors to defaults
    [System.Console]::ResetColor()
}

function Clear-CurrentLine {
    # Get current vertical cursor position
    $cursorTop = [Console]::CursorTop

    # Move cursor to column 0 of the current line
    [Console]::SetCursorPosition(0, $cursorTop)

    # Overwrite the entire console width with spaces
    $lineWidth = [Console]::WindowWidth
    [Console]::Write(' ' * $lineWidth)

    # Move cursor back to column 0 of the same line
    [Console]::SetCursorPosition(0, $cursorTop)
}
