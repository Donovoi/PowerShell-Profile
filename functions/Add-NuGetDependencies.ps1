<#
.SYNOPSIS
This function installs NuGet packages and their dependencies into a temporary directory.

.DESCRIPTION
The Add-NuGetDependencies function installs specified NuGet packages into a unique temporary directory. 
It uses the SHA1 hash of the current script's filename to create a unique directory for each script run. 
If a package is already installed, it will not be reinstalled. 
The function also prioritizes .NET version 4.8 over 4.5 when adding files to the application domain.

.PARAMETER NugetPackages
A hashtable where each key is the name of a NuGet package and the corresponding value is the version of the package to install.

.EXAMPLE
$packages = @{
    'Package1' = '1.0.0'
    'Package2' = '2.0.0'
}
Add-NuGetDependencies -NugetPackages $packages

This will install Package1 version 1.0.0 and Package2 version 2.0.0.
#>
function Add-NuGetDependencies {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, HelpMessage = 'The NuGet packages to load.')]
        [Hashtable] $NugetPackages
    )

    $TempWorkDir = $null

    try {
        $CurrentFileName = Split-Path $PSScriptRoot -Leaf
        $memstream = [IO.MemoryStream]::new([byte[]][char[]]$CurrentFileName)
        $CurrentFileNameHash = (Get-FileHash -InputStream $memstream -Algorithm SHA1).Hash

        # Get a unique temporary directory to store all the NuGet packages we need later
        $TempWorkDir = Join-Path "$($env:TEMP)" "$CurrentFileNameHash"

        Write-Information "Creating temporary directory at $TempWorkDir"

        if (-not (Test-Path "$TempWorkDir" -PathType Container)) {
            New-Item -Path "$($env:TEMP)" -Name "$CurrentFileNameHash" -ItemType Directory
        }

        foreach ($dep in $NugetPackages.Keys) {
            $version = $NugetPackages[$dep]
            $destinationPath = Join-Path "$TempWorkDir" "${dep}.${version}"
            if (-not (Test-Path "$destinationPath" -PathType Container)) {
                Write-Information "Installing package $dep version $version"
                Install-Package -Name $dep -RequiredVersion $version -Destination "$TempWorkDir" -SkipDependencies -ProviderName NuGet -Source nuget.org -Force
                Write-Information "[+] Install package ${dep} with version ${version} into folder ${TempWorkDir}"
            }

            # Prioritise version 4.8 over 4.5
            $BasePath = Join-Path (Join-Path "$destinationPath" "lib") "net48"
            if (-not (Test-Path "$BasePath" -PathType Container)) {
                $BasePath = Join-Path (Join-Path "$destinationPath" "lib") "net45"
            }

            Write-Information "Adding file ${dep}.dll to application domain"
            Add-FileToAppDomain -BasePath $BasePath -File "${dep}.dll"
        }
    }
    catch {
        Write-Error "An error occurred: $_"
        Write-Error "Error details: $($_.Exception)"
    }
    finally {
        if ($TempWorkDir -and (Test-Path "$TempWorkDir" -PathType Container)) {
            Write-Information "Cleaning up temporary directory at $TempWorkDir"
            Remove-Item -Path "$TempWorkDir" -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
