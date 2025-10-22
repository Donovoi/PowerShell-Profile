<#
.SYNOPSIS
    Displays a color gradient with Unicode characters in the console.

.DESCRIPTION
    The Invoke-ConsoleNoise function generates a visual display of Unicode characters with a
    color gradient in the console. The display continues until the user presses 'q'.

    Three color gradient modes are supported:
    - Rainbow: A full spectrum of colors
    - Greyscale: Shades of grey
    - Custom: A smooth custom gradient
    - LolCat: Colorful rainbow effect using the lolcat module

    The function can display either random Unicode characters or a specific character.

.PARAMETER ColorGradient
    Specifies the type of color gradient to display (Rainbow, Greyscale, Custom, LolCat).

.PARAMETER UseRgbColor
    Switch to indicate that the full RGB loop should be used instead of HSL-based gradient.

.PARAMETER UnicodeCharMode
    Specifies the mode for displaying characters (Random or Specific).

.PARAMETER SpecificChar
    The character to display when UnicodeCharMode is set to 'Specific'.

.EXAMPLE
    Invoke-ConsoleNoise -ColorGradient "Rainbow" -UnicodeCharMode "Random"
    Displays a rainbow gradient with random Unicode characters.

.EXAMPLE
    Invoke-ConsoleNoise -ColorGradient "Greyscale" -UnicodeCharMode "Specific" -SpecificChar '★'
    Displays a greyscale gradient with the '★' character.

.NOTES
    Press 'q' to exit the function at any time.
    Requires the Pansies module for RGB color rendering.
    LolCat mode requires the lolcat module.
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

    # Save original console state
    $originalState = Get-ConsoleState

    try {
        # Initialize console settings
        Initialize-Console

        # Ensure required modules are loaded
        $requiredModules = @('Pansies')
        if ($ColorGradient -eq 'LolCat') {
            $requiredModules += 'lolcat'
        }

        foreach ($module in $requiredModules) {
            Import-RequiredModule -ModuleName $module
        }

        # Get display settings
        $displaySettings = Get-DisplayConfiguration
        $consoleWidth = $displaySettings.Width
        $sleepTimeMs = $displaySettings.SleepTimeMs

        # Choose and execute the appropriate display mode
        $displayFunctions = @{
            'RGB'    = { Show-RgbColorDisplay -ConsoleWidth $consoleWidth -SleepTimeMs $sleepTimeMs -UnicodeCharMode $UnicodeCharMode -SpecificChar $SpecificChar }
            'LolCat' = { Show-LolCatDisplay -ConsoleWidth $consoleWidth -SleepTimeMs $sleepTimeMs -UnicodeCharMode $UnicodeCharMode -SpecificChar $SpecificChar }
            'HSL'    = { Show-HslColorDisplay -ColorGradient $ColorGradient -ConsoleWidth $consoleWidth -SleepTimeMs $sleepTimeMs -UnicodeCharMode $UnicodeCharMode -SpecificChar $SpecificChar }
        }

        if ($UseRgbColor) {
            & $displayFunctions['RGB']
        }
        elseif ($ColorGradient -eq 'LolCat') {
            & $displayFunctions['LolCat']
        }
        else {
            & $displayFunctions['HSL']
        }
    }
    catch {
        Write-Error "Error: $($_.Exception.Message)"
    }
    finally {
        # Restore original console state
        Restore-ConsoleState -OriginalState $originalState -ConsoleWidth $consoleWidth

        # Reset PSReadLine completely
        if (Get-Module -Name PSReadLine -ErrorAction Ignore) {
            try {
                # Force complete reset of PSReadLine
                Set-PSReadLineOption -EditMode Windows -ErrorAction SilentlyContinue
                [Microsoft.PowerShell.PSConsoleReadLine]::RevertLine()
            }
            catch {
            }
        }

        # Force new prompt
        Write-Host ''
        
        # Final aggressive buffer clear
        Clear-KeyboardBuffer
        Start-Sleep -Milliseconds 100
        Clear-KeyboardBuffer
    }
}

#region Helper Functions

function Restore-ConsoleState {
    param (
        [Parameter(Mandatory = $true)]
        [hashtable]$OriginalState,

        [Parameter()]
        [int]$ConsoleWidth
    )

    # Aggressive keyboard buffer flush
    Clear-KeyboardBuffer
    Start-Sleep -Milliseconds 150
    Clear-KeyboardBuffer

    # Restore cursor visibility FIRST
    if (($Host.UI.RawUI | Get-Member -Name CursorVisible -MemberType Property) -and
        $OriginalState.ContainsKey('CursorVisible')) {
        $Host.UI.RawUI.CursorVisible = $OriginalState.CursorVisible
    }

    # Clear screen completely
    try {
        Clear-Host
    }
    catch {
        # Fallback: manual clear
        [Console]::Clear()
    }

    # Restore colors
    $Host.UI.RawUI.ForegroundColor = $OriginalState.FgColor
    $Host.UI.RawUI.BackgroundColor = $OriginalState.BgColor

    # Reset console buffer
    try {
        [Console]::ResetColor()
    }
    catch {
    }

    # Final aggressive flush
    Clear-KeyboardBuffer
}

function Get-ConsoleState {
    $state = @{
        FgColor = $Host.UI.RawUI.ForegroundColor
        BgColor = $Host.UI.RawUI.BackgroundColor
    }

    # Only add CursorVisible if the property exists
    if ($Host.UI.RawUI | Get-Member -Name CursorVisible -MemberType Property) {
        $state.CursorVisible = $Host.UI.RawUI.CursorVisible
    }

    return $state
}

function Initialize-Console {
    # Make sure terminal supports unicode characters
    if ($env:TERM_PROGRAM -eq 'vscode') {
        Write-Information 'vscode terminal detected, setting codepage to UTF-8.' -InformationAction Continue
        [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    }

    # Make the cursor invisible during the animation if possible
    if ($Host.UI.RawUI | Get-Member -Name CursorVisible -MemberType Property) {
        $Host.UI.RawUI.CursorVisible = $false
    }
}

function Import-RequiredModule {
    param (
        [string]$ModuleName
    )

    if (-not (Get-Module -ListAvailable -Name $ModuleName)) {
        try {
            Install-Module -Name $ModuleName -Scope CurrentUser -AllowClobber -Force -AllowPrerelease
        }
        catch {
            Write-Error "Error installing $ModuleName module: $($_.Exception.Message)"
            throw
        }
    }
    Import-Module -Name $ModuleName -Force -ErrorAction Stop
}

function Get-DisplayConfiguration {
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

function Get-RandomUnicodeCharacter {
    $ranges = @(
        @{ Start = 0x1F300; End = 0x1F5FF }
    )
    $range = Get-Random -InputObject $ranges
    $codePoint = Get-Random -Minimum $range.Start -Maximum ($range.End + 1)
    return [char]::ConvertFromUtf32($codePoint)
}

function Convert-HslToRgb {
    param (
        [Parameter(Mandatory = $true)][double]$Hue,
        [Parameter(Mandatory = $true)][double]$Saturation,
        [Parameter(Mandatory = $true)][double]$Lightness
    )

    if ($Saturation -eq 0) {
        $r = $g = $b = $Lightness
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

function Clear-KeyboardBuffer {
    # Flush any remaining keys from the input buffer - try multiple methods
    
    # Method 1: Console API
    try {
        $attempts = 0
        while ([Console]::KeyAvailable -and $attempts -lt 100) {
            [Console]::ReadKey($true) | Out-Null
            $attempts++
        }
    }
    catch {
    }

    # Method 2: RawUI
    try {
        $rawUI = $Host.UI.RawUI
        if ($rawUI) {
            $attempts = 0
            while ($rawUI.KeyAvailable -and $attempts -lt 100) {
                $options = [System.Management.Automation.Host.ReadKeyOptions]::NoEcho `
                    -bor [System.Management.Automation.Host.ReadKeyOptions]::IncludeKeyDown
                $rawUI.ReadKey($options) | Out-Null
                $attempts++
            }
        }
    }
    catch {
    }
    
    # Method 3: FlushInputBuffer if available
    try {
        if ([Console]::GetType().GetMethod('FlushInputBuffer')) {
            [Console]::FlushInputBuffer()
        }
    }
    catch {
    }
}

function Get-CharToDisplay {
    param (
        [string]$UnicodeCharMode,
        [char]$SpecificChar
    )

    if ($UnicodeCharMode -eq 'Random') {
        return Get-RandomUnicodeCharacter
    }
    else {
        return [string]$SpecificChar
    }
}

function Test-KeyPress {
    $checkKey = {
        param($character, $virtualKey, $controlState)

        if ($character -eq 'q' -or $character -eq 'Q') {
            return $true
        }

        $ctrlPressed = ($controlState -band `
            ([System.Management.Automation.Host.ControlKeyStates]::LeftCtrlPressed `
                    -bor [System.Management.Automation.Host.ControlKeyStates]::RightCtrlPressed))

        if ($ctrlPressed -and $virtualKey -eq 67) {
            return $true
        }
        return $false
    }

    # Try Console.KeyAvailable first (more reliable)
    try {
        if ([Console]::KeyAvailable) {
            $key = [Console]::ReadKey($true)
            if (&$checkKey $key.KeyChar ([int]$key.Key) 0) {
                return $true
            }
        }
    }
    catch {
        # Fall back to RawUI if Console is not available
        $rawUI = $Host.UI.RawUI
        if ($rawUI -and $rawUI.KeyAvailable) {
            try {
                $options = [System.Management.Automation.Host.ReadKeyOptions]::NoEcho `
                    -bor [System.Management.Automation.Host.ReadKeyOptions]::IncludeKeyDown
                $keyInfo = $rawUI.ReadKey($options)
                if (&$checkKey $keyInfo.Character $keyInfo.VirtualKeyCode $keyInfo.ControlKeyState) {
                    return $true
                }
            }
            catch {
            }
        }
    }

    return $false
}

function Show-RgbColorDisplay {
    param (
        [int]$ConsoleWidth,
        [int]$SleepTimeMs,
        [string]$UnicodeCharMode,
        [char]$SpecificChar
    )

    $gstep = 0.01
    $bstep = 0.02
    $rstep = 0.1
    $r = 255
    $g = 0
    $b = 0

    while (-not (Test-KeyPress)) {
        $color = [PoshCode.Pansies.RgbColor]::new([Math]::Round($r, 2), [Math]::Round($g, 2), [Math]::Round($b, 2))
        $charToDisplay = Get-CharToDisplay -UnicodeCharMode $UnicodeCharMode -SpecificChar $SpecificChar
        $lineToDisplay = $charToDisplay * $ConsoleWidth

        # Only use Write-Host with -ForegroundColor parameter
        Write-Host $lineToDisplay -ForegroundColor $color
        Start-Sleep -Milliseconds $SleepTimeMs

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

function Show-LolCatDisplay {
    param (
        [int]$ConsoleWidth,
        [int]$SleepTimeMs,
        [string]$UnicodeCharMode,
        [char]$SpecificChar
    )

    $charToDisplay = Get-CharToDisplay -UnicodeCharMode $UnicodeCharMode -SpecificChar $SpecificChar

    while (-not (Test-KeyPress)) {
        $lineToDisplay = $charToDisplay * $ConsoleWidth
        $lineToDisplay | lolcat -a
        Start-Sleep -Milliseconds $SleepTimeMs
    }
}

function Show-HslColorDisplay {
    param (
        [string]$ColorGradient,
        [int]$ConsoleWidth,
        [int]$SleepTimeMs,
        [string]$UnicodeCharMode,
        [char]$SpecificChar
    )

    $hue = 0.0
    $sat = 0.8
    $light = 0.5

    while (-not (Test-KeyPress)) {
        if ($ColorGradient -eq 'Greyscale') {
            $light = ($light + 0.01) % 1.0
            $color = Convert-HslToRgb -Hue 0 -Saturation 0 -Lightness $light
        }
        else {
            $hue = ($hue + 0.01) % 1.0
            $color = Convert-HslToRgb -Hue $hue -Saturation $sat -Lightness $light
        }

        $charToDisplay = Get-CharToDisplay -UnicodeCharMode $UnicodeCharMode -SpecificChar $SpecificChar
        $lineToDisplay = $charToDisplay * $ConsoleWidth

        # Only use Write-Host with -ForegroundColor parameter, don't set console properties directly
        Write-Host $lineToDisplay -ForegroundColor $color
        Start-Sleep -Milliseconds $SleepTimeMs
    }
}


#endregion
