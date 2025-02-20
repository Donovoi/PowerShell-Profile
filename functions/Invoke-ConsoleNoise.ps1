<#
.SYNOPSIS
    Displays a color gradient with random Unicode characters in the console.

.DESCRIPTION
    The Invoke-ConsoleNoise function generates a visual display of Unicode characters with a background
    color gradient in the console using the Pansies module to render RGB colors. Users can choose between
    different color gradients (Rainbow, Greyscale, or Custom) and between random Unicode characters or a specific character.
    
    The "Custom" gradient now uses very small HSL increments. It starts at a bright red and over many iterations
    gradually changes to a darker red that eventually turns purple. This yields a smooth, pleasing visual transition.

.PARAMETER ColorGradient
    Specifies the type of color gradient to display.
    Options are:
      - Rainbow: A full spectrum of colors.
      - Greyscale: Shades of grey.
      - Custom: A smooth custom gradient from red to darker red to purple.

.PARAMETER UseRgbColor
    Switch to indicate that the full RGB loop should be used (iterating through all 256 values for red, green, and blue).
    If not specified, an HSL-based gradient is used.

.PARAMETER UnicodeCharMode
    Specifies the mode for displaying characters.
    Options are:
      - Random: Display random Unicode characters.
      - Specific: Display a specific character provided by the user.

.PARAMETER SpecificChar
    Specifies the specific character to display when UnicodeCharMode is set to 'Specific'.
    This parameter is ignored if UnicodeCharMode is 'Random'. The default is a solid block.

.EXAMPLE
    Invoke-ConsoleNoise -ColorGradient "Rainbow" -UnicodeCharMode "Random"
    Displays a full-spectrum rainbow gradient with random Unicode characters using HSL conversion.

.EXAMPLE
    Invoke-ConsoleNoise -ColorGradient "Greyscale" -UnicodeCharMode "Specific" -SpecificChar '★'
    Displays a greyscale gradient with the '★' character using HSL conversion.

.EXAMPLE
    Invoke-ConsoleNoise -ColorGradient "Custom" -UnicodeCharMode "Random"
    Displays a custom gradient that transitions very slightly from red to a darker red and eventually purple,
    with random Unicode characters.
    
.INPUTS
    None. You cannot pipe objects to this function.

.OUTPUTS
    Console output. The function renders colored characters directly to the console.

.NOTES
    This function requires the Pansies module for rendering colors. Ensure that the module is installed.
    The function demonstrates PowerShell's dynamic console output and smooth color transitions.
    
.LINK
    https://www.powershellgallery.com/packages/Pansies

.COMPONENT
    Pansies module for RGB color rendering.
#>
function Invoke-ConsoleNoise {
    [CmdletBinding()]
    param (
        [Parameter()]
        [ValidateSet('Rainbow', 'Greyscale', 'Custom')]
        [string]$ColorGradient = 'Rainbow',

        [Parameter()]
        [switch]$UseRgbColor,

        [Parameter()]
        [ValidateSet('Random', 'Specific')]
        [string]$UnicodeCharMode = 'Specific',

        [Parameter()]
        [char]$SpecificChar = [char]0x2588
    )

    # Save original console colors to restore later.
    $originalFgColor = $Host.UI.RawUI.ForegroundColor
    $originalBgColor = $Host.UI.RawUI.BackgroundColor

    try {
        # Ensure the Pansies module is available and imported.
        if (-not (Get-Module -ListAvailable -Name Pansies)) {
            try {
                Install-Module -Name Pansies -Scope CurrentUser -AllowClobber -Force -AllowPrerelease
            }
            catch {
                Write-Error "Error installing Pansies module: $($_.Exception.Message)"
                return
            }
        }
        Import-Module Pansies -Force

        # -------------------------------
        # Local helper functions
        # -------------------------------

        function Get-RandomUnicodeCharacter {
            <#
            .SYNOPSIS
                Returns a random Unicode character from a predefined range.
            #>
            # Define a Unicode range (for example, miscellaneous symbols and pictographs)
            $ranges = @(
                @{ Start = 0x1F300; End = 0x1F5FF }
            )
            $range = Get-Random -InputObject $ranges
            $codePoint = Get-Random -Minimum $range.Start -Maximum ($range.End + 1)
            return [char]::ConvertFromUtf32($codePoint)
        }

        function Convert-HslToRgb {
            <#
            .SYNOPSIS
                Converts HSL color values to an RGB color.
            .PARAMETER Hue
                Hue value as a fraction between 0 and 1.
            .PARAMETER Saturation
                Saturation value as a fraction between 0 and 1.
            .PARAMETER Lightness
                Lightness value as a fraction between 0 and 1.
            .OUTPUTS
                An instance of [PoshCode.Pansies.RgbColor] representing the RGB color.
            #>
            param (
                [Parameter(Mandatory = $true)][double]$Hue,
                [Parameter(Mandatory = $true)][double]$Saturation,
                [Parameter(Mandatory = $true)][double]$Lightness
            )
            if ($Saturation -eq 0) {
                $r = $Lightness
                $g = $Lightness
                $b = $Lightness
            }
            else {
                $hue2rgb = {
                    param($p, $q, $t)
                    if ($t -lt 0) {
                        $t += 1 
                    }
                    if ($t -gt 1) {
                        $t -= 1 
                    }
                    if ($t -lt 1 / 6) {
                        return $p + ($q - $p) * 6 * $t 
                    }
                    if ($t -lt 1 / 2) {
                        return $q 
                    }
                    if ($t -lt 2 / 3) {
                        return $p + ($q - $p) * (2 / 3 - $t) * 6 
                    }
                    return $p
                }
                $q = if ($Lightness -lt 0.5) {
                    $Lightness * (1 + $Saturation) 
                }
                else {
                    $Lightness + $Saturation - $Lightness * $Saturation 
                }
                $p = 2 * $Lightness - $q
                $r = & $hue2rgb $p $q ($Hue + 1 / 3)
                $g = & $hue2rgb $p $q $Hue
                $b = & $hue2rgb $p $q ($Hue - 1 / 3)
            }
            $r = [math]::Round($r * 255)
            $g = [math]::Round($g * 255)
            $b = [math]::Round($b * 255)
            return [PoshCode.Pansies.RgbColor]::new($r, $g, $b)
        }

        function Get-DisplaySettings {
            <#
            .SYNOPSIS
                Retrieves console width and calculates sleep time based on the monitor's refresh rate.
            .OUTPUTS
                A hashtable with keys 'Width' and 'SleepTimeMs'.
            #>
            $width = $Host.UI.RawUI.WindowSize.Width
            $videoControllers = Get-CimInstance -Namespace 'root\CIMV2' -Query 'SELECT * FROM Win32_VideoController'
            $refreshRate = 60  # default
            if ($videoControllers -and $videoControllers.CurrentRefreshRate) {
                $refreshRate = ($videoControllers.CurrentRefreshRate | Where-Object { $_ -gt 0 } | Select-Object -First 1) -as [int]
                if (-not $refreshRate) {
                    $refreshRate = 60 
                }
            }
            $sleepTimeMs = [math]::Round(1000 / $refreshRate)
            return @{ Width = $width; SleepTimeMs = $sleepTimeMs }
        }

        # -------------------------------
        # Main display logic
        # -------------------------------
        $displaySettings = Get-DisplaySettings
        $consoleWidth = $displaySettings.Width
        $sleepTimeMs = $displaySettings.SleepTimeMs

        if ($UseRgbColor) {
            # If using full RGB mode, iterate over all 256 values for each channel.
            for ($r = 0; $r -le 255; $r++) {
                for ($g = 0; $g -le 255; $g++) {
                    for ($b = 0; $b -le 255; $b++) {
                        $color = [PoshCode.Pansies.RgbColor]::new($r, $g, $b)
                        $charToDisplay = if ($UnicodeCharMode -eq 'Random') {
                            Get-RandomUnicodeCharacter 
                        }
                        else {
                            [string]$SpecificChar 
                        }
                        $lineToDisplay = $charToDisplay * $consoleWidth
                        Write-Host $lineToDisplay -ForegroundColor $color
                        Start-Sleep -Milliseconds $sleepTimeMs
                    }
                }
            }
        }
        else {
            if ($ColorGradient -eq 'Custom') {
                # Custom gradient: smoothly transition from red to darker red and finally toward purple.
                $startHue = 0.0         # Red
                $endHue = 0.75        # Approximate purple
                $startLightness = 0.5         # Bright red
                $endLightness = 0.3         # Darker red/purple
                $totalSteps = 750         # Many iterations for a smooth change
                for ($i = 0; $i -le $totalSteps; $i++) {
                    $currentHue = $startHue + ($i * (($endHue - $startHue) / $totalSteps))
                    $currentLightness = $startLightness + ($i * (($endLightness - $startLightness) / $totalSteps))
                    $color = Convert-HslToRgb -Hue $currentHue -Saturation 1 -Lightness $currentLightness
                    $charToDisplay = if ($UnicodeCharMode -eq 'Random') {
                        Get-RandomUnicodeCharacter 
                    }
                    else {
                        [string]$SpecificChar 
                    }
                    $lineToDisplay = $charToDisplay * $consoleWidth
                    Write-Host $lineToDisplay -ForegroundColor $color
                    Start-Sleep -Milliseconds $sleepTimeMs
                }
            }
            else {
                # For Rainbow or Greyscale, iterate through the full HSL spectrum in very small increments.
                $hue = 0.001
                $sat = 0.001
                $light = 0.001
                while ($hue -lt 1 -and $sat -lt 1 -and $light -lt 1) {
                    $color = Convert-HslToRgb -Hue $hue -Saturation $sat -Lightness $light
                    if ($ColorGradient -eq 'Greyscale') {
                        # Convert to greyscale by averaging RGB components.
                        $avg = [math]::Round((($color.Red + $color.Green + $color.Blue) / 3))
                        $color = [PoshCode.Pansies.RgbColor]::new($avg, $avg, $avg)
                    }
                    $charToDisplay = if ($UnicodeCharMode -eq 'Random') {
                        Get-RandomUnicodeCharacter 
                    }
                    else {
                        [string]$SpecificChar 
                    }
                    $lineToDisplay = $charToDisplay * $consoleWidth
                    Write-Host $lineToDisplay -ForegroundColor $color
                    Start-Sleep -Milliseconds $sleepTimeMs
                    $hue += 0.0001
                    $sat += 0.0001
                    $light += 0.0001
                }
            }
        }
    }
    catch {
        Write-Error "Error: $($_.Exception.Message)"
    }
    finally {
        # Restore the original console colors and clear the host.
        $Host.UI.RawUI.ForegroundColor = $originalFgColor
        $Host.UI.RawUI.BackgroundColor = $originalBgColor
        Clear-Host
    }
}
