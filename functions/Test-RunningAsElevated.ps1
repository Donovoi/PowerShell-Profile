function Test-RunningAsElevated {
    # Compatibility name; use the same uncached token check everywhere.
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    if (-not (Get-Command Test-IsAdministrator -ErrorAction Ignore)) {
        . (Join-Path $PSScriptRoot 'Test-IsAdministrator.ps1')
    }
    Test-IsAdministrator
}
