
#requires -RunAsAdministrator

function Start-CMatrix {
    param (
        [int]$maxColumns = 8,
        [int]$frameWait = 100,
        [int]$maxStrings = 10
    )

    $script:winsize = Get-ConsoleWindowSize
    $script:columns = @{}
    $script:strings = @()
    $script:frameNum = 0

    Clear-Host

    $done = $false

    while (-not $done) {
        Write-FrameBuffer -maxColumns $maxColumns -maxStrings $maxStrings
        Show-FrameBuffer

        Start-Sleep -Milliseconds $frameWait

        $done = $host.UI.RawUI.KeyAvailable
    }

    Clear-Host
}

function Get-ConsoleWindowSize {
    $console = Get-Console
    return [PSCustomObject]@{
        Width  = $console.BufferSize.Width
        Height = $console.BufferSize.Height
    }
}


function Get-Console {
    return (Get-Host).UI.RawUI
}



function New-String {
    param (
        [string]$text,
        [ConsoleColor]$foregroundColor = 'White',
        [ConsoleColor]$backgroundColor = 'Black'
    )

    return [PSCustomObject]@{
        Text            = $text
        ForegroundColor = $foregroundColor
        BackgroundColor = $backgroundColor
    }
}

function Write-FrameBuffer {
    param (
        [int]$maxColumns,
        [int]$maxStrings
    )

    if ($columns.Count -lt $maxColumns) {
        if ((Get-Random -Minimum 0 -Maximum 10) -lt 5) {
            $xPos = Get-Random -Minimum 0 -Maximum ($winSize.Width - 1)
            $columns[$xPos] = $xPos
        }
    }

    if ($strings.Count -lt $maxStrings) {
        $strings += New-String -text ([char](Get-Random -Minimum 65 -Maximum 122))
    }

    $frameNum++
}

function Show-FrameBuffer {
    for ($y = 0; $y -lt $winSize.Height; $y++) {
        for ($x = 0; $x -lt $winSize.Width; $x++) {
            if ($columns.Contains($x)) {
                Write-Cell -x $x -y $y -text ' ' -foregroundColor 'Green'
            }
            else {
                Write-Cell -x $x -y $y -text ' ' -foregroundColor 'Black'
            }
        }
    }

    for ($i = 0; $i -lt $strings.Count; $i++) {
        $string = $strings[$i]
        $xPos = $columns.Keys[$i % $columns.Count]

        Write-Cell -x $xPos -y ($winSize.Height - 1) -text $string.Text -foregroundColor $string.ForegroundColor -backgroundColor $string.BackgroundColor
    }
}

function Write-Cell {
    param (
        [int]$x,
        [int]$y,
        [string]$text,
        [ConsoleColor]$foregroundColor,
        [ConsoleColor]$backgroundColor
    )

    $cell = New-Object System.Management.Automation.Host.BufferCell
    $cell.Character = $text
    $cell.ForegroundColor = $foregroundColor

    # Check if $backgroundColor parameter is null, if yes, set it to "Black"
    if ($null -eq $backgroundColor) {
        $cell.BackgroundColor = 'Black'
    }
    else {
        $cell.BackgroundColor = $backgroundColor
    }

    $rect = New-Object System.Management.Automation.Host.Rectangle -Property @{
        Top    = $y
        Left   = $x
        Right  = $x
        Bottom = $y
    }

    $host.UI.RawUI.SetBufferContents($rect, $cell)
}

function Start-ScreenSaver {
    param (
        [int]$maxColumns = 8,
        [int]$frameWait = 100,
        [int]$maxStrings = 10
    )

    Start-CMatrix -maxColumns $maxColumns -frameWait $frameWait -maxStrings $maxStrings
}
