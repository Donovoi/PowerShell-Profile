<#
.SYNOPSIS
    Displays a color gradient with random Unicode characters in the console.

.DESCRIPTION
    The Invoke-ConsoleNoise function generates a visual display of Unicode characters with a background
    color gradient in the console using the Pansies module to render RGB colors. Users can choose between
    different color gradients (Rainbow, Greyscale, or Custom) and between random Unicode characters or a specific character.

    In non-RGB mode, the function uses a triple-nested loop to iterate over all possible combinations of
    hue, saturation, and lightness using the smallest increment possible (0.0001). For each fixed hue and saturation,
    all possible light values are rendered. When the light values are exhausted, saturation is incremented by the
    smallest step and the light loop repeats. Once both light and saturation have iterated completely, the hue is incremented,
    and the process repeats until the full range [0,1) for hue, saturation, and lightness is displayed.

    For the 'Greyscale' gradient, the resulting RGB color is averaged to produce shades of grey.

.PARAMETER ColorGradient
    Specifies the type of color gradient to display.
    Options are:
      - Rainbow: A full spectrum of colors.
      - Greyscale: Shades of grey.
      - Custom: A smooth custom gradient (the nested loops will iterate over all HSL values).

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
    Displays a custom gradient using a nested loop that iterates through every combination of hue, saturation,
    and lightness (with extremely fine steps) with random Unicode characters.

.INPUTS
    None. You cannot pipe objects to this function.

.OUTPUTS
    Console output. The function renders colored characters directly to the console.

.NOTES
    This function requires the Pansies module for rendering colors. Ensure that the module is installed.
    Due to the extremely fine HSL step (0.0001), the nested loops will run a huge number of iterations.
    Use with caution or adjust the step values for practical runtimes.

.LINK
    https://www.powershellgallery.com/packages/Pansies

.COMPONENT
    Pansies module for RGB color rendering.
#>
function Invoke-ConsoleNoise {
    [CmdletBinding()]
    param (
        [Parameter()]
        [ValidateSet('Rainbow', 'Greyscale', 'Custom', 'LolCat')]
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

    # Make sure terminal supports unicode characters.
    if ($env:TERM_PROGRAM -eq 'vscode') {
        Write-Information 'vscode terminal detected, setting codepage to UTF-8.' -InformationAction Continue
        [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    }


    try {
        # Ensure any modules are installed and imported.
        $modules = @('Pansies')
        foreach ($module in $modules) {
            if (-not (Get-Module -ListAvailable -Name $module)) {
                try {
                    Install-Module -Name $module -Scope CurrentUser -AllowClobber -Force -AllowPrerelease
                }
                catch {
                    Write-Error "Error installing $module module: $($_.Exception.Message)"
                    return
                }
            }
            Import-Module -Name $module -Force -ErrorAction SilentlyContinue
        }

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

        function Get-DisplayConfiguration {
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
        $displaySettings = Get-DisplayConfiguration
        $consoleWidth = $displaySettings.Width
        $sleepTimeMs = $displaySettings.SleepTimeMs

        if ($UseRgbColor) {
            # Full RGB mode: iterate over all 256 values for each channel.
            # Use a more efficient approach to cycle through colors
            $gstep = 0.01
            $bstep = 0.02
            $rstep = 0.1  # Larger step size for faster color changes
            $r = 255
            $g = 0
            $b = 0

            while ($true) {
                # Create RGB color
                $color = [PoshCode.Pansies.RgbColor]::new([Math]::Round($r, 2), [Math]::Round($g, 2), [Math]::Round($b, 2))

                # Display character
                $charToDisplay = if ($UnicodeCharMode -eq 'Random') {
                    Get-RandomUnicodeCharacter
                }
                else {
                    [string]$SpecificChar
                }
                $lineToDisplay = $charToDisplay * $consoleWidth

                $originalColor = $Host.UI.RawUI.ForegroundColor
                $Host.UI.RawUI.ForegroundColor = $color
                Write-Host $lineToDisplay -ForegroundColor $color
                Start-Sleep -Milliseconds $sleepTimeMs

                # Increment green channel
                $g += $gstep
                if ($g -eq 255) {
                    $g = 0
                }
                $b += $bstep
                if ($b -eq 255) {
                    $b = 0
                }
                $r -= $rstep
                if ($r -eq 0) {
                    $r = 255
                }
            }


        }
        elseif ($ColorGradient -eq 'LolCat') {
            $modules = @('lolcat')
            foreach ($module in $modules) {
                if (-not (Get-Module -ListAvailable -Name $module)) {
                    try {
                        Install-Module -Name $module -Scope CurrentUser -AllowClobber -Force -AllowPrerelease
                    }
                    catch {
                        Write-Error "Error installing $module module: $($_.Exception.Message)"
                        return
                    }
                }
                Import-Module -Name $module -Force -ErrorAction SilentlyContinue
            }

            # pipe the character to the lolcat command for a rainbow effect.
            $charToDisplay = if ($UnicodeCharMode -eq 'Random') {
                Get-RandomUnicodeCharacter
            }
            else {
                [string]$SpecificChar
            }
            while ($true) {
                $lineToDisplay = $charToDisplay * $consoleWidth
                $lineToDisplay | lolcat -a
                Start-Sleep -Milliseconds $sleepTimeMs
            }

        }
        else {
            # Create a more controlled gradient pattern
            $hue = 0.0
            $sat = 0.8  # Fixed saturation for better color transitions
            $light = 0.5  # Fixed lightness for better color transitions
            
            # Use a simpler approach with a single loop for smoother transitions
            while ($true) {
                if ($ColorGradient -eq 'Greyscale') {
                    # For greyscale, cycle through lightness only
                    $light = ($light + 0.01) % 1.0
                    $color = Convert-HslToRgb -Hue 0 -Saturation 0 -Lightness $light
                }
                else {
                    # For rainbow/custom, cycle through hues with fixed saturation and lightness
                    $hue = ($hue + 0.01) % 1.0
                    $color = Convert-HslToRgb -Hue $hue -Saturation $sat -Lightness $light
                }
                
                $charToDisplay = if ($UnicodeCharMode -eq 'Random') {
                    Get-RandomUnicodeCharacter
                }
                else {
                    [string]$SpecificChar
                }
                $lineToDisplay = $charToDisplay * $consoleWidth
                
                # Replace Write-Host with Write-Host
                Write-Host $lineToDisplay -ForegroundColor $color
                # Sleep for a short duration to control the speed of the gradient
                Start-Sleep -Milliseconds $sleepTimeMs
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