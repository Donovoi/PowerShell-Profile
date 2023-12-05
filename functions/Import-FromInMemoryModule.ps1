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
function Import-FromInMemoryModule {
    [CmdletBinding()]    
    param(
        [Parameter(Mandatory = $false)]
        [string[]]
        $ModuleName = 'pansies'
    )

    begin {
        try {




            # get powershell version
            $PSVersion = $PSVersionTable.PSVersion
            if ($PSVersion.Major -ge 6) {
                $PowerShellPath = [System.Environment]::GetFolderPath('MyDocuments') + '\PowerShell'
                $PowerShellModulesPath = $PowerShellPath + '\Modules'
            }
            else {
                $PowerShellPath = [System.Environment]::GetFolderPath('MyDocuments') + '\WindowsPowerShell'
                $PowerShellModulesPath = $WindowsPowerShellPath + '\Modules'
            }
            # make sure module exist and get the full path
            foreach ($Module in $ModuleName) {
                $ModulePath = Get-Module -ListAvailable $Module | Where-Object -FilterScript { $($_.Path | Split-Path -Parent).Contains($PowerShellModulesPath) } | Select-Object -Property Path
                if (-not $ModulePath) {
                    throw "Module '$Module' not found"
                }
                else {
                    Write-Verbose "Module '$Module' found at '$ModulePath'"
                    Write-Verbose "Making an in-memory copy of '$Module'"

                    # get files and folders recursively from the $PowerShellModulesPath
                    $ModuleFiles = Get-ChildItem -Path $PowerShellModulesPath\$Module -Recurse -Force -ErrorAction Stop

                #   Copy all files and folders in memory




                    # import the module
                    Import-Module -Assembly $ModuleAssembly -Verbose

                    Write-Verbose "Module '$Module' imported"


                }
            }
        }
        catch {
            throw "Failed to import module '$ModuleName'`: $_"
        }
    }

    process {

    }

    end {
    }
}

# Import-FromInMemoryModule -ModuleName pansies -Verbose -ErrorAction Break