
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
            Write-Logg -Message "[!] Can't find or access folder ${BasePath}." -Level Error
        }

        $FileToLoad = Join-Path $BasePath $File

        if (-not (Test-Path -Path "$FileToLoad" -PathType Leaf)) {
            Write-Logg -Message "[!] Can't find or access file ${FileToLoad}." -Level Error
        }

        if (-not ([AppDomain]::CurrentDomain.GetAssemblies() | Where-Object Location -Like $FileToLoad)) {
            Write-Logg -Message "Loading file $FileToLoad into application domain" -Level VERBOSE
            [System.Reflection.Assembly]::LoadFrom($FileToLoad) | Out-Null
            $clientVersion = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($FileToLoad).ProductVersion
            Write-Logg -Message "[+] File ${File} loaded with version ${clientVersion} from ${BasePath}." -Level VERBOSE
        }
    }
    catch {
        Write-Logg -Message "An error occurred: $_" -Level Error
        Write-Logg -Message "Error details: $($_.Exception)" -Level Error
    }
}