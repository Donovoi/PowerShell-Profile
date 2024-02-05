# This is an advanced function to install wsa on a n offline system, this will need an online system in order to download the required files.
# The goal is to be declarative and idempotent, so it can be run multiple times without causing any issues.
<#
.SYNOPSIS
    Short description
.DESCRIPTION
    Long description
.EXAMPLE
    Example of how to use this cmdlet
.EXAMPLE
    Another example of how to use this cmdlet
#>
function Get-WSASetup {
    [CmdletBinding()]
    [OutputType([type])]
    param(
        # [Parameter(Mandatory=$true)]
        # [string]
        # $parameter_name
    )
    # load my Install-cmdlet function into memory so we can install other cmdlets
    $cmdletstring = (Invoke-WebRequest -Uri 'https://raw.githubusercontent.com/Donovoi/PowerShell-Profile/main/functions/Install-Cmdlet.ps1').Content
    $modulestring = $cmdletstring + "`nExport-ModuleMember -Function * -Alias *"
    $module = New-Module -ScriptBlock ([ScriptBlock]::Create($modulestring))
    Import-Module $module
    
    #  check if git is installed, if not install it
    if (-not (Test-Path -Path 'C:\Program Files\Git\cmd\git.exe')) {
        Write-Output 'Git is not installed, installing it now'
        Install-WinGetPackage -Name 'Git' -Source 'Microsoft' -Force
    }
    else {
        Write-Output 'Git is already installed'
    }
    # Refresh the environment variables we will use chocolatey's refresh command
    
}