
<#
.SYNOPSIS
Adds the specified file to the application domain.

.DESCRIPTION
This function adds the specified file to the application domain by loading it from the base path.

.PARAMETER BasePath
The base path to load files from.

.PARAMETER File
The file to load into the AppDomain.
#>
function Add-FileToAppDomain {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, HelpMessage = 'The base path to load files from.')]
        [ValidateNotNull()]
        [string]$BasePath,

        [Parameter(Mandatory = $true, HelpMessage = 'The file to load into the AppDomain.')]
        [ValidateNotNull()]
        [string]$File
    )

    try {
        if (-not (Test-Path -Path "$BasePath" -PathType Container)) {
            throw "[!] Can't find or access folder ${BasePath}."
        }

        $FileToLoad = Join-Path $BasePath $File

        if (-not (Test-Path -Path "$FileToLoad" -PathType Leaf)) {
            throw "[!] Can't find or access file ${FileToLoad}."
        }

        if (-not ([AppDomain]::CurrentDomain.GetAssemblies() | Where-Object Location -Like $FileToLoad)) {
            Write-Log -Message "Loading file $FileToLoad into application domain" -Level VERBOSE
            [System.Reflection.Assembly]::LoadFrom($FileToLoad) | Out-Null
            $clientVersion = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($FileToLoad).ProductVersion
            Write-Log -Message "[+] File ${File} loaded with version ${clientVersion} from ${BasePath}." -Level VERBOSE
        }
    }
    catch {
        Write-Error "An error occurred: $_"
        Write-Error "Error details: $($_.Exception)"
    }
}