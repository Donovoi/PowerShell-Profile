
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
        $FileScriptBlock = ''
        # (1) Import required cmdlets if missing
        $neededcmdlets = @(
            'Write-Logg'

        )
        foreach ($cmd in $neededcmdlets) {
            if (-not (Get-Command -Name $cmd -ErrorAction SilentlyContinue)) {
                if (-not (Get-Command -Name 'Install-Cmdlet' -ErrorAction SilentlyContinue)) {
                    $method = Invoke-RestMethod -Uri 'https://raw.githubusercontent.com/Donovoi/PowerShell-Profile/main/functions/Install-Cmdlet.ps1'
                    $finalstring = [scriptblock]::Create($method.ToString() + "`nExport-ModuleMember -Function * -Alias *")
                    New-Module -Name 'InstallCmdlet' -ScriptBlock $finalstring | Import-Module
                }
                Write-Verbose "Importing cmdlet: $cmd"
                $scriptBlock = Install-Cmdlet -RepositoryCmdlets $cmd -PreferLocal -Force

                # Check if the returned value is a ScriptBlock and import it properly
                if ($scriptBlock -is [scriptblock]) {
                    $moduleName = "Dynamic_$cmd"
                    New-Module -Name $moduleName -ScriptBlock $scriptBlock | Import-Module -Force
                    Write-Verbose "Imported $cmd as dynamic module: $moduleName"
                }
                elseif ($scriptBlock -is [System.Management.Automation.PSModuleInfo]) {
                    # If a module info was returned, it's already imported
                    Write-Verbose "Module for $cmd was already imported: $($scriptBlock.Name)"
                }
                elseif ($($scriptBlock | Get-Item) -is [System.IO.FileInfo]) {
                    # If a file path was returned, import it
                    $FileScriptBlock += $(Get-Content -Path $scriptBlock -Raw) + "`n"
                    Write-Verbose "Imported $cmd from file: $scriptBlock"
                }
                else {
                    Write-Warning "Could not import $cmd`: Unexpected return type from Install-Cmdlet"
                    Write-Warning "Returned: $($scriptBlock)"
                }
            }
        }
        $finalFileScriptBlock = [scriptblock]::Create($FileScriptBlock.ToString() + "`nExport-ModuleMember -Function * -Alias *")
        New-Module -Name 'cmdletCollection' -ScriptBlock $finalFileScriptBlock | Import-Module -Force
    
        if (-not (Test-Path -Path "$BasePath" -PathType Container)) {
            Write-Logg -Message "[!] Can't find or access folder ${BasePath}." -Level Error
        }

        $FileToLoad = Join-Path $BasePath $File

        if (-not (Test-Path -Path "$FileToLoad" -PathType Leaf)) {
            Write-Logg -Message "[!] Can't find or access file ${FileToLoad}." -Level Error
        }

        if (-not ([AppDomain]::CurrentDomain.GetAssemblies() | Where-Object { $_.Location -eq $assembly.FullName })) {
            Write-Logg -Message "Loading file $FileToLoad into application domain" -Level VERBOSE -Verbose
            [System.Reflection.Assembly]::LoadFrom($FileToLoad) | Out-Null
            $clientVersion = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($FileToLoad).ProductVersion
            Write-Logg -Message "[+] File ${File} loaded with version ${clientVersion} from ${BasePath}." -Level VERBOSE -Verbose
        }
        else {
            Write-Logg -Message "[+] File ${File} is already loaded in the application domain." -Level VERBOSE -Verbose
        }
    }
    catch {
        Write-Logg -Message "An error occurred: $_" -Level Error
        Write-Logg -Message "Error details: $($_.Exception)" -Level Error
    }
}