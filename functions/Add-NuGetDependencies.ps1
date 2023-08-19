<#
.SYNOPSIS
Adds NuGet dependencies to the project.

.DESCRIPTION
This function adds NuGet dependencies to the project by installing the specified packages and saving them locally.

.PARAMETER NugetPackages
The NuGet packages to load. This should be a hashtable with the package names as keys and the package versions as values.

.PARAMETER SaveLocally
Specifies if the packages should be saved locally. By default, this is not enabled.
#>
function Add-NuGetDependencies {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, HelpMessage = 'The NuGet packages to load.')]
        [hashtable]$NugetPackages,

        [Parameter(Mandatory = $false, HelpMessage = 'Specify if the packages should be saved locally.')]
        [switch]$SaveLocally
    )

    try {
        $TempWorkDir = $null
        $InstalledDependencies = @{}

        $CurrentFileName = Split-Path $PWD -Leaf
        $memstream = [IO.MemoryStream]::new([byte[]][char[]]$CurrentFileName)
        $CurrentFileNameHash = (Get-FileHash -InputStream $memstream -Algorithm SHA1).Hash

        if ($SaveLocally) {
            $TempWorkDir = Join-Path (Join-Path $PWD 'PowershellscriptsandResources') 'nugetpackages'
            Write-Log -Message "Local destination directory set to $TempWorkDir" -Level VERBOSE
        }
        else {
            # Get a unique temporary directory to store all the NuGet packages we need later
            $TempWorkDir = Join-Path "$($env:TEMP)" "$CurrentFileNameHash"
            Write-Log -Message "Creating temporary directory at $TempWorkDir" -Level VERBOSE
        }

        if (-not (Test-Path -Path "$TempWorkDir" -PathType Container)) {
            New-Item -Path "$TempWorkDir" -ItemType Directory | Out-Null
        }

        foreach ($dep in $NugetPackages.Keys) {
            $version = $NugetPackages[$dep]
            $destinationPath = Join-Path "$TempWorkDir" "${dep}.${version}"
            if (-not (Test-Path -Path "$destinationPath" -PathType Container) -and (-not $InstalledDependencies.ContainsKey($dep) -or $InstalledDependencies[$dep] -ne $version)) {
                Write-Log -Message "Installing package $dep version $version" -Level VERBOSE
                Install-Package -Name $dep -RequiredVersion $version -Destination "$TempWorkDir" -SkipDependencies -ProviderName NuGet -Source Nuget -Force | Out-Null
                Write-Log -Message "[+] Installed package ${dep} with version ${version} into folder ${TempWorkDir}" -Level VERBOSE

                # Update the installed dependencies hashtable
                $InstalledDependencies[$dep] = $version
            }

            # Prioritise version 4.8 over 4.5
            $BasePath = Join-Path (Join-Path "$destinationPath" 'lib') 'net48'
            if (-not (Test-Path -Path "$BasePath" -PathType Container)) {
                $BasePath = Join-Path (Join-Path "$destinationPath" 'lib') 'net45'
            }

            Write-Log -Message "Adding file ${dep}.dll to application domain" -Level VERBOSE
            Add-FileToAppDomain -BasePath $BasePath -File "${dep}.dll"
        }
    }
    catch {
        Write-Log -Message "An error occurred: $_" -Level ERROR
        Write-Log -Message "Error details: $($_.Exception)" -Level ERROR
    }
    finally {
        if ($TempWorkDir -and (Test-Path -Path "$TempWorkDir" -PathType Container)) {
            if ($SaveLocally) {
                Write-Log -Message "Packages saved locally to $TempWorkDir" -Level VERBOSE
            }
            else {
                Write-Log -Message "Cleaning up temporary directory at $TempWorkDir" -Level VERBOSE
                Remove-Item -Path "$TempWorkDir" -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }
}