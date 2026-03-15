<#
.SYNOPSIS
    Renders an in-place animated Unicode gradient in the console.

.DESCRIPTION
    Invoke-ConsoleNoise renders a full-frame console animation without
    scrolling the viewport. Each frame is drawn in place by moving the cursor
    back to the top-left corner and writing a buffered frame, which produces a
    smoother and more visually pleasing result than repeatedly writing new
    lines.

    The default rainbow and RGB gradients are intentionally slow-moving so the
    colors drift almost imperceptibly from one hue to the next rather than
    rapidly cycling.

    An optional Windows Terminal GPU backend is also available. This mode
    exports an app-owned HLSL shader plus a tiny no-profile launcher script,
    opens a dedicated Windows Terminal session, and lets the GPU animate the
    same row-based gradients that the console renderer normally computes on the
    CPU.

    Supported gradient styles:
    - Rainbow  : balanced HSL rainbow bands
    - Greyscale: pulsing monochrome shimmer
    - Custom   : aurora-like blue/teal/purple gradient
    - LolCat   : high-saturation lolcat-inspired rainbow sweep

    The animation can render either a specific character or a curated set of
    fixed-width glyphs in random mode. Press 'q' or Ctrl+C to exit, or use
    -MaxFrames for non-interactive runs and smoke tests.

.PARAMETER ColorGradient
    Specifies the gradient style to render when -UseRgbColor is not specified.

.PARAMETER UseRgbColor
    Uses a smooth sine-wave RGB animation instead of the selected HSL
    gradient. When specified, this takes precedence over -ColorGradient.

.PARAMETER Renderer
    Chooses the rendering backend. Console uses the in-place ANSI renderer in
    this function. WindowsTerminalShader launches a dedicated Windows Terminal
    session that prints the glyph mask once and uses a GPU pixel shader to
    animate the same gradients without modifying the user's profile or
    Windows Terminal settings.json.

.PARAMETER ShaderOutputPath
    Optional destination path for the exported Windows Terminal HLSL shader when
    -Renderer WindowsTerminalShader is used. When omitted, the shader is placed
    in an app-managed Windows Terminal fragment folder.

.PARAMETER WindowsTerminalSettingsPath
    Legacy parameter retained for compatibility. The current
    WindowsTerminalShader renderer no longer edits the user's Windows Terminal
    settings.json file.

.PARAMETER LaunchWindowsTerminal
    Retained for compatibility. The WindowsTerminalShader renderer now always
    launches a dedicated Windows Terminal session so the GPU effect is visible
    immediately.

.PARAMETER UnicodeCharMode
    Controls whether the animation uses a curated random glyph set or a single
    fixed character.

.PARAMETER SpecificChar
    The character to display when -UnicodeCharMode is set to Specific.
    Fixed-width characters such as '█', '▓', '▒', and '■' work best.

.PARAMETER DebugCleanup
    Writes cleanup diagnostics directly to the console to help troubleshoot
    terminal input or cursor-restoration issues.

.PARAMETER MaxFrames
    Number of frames to render before automatically exiting. The default value
    of 0 runs until the user exits manually.

.EXAMPLE
    Invoke-ConsoleNoise -ColorGradient Rainbow -UnicodeCharMode Random

    Displays a smooth in-place rainbow animation using curated glyphs.

.EXAMPLE
    Invoke-ConsoleNoise -ColorGradient Custom -UnicodeCharMode Specific -SpecificChar '█'

    Displays an aurora-style animation using a solid block character.

.EXAMPLE
    Invoke-ConsoleNoise -UseRgbColor -MaxFrames 120

    Renders 120 frames of the RGB wave animation and then exits.

.EXAMPLE
    Invoke-ConsoleNoise -DebugCleanup -MaxFrames 10

    Runs a short animation and shows detailed cleanup diagnostics.

.EXAMPLE
    Invoke-ConsoleNoise -Renderer WindowsTerminalShader

    Exports the selected HLSL shader, creates an app-owned Windows Terminal
    fragment profile plus a no-profile launcher script, and launches a
    dedicated GPU-rendered terminal session.

.EXAMPLE
    Invoke-ConsoleNoise -Renderer WindowsTerminalShader -LaunchWindowsTerminal

    Launches the dedicated Windows Terminal GPU session. The switch is accepted
    for compatibility with earlier versions of the function.

.NOTES
    Optimized for ANSI-capable terminals such as Windows Terminal and VS Code.
    No external modules are required for the console backend. The GPU backend
    targets Windows Terminal pixel shaders rather than NVAPI directly because
    Windows Terminal already provides a practical GPU shader pipeline. The
    WindowsTerminalShader backend writes only app-owned fragment assets and a
    temporary launcher script; it does not mutate the user's PowerShell profile
    or Windows Terminal settings.json.
#>
function Invoke-ConsoleNoise {
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter()]
        [ValidateSet('Rainbow', 'Greyscale', 'Custom', 'LolCat')]
        [string]$ColorGradient = 'Rainbow',

        [Parameter()]
        [switch]$UseRgbColor,

        [Parameter()]
        [ValidateSet('Console', 'WindowsTerminalShader')]
        [string]$Renderer = 'Console',

        [Parameter()]
        [AllowEmptyString()]
        [string]$ShaderOutputPath = '',

        [Parameter()]
        [string[]]$WindowsTerminalSettingsPath,

        [Parameter()]
        [switch]$LaunchWindowsTerminal,

        [Parameter()]
        [ValidateSet('Random', 'Specific')]
        [string]$UnicodeCharMode = 'Specific',

        [Parameter()]
        [char]$SpecificChar = [char]0x2588,

        [Parameter()]
        [switch]$DebugCleanup,

        [Parameter()]
        [ValidateRange(0, 1000000)]
        [int]$MaxFrames = 0
    )

    if ($Renderer -eq 'WindowsTerminalShader') {
        $windowsTerminalShaderParams = @{
            SettingsPaths         = $WindowsTerminalSettingsPath
            LaunchWindowsTerminal = $LaunchWindowsTerminal
            ColorGradient         = $ColorGradient
            UseRgbColor           = $UseRgbColor
            UnicodeCharMode       = $UnicodeCharMode
            SpecificChar          = $SpecificChar
            MaxFrames             = $MaxFrames
        }

        if (-not [string]::IsNullOrWhiteSpace($ShaderOutputPath)) {
            $windowsTerminalShaderParams.ShaderOutputPath = $ShaderOutputPath
        }

        try {
            if (Enable-ConsoleNoiseWindowsTerminalShader @windowsTerminalShaderParams) {
                return
            }

            Write-Warning 'Falling back to the console renderer because the GPU renderer could not be started.'
        }
        catch {
            Write-Warning "WindowsTerminalShader renderer failed to start: $($_.Exception.Message). Falling back to the console renderer."
        }
    }

    $originalState = Get-ConsoleNoiseState
    $context = $null
    $errorRecordToWrite = $null

    try {
        $context = New-ConsoleNoiseContext -ColorGradient $ColorGradient -UseRgbColor:$UseRgbColor -UnicodeCharMode $UnicodeCharMode -SpecificChar $SpecificChar -MaxFrames $MaxFrames
        Initialize-ConsoleNoiseHost -Context $context
        Start-ConsoleNoiseAnimation -Context $context
    }
    catch {
        $errorRecordToWrite = $_
    }
    finally {
        Restore-ConsoleNoiseState -OriginalState $originalState -Context $context -DebugMode:$DebugCleanup
    }

    if ($null -ne $errorRecordToWrite) {
        Write-Error -ErrorRecord $errorRecordToWrite
    }
}

function Enable-ConsoleNoiseWindowsTerminalShader {
    [CmdletBinding()]
    param(
        [Parameter()]
        [AllowEmptyString()]
        [string]$ShaderOutputPath,

        [Parameter()]
        [string[]]$SettingsPaths,

        [Parameter()]
        [switch]$LaunchWindowsTerminal,

        [Parameter(Mandatory)]
        [ValidateSet('Rainbow', 'Greyscale', 'Custom', 'LolCat')]
        [string]$ColorGradient,

        [Parameter()]
        [switch]$UseRgbColor,

        [Parameter()]
        [ValidateSet('Random', 'Specific')]
        [string]$UnicodeCharMode = 'Specific',

        [Parameter()]
        [char]$SpecificChar = [char]0x2588,

        [Parameter()]
        [ValidateRange(0, 1000000)]
        [int]$MaxFrames = 0
    )

    if ($SettingsPaths) {
        Write-Warning 'WindowsTerminalSettingsPath is ignored by the current WindowsTerminalShader renderer. A dedicated app-owned fragment profile is used instead.'
    }

    $fragmentRoot = Get-ConsoleNoiseWindowsTerminalFragmentRoot
    $destinationShaderPath = if ([string]::IsNullOrWhiteSpace($ShaderOutputPath)) {
        Join-Path -Path $fragmentRoot -ChildPath 'ConsoleNoiseActive.hlsl'
    }
    else {
        $ShaderOutputPath
    }

    $exportedShaderPath = Export-ConsoleNoiseWindowsTerminalShader -DestinationPath $destinationShaderPath -ColorGradient $ColorGradient -UseRgbColor:$UseRgbColor
    $launcherScriptPath = Export-ConsoleNoiseWindowsTerminalBootstrapScript -FragmentRoot $fragmentRoot -UnicodeCharMode $UnicodeCharMode -SpecificChar $SpecificChar -MaxFrames $MaxFrames
    $commandLine = Get-ConsoleNoiseWindowsTerminalCommandLine -LauncherScriptPath $launcherScriptPath
    $profileName = 'Invoke-ConsoleNoise GPU'
    $fragmentPath = Export-ConsoleNoiseWindowsTerminalFragmentProfile -FragmentRoot $fragmentRoot -ProfileName $profileName -ShaderPath $exportedShaderPath -CommandLine $commandLine

    Start-Sleep -Milliseconds 150
    $launched = Start-ConsoleNoiseWindowsTerminalProfile -ProfileName $profileName -StartingDirectory (Get-Location).Path
    if (-not $launched) {
        return $false
    }

    Write-Information "Exported GPU shader to '$exportedShaderPath'." -InformationAction Continue
    Write-Information "Wrote GPU launcher script to '$launcherScriptPath'." -InformationAction Continue
    Write-Information "Wrote Windows Terminal fragment profile to '$fragmentPath'." -InformationAction Continue
    Write-Information "Launched Windows Terminal profile '$profileName' in a new window." -InformationAction Continue
    return $true
}

function Export-ConsoleNoiseWindowsTerminalShader {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$DestinationPath,

        [Parameter(Mandatory)]
        [ValidateSet('Rainbow', 'Greyscale', 'Custom', 'LolCat')]
        [string]$ColorGradient,

        [Parameter()]
        [switch]$UseRgbColor
    )

    $sourceShaderPath = Resolve-ConsoleNoiseWindowsTerminalShaderSourcePath -ColorGradient $ColorGradient -UseRgbColor:$UseRgbColor
    if (-not (Test-Path -Path $sourceShaderPath)) {
        throw "Windows Terminal shader source was not found at '$sourceShaderPath'."
    }

    $destinationDirectory = Split-Path -Path $DestinationPath -Parent
    if ($destinationDirectory -and -not (Test-Path -Path $destinationDirectory)) {
        New-Item -Path $destinationDirectory -ItemType Directory -Force | Out-Null
    }

    Copy-Item -Path $sourceShaderPath -Destination $DestinationPath -Force
    return $DestinationPath
}

function Export-ConsoleNoiseWindowsTerminalBootstrapScript {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$FragmentRoot,

        [Parameter()]
        [ValidateSet('Random', 'Specific')]
        [string]$UnicodeCharMode = 'Specific',

        [Parameter()]
        [char]$SpecificChar = [char]0x2588,

        [Parameter()]
        [ValidateRange(0, 1000000)]
        [int]$MaxFrames = 0
    )

    if (-not (Test-Path -Path $FragmentRoot)) {
        New-Item -Path $FragmentRoot -ItemType Directory -Force | Out-Null
    }

    $unicodeCharModeLiteral = ConvertTo-ConsoleNoisePowerShellSingleQuotedLiteral -Value $UnicodeCharMode
    $specificCharLiteral = ConvertTo-ConsoleNoisePowerShellSingleQuotedLiteral -Value ([string]$SpecificChar)

    $launcherScriptContent = @"
`$ErrorActionPreference = 'SilentlyContinue'
`$unicodeCharMode = $unicodeCharModeLiteral
`$specificChar = $specificCharLiteral
`$maxFrames = $MaxFrames
`$randomCharacterPool = @(
    '█', '▓', '▒', '░', '■', '◆',
    '◈', '●', '◼', '▪', '▫', '▣'
)

function Get-ConsoleNoiseViewport {
    `$width = 80
    `$height = 24

    try {
        `$width = [Console]::WindowWidth
        `$height = [Console]::WindowHeight
    }
    catch {
    }

    if (`$width -lt 1) {
        `$width = 1
    }

    if (`$height -lt 2) {
        `$height = 2
    }

    return [pscustomobject]@{
        Width  = `$width
        Height = [Math]::Max(1, (`$height - 1))
    }
}

function Get-ConsoleNoiseWaveValue {
    param(
        [Parameter(Mandatory)]
        [double]`$Phase
    )

    return (([Math]::Sin(`$Phase) + 1.0) / 2.0)
}

function New-ConsoleNoiseRow {
    param(
        [Parameter(Mandatory)]
        [int]`$Width,

        [Parameter(Mandatory)]
        [int]`$RowIndex,

        [Parameter(Mandatory)]
        [int]`$Seed
    )

    if (`$unicodeCharMode -eq 'Specific') {
        return (`$specificChar * `$Width)
    }

    `$builder = [System.Text.StringBuilder]::new(`$Width)
    `$poolCount = `$randomCharacterPool.Count
    `$waveOffset = [int][Math]::Round((Get-ConsoleNoiseWaveValue -Phase ((`$Seed * 0.03) + (`$RowIndex * 0.35))) * (`$poolCount - 1))
    `$driftOffset = [int][Math]::Floor((`$Seed * 0.11) + (`$RowIndex * 1.4))
    `$rowOffset = (`$waveOffset + `$driftOffset) % `$poolCount

    for (`$columnIndex = 0; `$columnIndex -lt `$Width; `$columnIndex++) {
        `$poolIndex = (`$columnIndex + `$rowOffset) % `$poolCount
        `$null = `$builder.Append(`$randomCharacterPool[`$poolIndex])
    }

    return `$builder.ToString()
}

function New-ConsoleNoiseFrame {
    param(
        [Parameter(Mandatory)]
        [int]`$Seed
    )

    `$viewport = Get-ConsoleNoiseViewport
    `$estimatedCapacity = [Math]::Max(128, ((`$viewport.Width + 2) * `$viewport.Height))
    `$builder = [System.Text.StringBuilder]::new(`$estimatedCapacity)

    for (`$rowIndex = 0; `$rowIndex -lt `$viewport.Height; `$rowIndex++) {
        `$null = `$builder.Append((New-ConsoleNoiseRow -Width `$viewport.Width -RowIndex `$rowIndex -Seed `$Seed))

        if (`$rowIndex -lt (`$viewport.Height - 1)) {
            `$null = `$builder.Append("`r`n")
        }
    }

    [Console]::SetCursorPosition(0, 0)
    [Console]::Write(`$builder.ToString())
    [Console]::Out.Flush()

    return `$viewport
}

function Test-ConsoleNoiseExitRequested {
    try {
        if ([Console]::KeyAvailable) {
            `$key = [Console]::ReadKey(`$true)

            if (`$null -ne `$key) {
                if (`$key.Key -eq [System.ConsoleKey]::Q) {
                    return `$true
                }

                if (((`$key.Modifiers -band [System.ConsoleModifiers]::Control) -ne 0) -and `$key.Key -eq [System.ConsoleKey]::C) {
                    return `$true
                }
            }
        }
    }
    catch {
    }

    return `$false
}

`$originalCursorVisibleCaptured = `$false
`$originalTreatControlCAsInputCaptured = `$false

try {
    try {
        [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    }
    catch {
    }

    try {
        `$originalCursorVisible = [Console]::CursorVisible
        `$originalCursorVisibleCaptured = `$true
        [Console]::CursorVisible = `$false
    }
    catch {
    }

    try {
        `$originalTreatControlCAsInput = [Console]::TreatControlCAsInput
        `$originalTreatControlCAsInputCaptured = `$true
        [Console]::TreatControlCAsInput = `$true
    }
    catch {
    }

    try {
        [Console]::Clear()
    }
    catch {
    }

    `$frameSeed = [int](Get-Random -Minimum 0 -Maximum 4096)
    `$viewport = New-ConsoleNoiseFrame -Seed `$frameSeed
    `$startedAt = [DateTime]::UtcNow
    `$maxDurationMs = if (`$maxFrames -gt 0) {
        [int][Math]::Round((1000.0 / 30.0) * `$maxFrames)
    }
    else {
        0
    }

    while (`$true) {
        if (`$maxDurationMs -gt 0 -and (([DateTime]::UtcNow - `$startedAt).TotalMilliseconds -ge `$maxDurationMs)) {
            break
        }

        if (Test-ConsoleNoiseExitRequested) {
            break
        }

        `$latestViewport = Get-ConsoleNoiseViewport
        if (`$latestViewport.Width -ne `$viewport.Width -or `$latestViewport.Height -ne `$viewport.Height) {
            try {
                [Console]::Clear()
            }
            catch {
            }

            `$viewport = New-ConsoleNoiseFrame -Seed `$frameSeed
        }

        Start-Sleep -Milliseconds 120
    }
}
finally {
    if (`$originalCursorVisibleCaptured) {
        try {
            [Console]::CursorVisible = `$originalCursorVisible
        }
        catch {
        }
    }

    if (`$originalTreatControlCAsInputCaptured) {
        try {
            [Console]::TreatControlCAsInput = `$originalTreatControlCAsInput
        }
        catch {
        }
    }
}
"@

    $scriptPath = Join-Path -Path $FragmentRoot -ChildPath 'Invoke-ConsoleNoise.GpuLauncher.ps1'
    [System.IO.File]::WriteAllText($scriptPath, $launcherScriptContent, [System.Text.UTF8Encoding]::new($false))
    return $scriptPath
}

function Get-ConsoleNoiseWindowsTerminalCommandLine {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$LauncherScriptPath
    )

    $shellExecutable = Get-ConsoleNoiseShellExecutable
    $escapedShellExecutable = $shellExecutable.Replace('"', '""')
    $escapedLauncherScriptPath = $LauncherScriptPath.Replace('"', '""')

    return ('"{0}" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "{1}"' -f $escapedShellExecutable, $escapedLauncherScriptPath)
}

function Get-ConsoleNoiseShellExecutable {
    [CmdletBinding()]
    param()

    $shellExecutable = $null
    try {
        $shellExecutable = (Get-Process -Id $PID -ErrorAction Stop).Path
    }
    catch {
    }

    if ([string]::IsNullOrWhiteSpace($shellExecutable)) {
        $shellExecutable = if ($PSVersionTable.PSEdition -eq 'Core') {
            Join-Path -Path $PSHOME -ChildPath 'pwsh.exe'
        }
        else {
            Join-Path -Path $PSHOME -ChildPath 'powershell.exe'
        }
    }

    return $shellExecutable
}

function ConvertTo-ConsoleNoisePowerShellSingleQuotedLiteral {
    [CmdletBinding()]
    param(
        [Parameter()]
        [AllowNull()]
        [string]$Value
    )

    if ($null -eq $Value) {
        return "''"
    }

    return "'$($Value.Replace("'", "''"))'"
}

function Resolve-ConsoleNoiseWindowsTerminalShaderSourcePath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Rainbow', 'Greyscale', 'Custom', 'LolCat')]
        [string]$ColorGradient,

        [Parameter()]
        [switch]$UseRgbColor
    )

    $repositoryRoot = Split-Path -Path $PSScriptRoot -Parent
    $shaderFileName = if ($UseRgbColor) {
        'ConsoleNoiseRgb.hlsl'
    }
    else {
        switch ($ColorGradient) {
            'Rainbow' {
                'ConsoleNoiseRainbow.hlsl' 
            }
            'Greyscale' {
                'ConsoleNoiseGreyscale.hlsl' 
            }
            'LolCat' {
                'ConsoleNoiseLolCat.hlsl' 
            }
            default {
                'CalmAurora.hlsl' 
            }
        }
    }

    return (Join-Path -Path $repositoryRoot -ChildPath (Join-Path -Path 'Non PowerShell Tools' -ChildPath $shaderFileName))
}

function Get-ConsoleNoiseWindowsTerminalFragmentRoot {
    [CmdletBinding()]
    param()

    return (Join-Path -Path $env:LOCALAPPDATA -ChildPath 'Microsoft\Windows Terminal\Fragments\InvokeConsoleNoise')
}

function Export-ConsoleNoiseWindowsTerminalFragmentProfile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$FragmentRoot,

        [Parameter(Mandatory)]
        [string]$ProfileName,

        [Parameter(Mandatory)]
        [string]$ShaderPath,

        [Parameter(Mandatory)]
        [string]$CommandLine
    )

    if (-not (Test-Path -Path $FragmentRoot)) {
        New-Item -Path $FragmentRoot -ItemType Directory -Force | Out-Null
    }

    $fragmentObject = [ordered]@{
        profiles = @(
            [ordered]@{
                guid                               = '{ab3d0e87-0b8c-4e41-9f45-1d4d2a07fa42}'
                name                               = $ProfileName
                commandline                        = $CommandLine
                startingDirectory                  = (Get-Location).Path
                suppressApplicationTitle           = $true
                tabTitle                           = $ProfileName
                'experimental.pixelShaderPath'     = $ShaderPath
                'experimental.retroTerminalEffect' = $false
            }
        )
    }

    $fragmentPath = Join-Path -Path $FragmentRoot -ChildPath 'Invoke-ConsoleNoise.fragment.json'
    $json = $fragmentObject | ConvertTo-Json -Depth 10
    [System.IO.File]::WriteAllText($fragmentPath, $json, [System.Text.UTF8Encoding]::new($false))
    return $fragmentPath
}

function Start-ConsoleNoiseWindowsTerminalProfile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ProfileName,

        [Parameter(Mandatory)]
        [string]$StartingDirectory
    )

    $wtCommand = Get-Command -Name 'wt.exe' -ErrorAction SilentlyContinue
    if (-not $wtCommand) {
        Write-Warning 'Windows Terminal (wt.exe) was not found on PATH, so the GPU renderer could not be launched.'
        return $false
    }

    try {
        $argumentList = @('-w', '-1', 'new-tab', '-p', $ProfileName, '-d', $StartingDirectory)
        Start-Process -FilePath $wtCommand.Source -ArgumentList $argumentList -ErrorAction Stop | Out-Null
        return $true
    }
    catch {
        Write-Warning "Failed to launch Windows Terminal automatically: $($_.Exception.Message)"
        return $false
    }
}

function Get-ConsoleNoiseState {
    $state = @{
        ForegroundColor = $Host.UI.RawUI.ForegroundColor
        BackgroundColor = $Host.UI.RawUI.BackgroundColor
    }

    try {
        $state.OutputEncoding = [Console]::OutputEncoding
    }
    catch {
    }

    try {
        $state.TreatControlCAsInput = [Console]::TreatControlCAsInput
    }
    catch {
    }

    if (Get-Module -Name PSReadLine -ErrorAction Ignore) {
        try {
            $state.PSReadLineEditMode = (Get-PSReadLineOption).EditMode
        }
        catch {
        }
    }

    if ($Host.UI.RawUI | Get-Member -Name CursorVisible -MemberType Property -ErrorAction Ignore) {
        try {
            $state.CursorVisible = $Host.UI.RawUI.CursorVisible
        }
        catch {
        }
    }

    if ($PSVersionTable.PSVersion.Major -ge 7) {
        try {
            $state.OutputRendering = [string]$PSStyle.OutputRendering
        }
        catch {
        }
    }

    return $state
}

function New-ConsoleNoiseContext {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Rainbow', 'Greyscale', 'Custom', 'LolCat')]
        [string]$ColorGradient,

        [Parameter()]
        [switch]$UseRgbColor,

        [Parameter(Mandatory)]
        [ValidateSet('Random', 'Specific')]
        [string]$UnicodeCharMode,

        [Parameter(Mandatory)]
        [char]$SpecificChar,

        [Parameter(Mandatory)]
        [int]$MaxFrames
    )

    $viewport = Get-ConsoleNoiseViewport
    $refreshRate = Get-ConsoleNoiseRefreshRate

    return [pscustomobject]@{
        Width               = $viewport.Width
        Height              = $viewport.Height
        RefreshRate         = $refreshRate
        FrameDelayMs        = Get-ConsoleNoiseFrameDelay -RefreshRate $refreshRate
        ColorGradient       = $ColorGradient
        UseRgbColor         = [bool]$UseRgbColor
        UnicodeCharMode     = $UnicodeCharMode
        SpecificChar        = [string]$SpecificChar
        MaxFrames           = $MaxFrames
        UseAnsi             = Test-ConsoleNoiseAnsiSupport
        Escape              = [char]27
        RainbowHueDrift     = 0.00045
        RainbowRowHueStep   = 0.0075
        RgbPhaseDrift       = 0.0016
        RgbRowPhaseStep     = 0.045
        RandomCharacterPool = @(
            '█', '▓', '▒', '░', '■', '◆',
            '◈', '●', '◼', '▪', '▫', '▣'
        )
    }
}

function Initialize-ConsoleNoiseHost {
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Context
    )

    Clear-ConsoleNoiseKeyboardBuffer -DebugMode:$false

    try {
        [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    }
    catch {
    }

    if ($Context.UseAnsi -and $PSVersionTable.PSVersion.Major -ge 7) {
        try {
            $PSStyle.OutputRendering = 'Ansi'
        }
        catch {
        }
    }

    try {
        [Console]::TreatControlCAsInput = $true
    }
    catch {
    }

    if ($Host.UI.RawUI | Get-Member -Name CursorVisible -MemberType Property -ErrorAction Ignore) {
        try {
            $Host.UI.RawUI.CursorVisible = $false
        }
        catch {
        }
    }

    [Console]::Clear()
    [Console]::SetCursorPosition(0, 0)
}

function Restore-ConsoleNoiseState {
    param(
        [Parameter(Mandatory)]
        [hashtable]$OriginalState,

        [Parameter()]
        [pscustomobject]$Context,

        [Parameter()]
        [switch]$DebugMode
    )

    Write-ConsoleNoiseDebug -Enabled:$DebugMode -Message '[DEBUG] Starting Invoke-ConsoleNoise cleanup...'
    Clear-ConsoleNoiseKeyboardBuffer -DebugMode:$DebugMode

    if (($Host.UI.RawUI | Get-Member -Name CursorVisible -MemberType Property -ErrorAction Ignore) -and $OriginalState.ContainsKey('CursorVisible')) {
        try {
            $Host.UI.RawUI.CursorVisible = $OriginalState.CursorVisible
        }
        catch {
            Write-ConsoleNoiseDebug -Enabled:$DebugMode -Message "[DEBUG] Failed to restore cursor visibility: $($_.Exception.Message)"
        }
    }

    try {
        $Host.UI.RawUI.ForegroundColor = $OriginalState.ForegroundColor
        $Host.UI.RawUI.BackgroundColor = $OriginalState.BackgroundColor
    }
    catch {
        Write-ConsoleNoiseDebug -Enabled:$DebugMode -Message "[DEBUG] Failed to restore host colors: $($_.Exception.Message)"
    }

    try {
        [Console]::ResetColor()
    }
    catch {
        Write-ConsoleNoiseDebug -Enabled:$DebugMode -Message "[DEBUG] Console.ResetColor failed: $($_.Exception.Message)"
    }

    if ($OriginalState.ContainsKey('OutputEncoding')) {
        try {
            [Console]::OutputEncoding = $OriginalState.OutputEncoding
        }
        catch {
            Write-ConsoleNoiseDebug -Enabled:$DebugMode -Message "[DEBUG] Failed to restore output encoding: $($_.Exception.Message)"
        }
    }

    if ($OriginalState.ContainsKey('TreatControlCAsInput')) {
        try {
            [Console]::TreatControlCAsInput = [bool]$OriginalState.TreatControlCAsInput
        }
        catch {
            Write-ConsoleNoiseDebug -Enabled:$DebugMode -Message "[DEBUG] Failed to restore TreatControlCAsInput: $($_.Exception.Message)"
        }
    }

    if ($PSVersionTable.PSVersion.Major -ge 7 -and $OriginalState.ContainsKey('OutputRendering')) {
        try {
            $PSStyle.OutputRendering = $OriginalState.OutputRendering
        }
        catch {
            Write-ConsoleNoiseDebug -Enabled:$DebugMode -Message "[DEBUG] Failed to restore PSStyle output rendering: $($_.Exception.Message)"
        }
    }

    Reset-ConsoleNoisePSReadLine -OriginalState $OriginalState -DebugMode:$DebugMode

    [Console]::Out.Flush()
    Start-Sleep -Milliseconds 40

    try {
        [Console]::Clear()
    }
    catch {
        try {
            Clear-Host
        }
        catch {
            Write-ConsoleNoiseDebug -Enabled:$DebugMode -Message "[DEBUG] Failed to clear console during cleanup: $($_.Exception.Message)"
        }
    }

    Clear-ConsoleNoiseKeyboardBuffer -DebugMode:$DebugMode
    Write-ConsoleNoiseDebug -Enabled:$DebugMode -Message '[DEBUG] Invoke-ConsoleNoise cleanup complete.'
}

function Reset-ConsoleNoisePSReadLine {
    param(
        [Parameter(Mandatory)]
        [hashtable]$OriginalState,

        [Parameter()]
        [switch]$DebugMode
    )

    if (-not (Get-Module -Name PSReadLine -ErrorAction Ignore)) {
        return
    }

    if ($OriginalState.ContainsKey('PSReadLineEditMode')) {
        try {
            Set-PSReadLineOption -EditMode $OriginalState.PSReadLineEditMode -ErrorAction SilentlyContinue
        }
        catch {
            Write-ConsoleNoiseDebug -Enabled:$DebugMode -Message "[DEBUG] Set-PSReadLineOption failed: $($_.Exception.Message)"
        }
    }

    try {
        [Microsoft.PowerShell.PSConsoleReadLine]::RevertLine()
    }
    catch {
        Write-ConsoleNoiseDebug -Enabled:$DebugMode -Message "[DEBUG] PSConsoleReadLine::RevertLine failed: $($_.Exception.Message)"
    }
}

function Write-ConsoleNoiseDebug {
    param(
        [Parameter(Mandatory)]
        [string]$Message,

        [Parameter()]
        [switch]$Enabled
    )

    if ($Enabled) {
        [Console]::WriteLine($Message)
    }
}

function Get-ConsoleNoiseViewport {
    $width = 80
    $height = 24

    try {
        $width = $Host.UI.RawUI.WindowSize.Width
        $height = $Host.UI.RawUI.WindowSize.Height
    }
    catch {
        try {
            $width = [Console]::WindowWidth
            $height = [Console]::WindowHeight
        }
        catch {
        }
    }

    if ($width -lt 1) {
        $width = 1
    }

    if ($height -lt 2) {
        $height = 2
    }

    return [pscustomobject]@{
        Width  = $width
        Height = [Math]::Max(1, ($height - 1))
    }
}

function Update-ConsoleNoiseViewport {
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Context
    )

    $viewport = Get-ConsoleNoiseViewport
    $sizeChanged = ($Context.Width -ne $viewport.Width) -or ($Context.Height -ne $viewport.Height)

    $Context.Width = $viewport.Width
    $Context.Height = $viewport.Height

    return $sizeChanged
}

function Get-ConsoleNoiseRefreshRate {
    $refreshRate = 60

    try {
        $rates = Get-CimInstance -Namespace 'root\CIMV2' -ClassName Win32_VideoController -ErrorAction Stop |
            ForEach-Object { [int]$_.CurrentRefreshRate } |
                Where-Object { $_ -gt 0 }

        if ($rates) {
            $refreshRate = $rates | Select-Object -First 1
        }
    }
    catch {
    }

    if ($refreshRate -lt 1) {
        $refreshRate = 60
    }

    return [int]$refreshRate
}

function Get-ConsoleNoiseFrameDelay {
    param(
        [Parameter(Mandatory)]
        [int]$RefreshRate
    )

    $effectiveRefreshRate = if ($RefreshRate -gt 0) {
        $RefreshRate
    }
    else {
        60
    }

    if ($effectiveRefreshRate -gt 30) {
        $effectiveRefreshRate = 30
    }
    elseif ($effectiveRefreshRate -lt 24) {
        $effectiveRefreshRate = 24
    }

    return [Math]::Max(16, [int][Math]::Round(1000 / $effectiveRefreshRate))
}

function Test-ConsoleNoiseAnsiSupport {
    if ($Host.Name -like '*ISE*') {
        return $false
    }

    if ($env:TERM -eq 'dumb') {
        return $false
    }

    return $true
}

function Start-ConsoleNoiseAnimation {
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Context
    )

    $frameNumber = 0

    while ($true) {
        if ($Context.MaxFrames -gt 0 -and $frameNumber -ge $Context.MaxFrames) {
            break
        }

        if (Test-ConsoleNoiseExitRequested) {
            break
        }

        if (Update-ConsoleNoiseViewport -Context $Context) {
            [Console]::Clear()
        }

        $frameText = New-ConsoleNoiseFrame -Context $Context -FrameNumber $frameNumber
        [Console]::SetCursorPosition(0, 0)
        [Console]::Write($frameText)
        [Console]::Out.Flush()

        $frameNumber++
        Start-Sleep -Milliseconds $Context.FrameDelayMs
    }
}

function New-ConsoleNoiseFrame {
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Context,

        [Parameter(Mandatory)]
        [int]$FrameNumber
    )

    $estimatedCapacity = [Math]::Max(128, (($Context.Width + 24) * $Context.Height))
    $builder = [System.Text.StringBuilder]::new($estimatedCapacity)

    for ($rowIndex = 0; $rowIndex -lt $Context.Height; $rowIndex++) {
        $color = Get-ConsoleNoiseRowColor -Context $Context -FrameNumber $FrameNumber -RowIndex $rowIndex

        if ($Context.UseAnsi) {
            $null = $builder.Append((New-ConsoleNoiseAnsiForegroundSequence -Red $color.Red -Green $color.Green -Blue $color.Blue))
        }

        $null = $builder.Append((New-ConsoleNoiseRow -Context $Context -FrameNumber $FrameNumber -RowIndex $rowIndex))

        if ($rowIndex -lt ($Context.Height - 1)) {
            $null = $builder.Append("`r`n")
        }
    }

    if ($Context.UseAnsi) {
        $null = $builder.Append("$($Context.Escape)[0m")
    }

    return $builder.ToString()
}

function New-ConsoleNoiseRow {
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Context,

        [Parameter(Mandatory)]
        [int]$FrameNumber,

        [Parameter(Mandatory)]
        [int]$RowIndex
    )

    if ($Context.UnicodeCharMode -eq 'Specific') {
        return ($Context.SpecificChar * $Context.Width)
    }

    $characterPool = $Context.RandomCharacterPool
    $builder = [System.Text.StringBuilder]::new($Context.Width)
    $poolCount = $characterPool.Count
    $waveOffset = [int][Math]::Round((Get-ConsoleNoiseWaveValue -Phase (($FrameNumber * 0.12) + ($RowIndex * 0.35))) * ($poolCount - 1))
    $driftOffset = [int][Math]::Floor(($FrameNumber * 0.6) + ($RowIndex * 1.4))
    $rowOffset = ($waveOffset + $driftOffset) % $poolCount

    for ($columnIndex = 0; $columnIndex -lt $Context.Width; $columnIndex++) {
        $poolIndex = ($columnIndex + $rowOffset) % $poolCount
        $null = $builder.Append($characterPool[$poolIndex])
    }

    return $builder.ToString()
}

function Get-ConsoleNoiseRowColor {
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Context,

        [Parameter(Mandatory)]
        [int]$FrameNumber,

        [Parameter(Mandatory)]
        [int]$RowIndex
    )

    if ($Context.UseRgbColor) {
        return Get-ConsoleNoiseRgbWaveColor -Context $Context -FrameNumber $FrameNumber -RowIndex $RowIndex
    }

    return Get-ConsoleNoiseHslGradientColor -Context $Context -FrameNumber $FrameNumber -RowIndex $RowIndex
}

function Get-ConsoleNoiseRgbWaveColor {
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Context,

        [Parameter(Mandatory)]
        [int]$FrameNumber,

        [Parameter(Mandatory)]
        [int]$RowIndex
    )

    $phase = ($FrameNumber * $Context.RgbPhaseDrift) + ($RowIndex * $Context.RgbRowPhaseStep)
    $channelMidpoint = 160
    $channelAmplitude = 70

    $red = [int][Math]::Round($channelMidpoint + ($channelAmplitude * [Math]::Sin($phase)))
    $green = [int][Math]::Round($channelMidpoint + ($channelAmplitude * [Math]::Sin($phase + ((2 * [Math]::PI) / 3))))
    $blue = [int][Math]::Round($channelMidpoint + ($channelAmplitude * [Math]::Sin($phase + ((4 * [Math]::PI) / 3))))

    return [pscustomobject]@{
        Red   = $red
        Green = $green
        Blue  = $blue
    }
}

function Get-ConsoleNoiseHslGradientColor {
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Context,

        [Parameter(Mandatory)]
        [int]$FrameNumber,

        [Parameter(Mandatory)]
        [int]$RowIndex
    )

    $rowPhase = ($FrameNumber * 0.045) + ($RowIndex * 0.06)

    switch ($Context.ColorGradient) {
        'Greyscale' {
            $lightness = 0.18 + ((Get-ConsoleNoiseWaveValue -Phase ($rowPhase * 3.6)) * 0.62)
            return Convert-HslToRgb -Hue 0 -Saturation 0 -Lightness $lightness
        }

        'Custom' {
            $hue = 0.56 + ([Math]::Sin($rowPhase * 1.7) * 0.12)
            if ($hue -lt 0) {
                $hue += 1.0
            }
            elseif ($hue -ge 1.0) {
                $hue -= 1.0
            }

            $saturation = 0.74 + ((Get-ConsoleNoiseWaveValue -Phase ($rowPhase * 0.8)) * 0.16)
            $lightness = 0.38 + ((Get-ConsoleNoiseWaveValue -Phase (($rowPhase * 2.1) + 0.7)) * 0.18)

            return Convert-HslToRgb -Hue $hue -Saturation $saturation -Lightness $lightness
        }

        'LolCat' {
            $hue = (($FrameNumber * 0.065) + ($RowIndex * 0.115)) % 1.0
            $lightness = 0.55 + ((Get-ConsoleNoiseWaveValue -Phase ($rowPhase * 2.4)) * 0.10)
            return Convert-HslToRgb -Hue $hue -Saturation 1.0 -Lightness $lightness
        }

        default {
            $hue = (($FrameNumber * $Context.RainbowHueDrift) + ($RowIndex * $Context.RainbowRowHueStep)) % 1.0
            return Convert-HslToRgb -Hue $hue -Saturation 0.84 -Lightness 0.56
        }
    }
}

function Get-ConsoleNoiseWaveValue {
    param(
        [Parameter(Mandatory)]
        [double]$Phase
    )

    return (([Math]::Sin($Phase) + 1.0) / 2.0)
}

function Convert-HslToRgb {
    param(
        [Parameter(Mandatory)]
        [double]$Hue,

        [Parameter(Mandatory)]
        [double]$Saturation,

        [Parameter(Mandatory)]
        [double]$Lightness
    )

    $Hue = $Hue % 1.0
    if ($Hue -lt 0) {
        $Hue += 1.0
    }

    $Saturation = [Math]::Max(0.0, [Math]::Min(1.0, $Saturation))
    $Lightness = [Math]::Max(0.0, [Math]::Min(1.0, $Lightness))

    if ($Saturation -eq 0) {
        $r = $Lightness
        $g = $Lightness
        $b = $Lightness
    }
    else {
        $hue2rgb = {
            param(
                [double]$p,
                [double]$q,
                [double]$t
            )

            if ($t -lt 0) {
                $t += 1.0
            }

            if ($t -gt 1) {
                $t -= 1.0
            }

            if ($t -lt (1.0 / 6.0)) {
                return $p + (($q - $p) * 6.0 * $t)
            }

            if ($t -lt 0.5) {
                return $q
            }

            if ($t -lt (2.0 / 3.0)) {
                return $p + (($q - $p) * (((2.0 / 3.0) - $t) * 6.0))
            }

            return $p
        }

        $q = if ($Lightness -lt 0.5) {
            $Lightness * (1 + $Saturation)
        }
        else {
            $Lightness + $Saturation - ($Lightness * $Saturation)
        }

        $p = (2 * $Lightness) - $q
        $r = & $hue2rgb $p $q ($Hue + (1.0 / 3.0))
        $g = & $hue2rgb $p $q $Hue
        $b = & $hue2rgb $p $q ($Hue - (1.0 / 3.0))
    }

    $red = [Math]::Max(0, [Math]::Min(255, [int][Math]::Round($r * 255)))
    $green = [Math]::Max(0, [Math]::Min(255, [int][Math]::Round($g * 255)))
    $blue = [Math]::Max(0, [Math]::Min(255, [int][Math]::Round($b * 255)))

    return [pscustomobject]@{
        Red   = [int]$red
        Green = [int]$green
        Blue  = [int]$blue
    }
}

function New-ConsoleNoiseAnsiForegroundSequence {
    param(
        [Parameter(Mandatory)]
        [int]$Red,

        [Parameter(Mandatory)]
        [int]$Green,

        [Parameter(Mandatory)]
        [int]$Blue
    )

    return ('{0}[38;2;{1};{2};{3}m' -f [char]27, $Red, $Green, $Blue)
}

function Test-ConsoleNoiseExitRequested {
    try {
        if ([Console]::KeyAvailable) {
            $key = [Console]::ReadKey($true)

            if ($null -ne $key) {
                if ($key.Key -eq [System.ConsoleKey]::Q) {
                    return $true
                }

                if ((($key.Modifiers -band [System.ConsoleModifiers]::Control) -ne 0) -and $key.Key -eq [System.ConsoleKey]::C) {
                    return $true
                }
            }
        }
    }
    catch {
        try {
            $rawUi = $Host.UI.RawUI
            if ($rawUi -and $rawUi.KeyAvailable) {
                $options = [System.Management.Automation.Host.ReadKeyOptions]::NoEcho -bor [System.Management.Automation.Host.ReadKeyOptions]::IncludeKeyDown
                $keyInfo = $rawUi.ReadKey($options)

                if ($null -ne $keyInfo) {
                    if ($keyInfo.Character -eq 'q' -or $keyInfo.Character -eq 'Q') {
                        return $true
                    }

                    $controlMask = [System.Management.Automation.Host.ControlKeyStates]::LeftCtrlPressed -bor [System.Management.Automation.Host.ControlKeyStates]::RightCtrlPressed
                    if (($keyInfo.ControlKeyState -band $controlMask) -and $keyInfo.VirtualKeyCode -eq 67) {
                        return $true
                    }
                }
            }
        }
        catch {
            return $false
        }
    }

    return $false
}

function Clear-ConsoleNoiseKeyboardBuffer {
    param(
        [Parameter()]
        [switch]$DebugMode
    )

    try {
        while ([Console]::KeyAvailable) {
            [Console]::ReadKey($true) | Out-Null
        }
    }
    catch {
        Write-ConsoleNoiseDebug -Enabled:$DebugMode -Message "[DEBUG] Console keyboard flush failed: $($_.Exception.Message)"
    }

    try {
        $rawUi = $Host.UI.RawUI
        if ($rawUi -and ($rawUi | Get-Member -Name FlushInputBuffer -MemberType Method -ErrorAction Ignore)) {
            $rawUi.FlushInputBuffer()
        }
    }
    catch {
        Write-ConsoleNoiseDebug -Enabled:$DebugMode -Message "[DEBUG] RawUI keyboard flush failed: $($_.Exception.Message)"
    }
}