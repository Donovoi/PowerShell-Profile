function Find-ScreenTrouble {
    <#
    .SYNOPSIS
    Finds recent System warnings and errors mentioning the display.
    .DESCRIPTION
    Returns matching event records. These are clues, not a hardware diagnosis.
    Active flicker and Win32 display tests are not implemented.
    Importing this file does not query logs or require elevation.
    #>
    [CmdletBinding()]
    param([ValidateRange(1, 100000)] [int]$MaxEvents = 1000)

    try {
        Get-WinEvent -FilterHashtable @{ LogName = 'System'; Level = 2, 3 } -MaxEvents $MaxEvents -ErrorAction Stop |
            Where-Object { $_.Message -match 'screen|display' }
    }
    catch {
        if ($_.FullyQualifiedErrorId -notlike 'NoMatchingEventsFound*') { $PSCmdlet.ThrowTerminatingError($_) }
    }
    Write-Verbose 'Event messages alone cannot identify the cause of screen flicker. Active display tests are not implemented.'
}
