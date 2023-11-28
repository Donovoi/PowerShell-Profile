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
function Update-VisualStudio {
    [CmdletBinding()]
    
    param(
        [Parameter(Mandatory = $false)]
        [string]
        $vswhere = 'C:\Program Files (x86)\Microsoft Visual Studio\Installer\vswhere.exe',
        [Parameter(Mandatory = $false)]
        [string]
        $vsInstaller = 'C:\Program Files (x86)\Microsoft Visual Studio\Installer\vs_installer.exe'
    )
    # Get all Visual Studio instances
    $instances = & $vswhere -all -prerelease -format json | ConvertFrom-Json

    # Update each instance
    foreach ($instance in $instances) {
        Write-Logg -Message "Updating $($instance.installationPath)..."
        & $vsInstaller update --installPath $($instance.installationPath)
    }

}