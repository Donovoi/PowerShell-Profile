
<#
.SYNOPSIS
    Loads a .NET assembly file into the current PowerShell application domain.

.DESCRIPTION
    The Add-FileToAppDomain function loads a specified .NET assembly (DLL) file into the current
    PowerShell application domain using System.Reflection.Assembly.LoadFrom().
    
    The function:
    - Validates that the base path directory exists
    - Validates that the target file exists
    - Checks if the assembly is already loaded to avoid duplicate loading
    - Loads the assembly and logs version information
    - Handles errors gracefully with detailed logging
    
    Commonly used when working with NuGet packages or custom .NET assemblies that need to be
    loaded into PowerShell for use by other cmdlets or scripts.

.PARAMETER BasePath
    The base directory path where the assembly file is located.
    Must be a valid directory path. The function will validate this path exists before attempting to load.
    
    Example: "C:\NuGet\HtmlAgilityPack.1.11.46\lib\netstandard2.0"

.PARAMETER File
    The filename (including extension) of the assembly to load.
    Must be a valid file name. The function will validate this file exists in the BasePath before loading.
    
    Example: "HtmlAgilityPack.dll"

.EXAMPLE
    Add-FileToAppDomain -BasePath "C:\NuGet\HtmlAgilityPack\lib\netstandard2.0" -File "HtmlAgilityPack.dll"
    
    Loads the HtmlAgilityPack.dll assembly from the specified path into the current application domain.

.EXAMPLE
    $basePath = "C:\Temp\CustomAssembly"
    $fileName = "MyCustomLibrary.dll"
    Add-FileToAppDomain -BasePath $basePath -File $fileName
    
    Loads a custom assembly using variables for the path and filename.

.EXAMPLE
    Get-ChildItem "C:\NuGet\*\*.dll" | ForEach-Object {
        Add-FileToAppDomain -BasePath $_.DirectoryName -File $_.Name
    }
    
    Loads all DLL files found in subdirectories of C:\NuGet into the application domain.

.OUTPUTS
    None. The function loads assemblies into the session and logs messages via Write-Logg.
    Assembly information is logged including version details.

.NOTES
    - If an assembly is already loaded, the function skips loading and logs a message
    - Requires Write-Logg cmdlet for logging (automatically loaded via Initialize-CmdletDependencies)
    - Uses [System.Reflection.Assembly]::LoadFrom() which loads assemblies from a specific path
    - Errors during loading are caught and logged but do not stop execution
    - File version information is retrieved and logged using [System.Diagnostics.FileVersionInfo]
#>
function Add-FileToAppDomain {
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory = $true, HelpMessage = 'The base path to load files from.')]
        [ValidateNotNull()]
        [string]$BasePath,

        [Parameter(Mandatory = $true, HelpMessage = 'The file to load into the AppDomain.')]
        [ValidateNotNull()]
        [string]$File
    )

    try {
        # Load shared dependency loader if not already available
        if (-not (Get-Command -Name 'Initialize-CmdletDependencies' -ErrorAction SilentlyContinue)) {
            $initScript = Join-Path $PSScriptRoot 'Initialize-CmdletDependencies.ps1'
            if (Test-Path $initScript) {
                . $initScript
            }
            else {
                Write-Warning "Initialize-CmdletDependencies.ps1 not found in $PSScriptRoot"
                Write-Warning 'Falling back to direct download'
                $method = Invoke-RestMethod -Uri 'https://raw.githubusercontent.com/Donovoi/PowerShell-Profile/main/functions/cmdlets/Initialize-CmdletDependencies.ps1'
                $scriptBlock = [scriptblock]::Create($method)
                . $scriptBlock
            }
        }
        
        # (1) Import required cmdlets if missing
        # Load all required cmdlets (replaces 40+ lines of boilerplate)
        Initialize-CmdletDependencies -RequiredCmdlets @('Write-Logg') -PreferLocal -Force

        if (-not (Test-Path -Path "$BasePath" -PathType Container)) {
            Write-Logg -Message "[!] Can't find or access folder ${BasePath}." -Level Error
        }

        $FileToLoad = Join-Path $BasePath $File

        if (-not (Test-Path -Path "$FileToLoad" -PathType Leaf)) {
            Write-Logg -Message "[!] Can't find or access file ${FileToLoad}." -Level Error
        }

        if (-not ([AppDomain]::CurrentDomain.GetAssemblies() | Where-Object { ($_.Location -split '\\')[-1] -like ($FileToLoad -split '\\')[-1] })) {
            Write-Logg -Message "Loading file $FileToLoad into application domain" -Level VERBOSE
            [System.Reflection.Assembly]::LoadFrom($FileToLoad) | Out-Null
            $clientVersion = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($FileToLoad).ProductVersion
            Write-Logg -Message "[+] File ${File} loaded with version ${clientVersion} from ${BasePath}." -Level VERBOSE
        }
        else {
            Write-Logg -Message "[+] File ${File} is already loaded in the application domain." -Level VERBOSE
        }
    }
    catch {
        Write-Logg -Message "An error occurred: $_" -Level Error
        Write-Logg -Message "Error details: $($_.Exception)" -Level Error
    }
}