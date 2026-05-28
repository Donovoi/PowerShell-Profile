<#
.SYNOPSIS
    Installs or refreshes the PowerShell profile.

.DESCRIPTION
    Compatibility wrapper around Install-Profile. Keep this file only if you want an
    Invoke-PowerShellProfile command name as well as Install-Profile.
#>
function Invoke-PowerShellProfile {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    param(
        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [uri]$ProfileUrl = 'https://github.com/Donovoi/PowerShell-Profile.git',

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]$ProfilePath = (Join-Path -Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::MyDocuments)) -ChildPath 'PowerShell'),

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]$BackupRoot = (Join-Path -Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::MyDocuments)) -ChildPath 'PowerShell_Profile_Backups'),

        [Parameter()]
        [switch]$NoBackup,

        [Parameter()]
        [switch]$ImportFunctionsAfterInstall
    )

    Install-Profile @PSBoundParameters
}