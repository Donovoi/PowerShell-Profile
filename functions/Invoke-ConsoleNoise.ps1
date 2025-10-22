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

.PARAMETER DebugCleanup
    Shows detailed debug output during cleanup to diagnose terminal input issues.

.EXAMPLE
    Invoke-ConsoleNoise -ColorGradient "Rainbow" -UnicodeCharMode "Random"
    Displays a rainbow gradient with random Unicode characters.

.EXAMPLE
    Invoke-ConsoleNoise -ColorGradient "Greyscale" -UnicodeCharMode "Specific" -SpecificChar '★'
    Displays a greyscale gradient with the '★' character.

.EXAMPLE
    Invoke-ConsoleNoise -DebugCleanup
    Run with debug output to troubleshoot terminal input issues after exit.

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
        [char]$SpecificChar = [char]0x2588,

        [Parameter()]
        [switch]$DebugCleanup
    )

    $originalState = Get-ConsoleState

    try {
        Initialize-Console

        $requiredModules = @('Pansies')
        if ($ColorGradient -eq 'LolCat') {
            $requiredModules += 'lolcat'
        }

        foreach ($module in $requiredModules) {
            Import-RequiredModule -ModuleName $module
        }

        $displaySettings = Get-DisplayConfiguration
        $consoleWidth = $displaySettings.Width
        $sleepTimeMs = $displaySettings.SleepTimeMs

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
        # Suspend PSReadLine FIRST to prevent prompt interference
        $psrlSuspended = $false
        if (Get-Module -Name PSReadLine -ErrorAction Ignore) {
            try {
                [Microsoft.PowerShell.PSConsoleReadLine]::Suspend()
                $psrlSuspended = $true
                if ($DebugCleanup) {
                    [Console]::WriteLine("`n[DEBUG] PSReadLine suspended")
                }
            }
            catch {
                if ($DebugCleanup) {
                    [Console]::WriteLine("[DEBUG] Could not suspend PSReadLine: $($_.Exception.Message)")
                }
            }
        }
        
        if ($DebugCleanup) {
            [Console]::WriteLine('[DEBUG] Starting cleanup process...')
        }
        
        Restore-ConsoleState -OriginalState $originalState -ConsoleWidth $consoleWidth -DebugMode:$DebugCleanup

        if ($DebugCleanup) {
            [Console]::WriteLine('[DEBUG] Checking PSReadLine module...')
        }
        
        if (Get-Module -Name PSReadLine -ErrorAction Ignore) {
            if ($DebugCleanup) {
                [Console]::WriteLine('[DEBUG] PSReadLine module found, attempting reset...')
            }
            try {
                if ($DebugCleanup) {
                    [Console]::WriteLine('[DEBUG] Setting EditMode to Windows...')
                }
                Set-PSReadLineOption -EditMode Windows -ErrorAction SilentlyContinue
                
                if ($DebugCleanup) {
                    [Console]::WriteLine('[DEBUG] Calling RevertLine...')
                }
                [Microsoft.PowerShell.PSConsoleReadLine]::RevertLine()
                
                if ($DebugCleanup) {
                    [Console]::WriteLine('[DEBUG] PSReadLine reset complete')
                }
            }
            catch {
                if ($DebugCleanup) {
                    [Console]::WriteLine("[DEBUG] PSReadLine reset error: $($_.Exception.Message)")
                }
            }
        }
        else {
            if ($DebugCleanup) {
                [Console]::WriteLine('[DEBUG] PSReadLine module not loaded')
            }
        }

        if ($DebugCleanup) {
            [Console]::WriteLine('[DEBUG] Writing new line...')
        }
        [Console]::WriteLine()
        
        if ($DebugCleanup) {
            [Console]::WriteLine('[DEBUG] Final buffer clear (1/2)...')
        }
        Clear-KeyboardBuffer -DebugMode:$DebugCleanup
        Start-Sleep -Milliseconds 100
        
        if ($DebugCleanup) {
            [Console]::WriteLine('[DEBUG] Final buffer clear (2/2)...')
        }
        Clear-KeyboardBuffer -DebugMode:$DebugCleanup
        
        if ($DebugCleanup) {
            [Console]::WriteLine('[DEBUG] Cleanup complete. Testing keyboard input...')
            [Console]::WriteLine("[DEBUG] Console.KeyAvailable: $([Console]::KeyAvailable)")
            [Console]::WriteLine("[DEBUG] RawUI.KeyAvailable: $($Host.UI.RawUI.KeyAvailable)")
        }
        
        # Force all pending output to complete
        [Console]::Out.Flush()
        Start-Sleep -Milliseconds 100
        
        # Now clear the screen
        if (-not $DebugCleanup) {
            try {
                Clear-Host
            }
            catch {
                [Console]::Clear()
            }
        }
        
        # Resume PSReadLine if we suspended it
        if ($psrlSuspended) {
            try {
                if ($DebugCleanup) {
                    [Console]::WriteLine('[DEBUG] Resuming PSReadLine...')
                }
                [Microsoft.PowerShell.PSConsoleReadLine]::Resume()
                if ($DebugCleanup) {
                    [Console]::WriteLine('[DEBUG] PSReadLine resumed')
                }
            }
            catch {
                if ($DebugCleanup) {
                    [Console]::WriteLine("[DEBUG] Could not resume PSReadLine: $($_.Exception.Message)")
                }
            }
        }
    }
}

function Restore-ConsoleState {
    param (
        [Parameter(Mandatory = $true)]
        [hashtable]$OriginalState,
        [Parameter()]
        [int]$ConsoleWidth,
        [Parameter()]
        [switch]$DebugMode
    )

    if ($DebugMode) {
        [Console]::WriteLine('[DEBUG] Restore-ConsoleState: Starting buffer flush (1/2)...')
    }
    Clear-KeyboardBuffer -DebugMode:$DebugMode
    Start-Sleep -Milliseconds 150
    
    if ($DebugMode) {
        [Console]::WriteLine('[DEBUG] Restore-ConsoleState: Starting buffer flush (2/2)...')
    }
    Clear-KeyboardBuffer -DebugMode:$DebugMode

    if (($Host.UI.RawUI | Get-Member -Name CursorVisible -MemberType Property) -and
        $OriginalState.ContainsKey('CursorVisible')) {
        if ($DebugMode) {
            [Console]::WriteLine("[DEBUG] Restore-ConsoleState: Restoring cursor visibility to $($OriginalState.CursorVisible)...")
        }
        $Host.UI.RawUI.CursorVisible = $OriginalState.CursorVisible
    }

    # Don't clear screen yet - wait until all cleanup is done

    if ($DebugMode) {
        [Console]::WriteLine("[DEBUG] Restore-ConsoleState: Restoring colors (FG: $($OriginalState.FgColor), BG: $($OriginalState.BgColor))...")
    }
    $Host.UI.RawUI.ForegroundColor = $OriginalState.FgColor
    $Host.UI.RawUI.BackgroundColor = $OriginalState.BgColor

    try {
        if ($DebugMode) {
            [Console]::WriteLine('[DEBUG] Restore-ConsoleState: Calling Console.ResetColor()...')
        }
        [Console]::ResetColor()
    }
    catch {
        if ($DebugMode) {
            [Console]::WriteLine("[DEBUG] Restore-ConsoleState: Console.ResetColor() error: $($_.Exception.Message)")
        }
    }

    if ($DebugMode) {
        [Console]::WriteLine('[DEBUG] Restore-ConsoleState: Final buffer flush...')
    }
    Clear-KeyboardBuffer -DebugMode:$DebugMode
    
    if ($DebugMode) {
        [Console]::WriteLine('[DEBUG] Restore-ConsoleState: Complete')
    }
    
    # Force output flush before returning
    [Console]::Out.Flush()
}

function Get-ConsoleState {
    $state = @{
        FgColor = $Host.UI.RawUI.ForegroundColor
        BgColor = $Host.UI.RawUI.BackgroundColor
    }

    if ($Host.UI.RawUI | Get-Member -Name CursorVisible -MemberType Property) {
        $state.CursorVisible = $Host.UI.RawUI.CursorVisible
    }

    return $state
}

function Initialize-Console {
    if ($env:TERM_PROGRAM -eq 'vscode') {
        [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    }

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
    $refreshRate = 60
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
    param (
        [Parameter()]
        [switch]$DebugMode
    )
    
    try {
        if ($DebugMode) {
            [Console]::WriteLine('[DEBUG] Clear-KeyboardBuffer: Method 1 (Console API)...')
        }
        $attempts = 0
        $keysCleared = 0
        while ([Console]::KeyAvailable -and $attempts -lt 100) {
            [Console]::ReadKey($true) | Out-Null
            $attempts++
            $keysCleared++
        }
        if ($DebugMode) {
            [Console]::WriteLine("[DEBUG] Clear-KeyboardBuffer: Method 1 cleared $keysCleared keys in $attempts attempts")
        }
    }
    catch {
        if ($DebugMode) {
            [Console]::WriteLine("[DEBUG] Clear-KeyboardBuffer: Method 1 error: $($_.Exception.Message)")
        }
    }

    try {
        if ($DebugMode) {
            [Console]::WriteLine('[DEBUG] Clear-KeyboardBuffer: Method 2 (RawUI)...')
        }
        $rawUI = $Host.UI.RawUI
        if ($rawUI) {
            $attempts = 0
            $keysCleared = 0
            while ($rawUI.KeyAvailable -and $attempts -lt 100) {
                $options = [System.Management.Automation.Host.ReadKeyOptions]::NoEcho -bor [System.Management.Automation.Host.ReadKeyOptions]::IncludeKeyDown
                $rawUI.ReadKey($options) | Out-Null
                $attempts++
                $keysCleared++
            }
            if ($DebugMode) {
                [Console]::WriteLine("[DEBUG] Clear-KeyboardBuffer: Method 2 cleared $keysCleared keys in $attempts attempts")
            }
        }
    }
    catch {
        if ($DebugMode) {
            [Console]::WriteLine("[DEBUG] Clear-KeyboardBuffer: Method 2 error: $($_.Exception.Message)")
        }
    }
    
    try {
        if ($DebugMode) {
            [Console]::WriteLine('[DEBUG] Clear-KeyboardBuffer: Method 3 (FlushInputBuffer)...')
        }
        $method = [Console]::GetType().GetMethod('FlushInputBuffer')
        if ($method) {
            if ($DebugMode) {
                [Console]::WriteLine('[DEBUG] Clear-KeyboardBuffer: FlushInputBuffer method found, invoking...')
            }
            [Console]::FlushInputBuffer()
            if ($DebugMode) {
                [Console]::WriteLine('[DEBUG] Clear-KeyboardBuffer: FlushInputBuffer successful')
            }
        }
        else {
            if ($DebugMode) {
                [Console]::WriteLine('[DEBUG] Clear-KeyboardBuffer: FlushInputBuffer method not available')
            }
        }
    }
    catch {
        if ($DebugMode) {
            [Console]::WriteLine("[DEBUG] Clear-KeyboardBuffer: Method 3 error: $($_.Exception.Message)")
        }
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

        $ctrlPressed = ($controlState -band ([System.Management.Automation.Host.ControlKeyStates]::LeftCtrlPressed -bor [System.Management.Automation.Host.ControlKeyStates]::RightCtrlPressed))

        if ($ctrlPressed -and $virtualKey -eq 67) {
            return $true
        }
        return $false
    }

    try {
        if ([Console]::KeyAvailable) {
            $key = [Console]::ReadKey($true)
            if (&$checkKey $key.KeyChar ([int]$key.Key) 0) {
                return $true
            }
        }
    }
    catch {
        $rawUI = $Host.UI.RawUI
        if ($rawUI -and $rawUI.KeyAvailable) {
            try {
                $options = [System.Management.Automation.Host.ReadKeyOptions]::NoEcho -bor [System.Management.Automation.Host.ReadKeyOptions]::IncludeKeyDown
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

        Write-Host $lineToDisplay -ForegroundColor $color
        Start-Sleep -Milliseconds $SleepTimeMs
    }
}
