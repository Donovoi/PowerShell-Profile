<#
.SYNOPSIS
    Displays a color gradient with random Unicode characters in the console.

.DESCRIPTION
    The Invoke-ConsoleNoise function generates a visual display of random Unicode characters
    with a background of a color gradient in the console. It uses the Pansies module to render RGB colors.
    Users can select between different color gradients (Rainbow, Greyscale, or Custom) and choose
    between random Unicode characters or a specific character.

.PARAMETER ColorGradient
    Specifies the type of color gradient to display.
    Options are:
    - Rainbow: A full spectrum of colors.
    - Greyscale: Shades of grey.
    - Custom: User-defined gradient (requires additional implementation).

.PARAMETER UnicodeCharMode
    Specifies the mode for displaying characters.
    Options are:
    - Random: Display random Unicode characters.
    - Specific: Display a specific character provided by the user.

.PARAMETER SpecificChar
    Specifies the specific character to display when UnicodeCharMode is set to 'Specific'.
    This parameter is ignored if UnicodeCharMode is 'Random'.

.EXAMPLE
    Invoke-ConsoleNoise -ColorGradient "Rainbow" -UnicodeCharMode "Random"
    This example displays a rainbow gradient with random Unicode characters.

.EXAMPLE
    Invoke-ConsoleNoise -ColorGradient "Greyscale" -UnicodeCharMode "Specific" -SpecificChar '★'
    This example displays a greyscale gradient with the '★' character.

.INPUTS
    None. You cannot pipe objects to Invoke-ConsoleNoise.

.OUTPUTS
    Console output. The function renders colored characters directly to the console.

.NOTES
    This function requires the Pansies module to render RGB colors in the console.
    Make sure the module is installed and imported before using this function.
    The function is designed to demonstrate PowerShell's capability to generate visually
    pleasing console outputs and is not optimized for performance.

.LINK
    https://www.powershellgallery.com/packages/Pansies

.COMPONENT
    Requires Pansies module for rendering colors.

#>
function Invoke-ConsoleNoise {
    [CmdletBinding()]
    param (
        [Parameter()]
        [ValidateSet('Rainbow', 'Greyscale', 'Custom')]
        [string]$ColorGradient = 'Rainbow',

        [Parameter()]
        [ValidateSet('Random', 'Specific')]
        [string]$UnicodeCharMode = 'Specific',

        [Parameter()]
        $SpecificChar = [char]0x2588
    )
    # Array of block characters for gradient using Unicode escape sequences
    #$blockChars = @(, [char]0x2592, [char]0x2593, [char]0x2588)
    # Ensure the Pansies module is installed and imported
    try {
        if (-not (Get-Module -ListAvailable -Name Pansies)) {
            Install-Module -Name Pansies -Scope CurrentUser
        }
        Import-Module Pansies
    }
    catch {
        Write-Error "Error importing Pansies module. Please ensure it's installed."
        exit
    }

    function Get-RandomUnicodeCharacter {
        # Define Unicode ranges for non-letter characters
        $ranges = @(
            @{Start = 0x1F300; End = 0x1F5FF }
        )

        $range = Get-Random -InputObject $ranges
        $codePoint = Get-Random -Minimum $range.Start -Maximum $range.End
        return [char]::ConvertFromUtf32($codePoint)
    }

    function Invoke-ColorGradient {
        [CmdletBinding()]
        param (
            [Parameter(Mandatory)]
            [int]$Red,
    
            [Parameter(Mandatory)]
            [int]$Green,
    
            [Parameter(Mandatory)]
            [int]$Blue
        )
        switch ($ColorGradient) {
            'Rainbow' {
                return [PoshCode.Pansies.RgbColor]::new($Red, $Green, $Blue)
            }
            'Greyscale' {
                $grey = [int](($Red + $Green + $Blue) / 3)
                return [PoshCode.Pansies.RgbColor]::new($grey, $grey, $grey)
            }
            'Custom' {
                # Custom color logic can be added here
            }
        }
    }
    $consoleWidth = $Host.UI.RawUI.WindowSize.Width
    for ($r = 0; $r -le 255; $r++) {
        for ($g = 0; $g -le 255; $g++) {
            for ($b = 0; $b -le 255; $b++) {
                $color = Invoke-ColorGradient -Red $r -Green $g -Blue $b
                # Define your specific character or get a random Unicode character based on the mode
                $charToDisplay = if ($UnicodeCharMode -eq 'Random') {
                    Get-RandomUnicodeCharacter # Assuming this is a function that returns a single character
                }
                else {
                    [string]$SpecificChar
                }
                # Create a string that repeats the character to fill the entire width of the console
                $lineToDisplay = $charToDisplay * $consoleWidth
                # Write the line to the console
                Write-Host $lineToDisplay -ForegroundColor $color
            }
        }
    }
}
