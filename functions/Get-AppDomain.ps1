<#
.SYNOPSIS
This function loads a specified file into the current application domain.

.DESCRIPTION
The Add-FileToAppDomain function loads a specified file into the current application domain. 
It checks if the file is already loaded into the application domain, and if not, it loads the file.

.PARAMETER BasePath
The base path from where the file should be loaded.

.PARAMETER File
The name of the file to be loaded into the application domain.

.EXAMPLE
Add-FileToAppDomain -BasePath "C:\MyFiles" -File "MyAssembly.dll"

This will load the MyAssembly.dll file from the C:\MyFiles directory into the current application domain.
#>
function Add-FileToAppDomain {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, HelpMessage = 'The base path to load files from.')]
        [ValidateNotNull()]
        [string] $BasePath,
        [Parameter(Mandatory = $true, HelpMessage = 'The file to load into the AppDomain.')]
        [ValidateNotNull()]
        [string] $File
    )

    try {
        if (-not (Test-Path "$BasePath" -PathType Container)) {
            Throw "[!] Can't find or access folder ${BasePath}."
        }

        $FileToLoad = Join-Path "${BasePath}" "$File"

        if (-not (Test-Path "$FileToLoad" -PathType Leaf)) {
            Throw "[!] Can't find or access file ${FileToLoad}."
        }

        if ( -Not ([appdomain]::currentdomain.getassemblies() | Where-Object Location -Like ${FileToLoad})) {
            Write-Information "Loading file $FileToLoad into application domain"
            [System.Reflection.Assembly]::LoadFrom($FileToLoad) | Out-Null
            $clientVersion = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($FileToLoad).ProductVersion
            Write-Debug "[+] File ${File} loaded with version ${clientVersion} from ${BasePath}."
        }
    }
    catch {
        Write-Error "An error occurred: $_"
        Write-Error "Error details: $($_.Exception)"
    }
}
