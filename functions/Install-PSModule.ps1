function Install-PSModule {
    [CmdletBinding()]
    param(
        [bool]$InstallDefaultPSModules,
        [string[]]$PSModule,
        [bool]$RemoveAllModules,
        [string]$LocalModulesDirectory = $PWD
    )

    process {
        $neededcmdlets = @(
            'Write-Logg'
        )
        $neededcmdlets | ForEach-Object {
            if (-not (Get-Command -Name $_ -ErrorAction SilentlyContinue)) {
                if (-not (Get-Command -Name 'Install-Cmdlet' -ErrorAction SilentlyContinue)) {
                    $method = Invoke-RestMethod -Uri 'https://raw.githubusercontent.com/Donovoi/PowerShell-Profile/main/functions/Install-Cmdlet.ps1'
                    $finalstring = [scriptblock]::Create($method.ToString() + "`nExport-ModuleMember -Function * -Alias *")
                    New-Module -Name 'InstallCmdlet' -ScriptBlock $finalstring | Import-Module
                }
                Write-Verbose -Message "Importing cmdlet: $_"
                $Cmdletstoinvoke = Install-Cmdlet -donovoicmdlets $_
                $Cmdletstoinvoke | Import-Module -Force
            }
        }

        try {
            # Build a module list
            $ModulesToBeInstalled = @()
            if ($InstallDefaultPSModules) {
                $ModulesToBeInstalled = @(
                    # Example default modules
                    'PSReadLine'
                )
            }
            elseif ($PSModule) {
                $ModulesToBeInstalled = $PSModule
            }

            # Remove all modules if requested (the original code suggests this is possible)
            if ($RemoveAllModules) {
                Write-Verbose 'RemoveAllModules is specified. Unloading any currently loaded modules.'
                Get-Module | ForEach-Object {
                    if ($_.Name -ne 'InstallDependencies' -and $_.Name -ne 'InstallCmdlet') {
                        Remove-Module -Name $_.Name -Force -ErrorAction SilentlyContinue
                    }
                }
            }

            # Show a progress bar for "Installing PS Modules"
            if ($ModulesToBeInstalled.Count -gt 0) {
                $count = 0
                $total = $ModulesToBeInstalled.Count
                foreach ($moduleName in $ModulesToBeInstalled) {
                    $count++
                    $percent = [int](($count / $total) * 100)

                    Write-Progress `
                        -Activity 'Installing PowerShell modules' `
                        -Status "Installing '$moduleName' ($count of $total)" `
                        -PercentComplete $percent

                    if ($percent -eq 100) {
                        Clear-Host
                    }

                    # Check if module is installed
                    if (-not (Get-Module -Name $moduleName -ListAvailable -ErrorAction SilentlyContinue)) {
                        Write-Logg -Message "Installing module $moduleName" -Level Verbose

                        if (-not [string]::IsNullOrEmpty($LocalModulesDirectory)) {
                            $LocalModulePath = Join-Path -Path $LocalModulesDirectory -ChildPath $moduleName
                            if (Test-Path -Path $LocalModulePath -PathType Container) {
                                Write-Logg -Message "Module '$moduleName' found locally. Importing..." -Level Verbose
                                Import-Module -Name $LocalModulePath -Force -ErrorAction SilentlyContinue -WarningAction SilentlyContinue
                            }
                            else {
                                Write-Logg -Message "Module '$moduleName' not found locally. Installing from PSGallery..." -Level Verbose
                                Install-Module -Name $moduleName -Force -Confirm:$false -ErrorAction SilentlyContinue `
                                    -Scope CurrentUser -AllowClobber -SkipPublisherCheck -WarningAction SilentlyContinue
                            }
                        }
                        else {
                            Write-Logg -Message 'Local destination directory not set. Exiting script...' -Level Error
                            throw
                        }
                    }

                    Import-Module -Name $moduleName -Force -ErrorAction SilentlyContinue -WarningAction SilentlyContinue
                }
            }
            else {
                Write-Verbose 'No modules to install.'
            }
        }
        catch {
            Write-Error "An error occurred in Install-PSModule: $_"
        }
    }
}