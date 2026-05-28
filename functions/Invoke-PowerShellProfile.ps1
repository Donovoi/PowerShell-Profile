<#
.SYNOPSIS
    Force-installs or refreshes the PowerShell profile.

.DESCRIPTION
    Compatibility wrapper around Install-Profile. Keep this file only if you want an
    Invoke-PowerShellProfile command name as well as Install-Profile.
#>
function Invoke-PowerShellProfile {
    [CmdletBinding()]
    param(
        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [uri]$ProfileUrl = 'https://github.com/Donovoi/PowerShell-Profile.git',

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]$ProfilePath = (Join-Path -Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::MyDocuments)) -ChildPath 'PowerShell')
    )

    Install-Profile @PSBoundParameters
}