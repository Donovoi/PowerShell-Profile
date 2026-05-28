<#
.SYNOPSIS
    Force-installs or refreshes the PowerShell profile.
#>
function Invoke-PowerShellProfile {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
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