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
                    New-Module -Name $moduleName -ScriptBlock $scriptBlock | Import-Module -Force -Global
                    Write-Verbose "Imported $cmd as dynamic module: $moduleName"
                }
                elseif ($scriptBlock -is [System.Management.Automation.PSModuleInfo]) {
                    # If a module info was returned, it's already imported
                    Write-Verbose "Module for $cmd was already imported: $($scriptBlock.Name)"
                }
                elseif ($scriptBlock -is [System.IO.FileInfo]) {
                    # If a file path was returned, import it
                    Import-Module -Name $scriptBlock.FullName -Force -Global
                    Write-Verbose "Imported $cmd from file: $($scriptBlock.FullName)"
                }
                else {
                    Write-Warning "Could not import $cmd`: Unexpected return type from Install-Cmdlet"
                }
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

                    $progressParams = @{
                        Activity        = 'Installing PowerShell modules'
                        Status          = "Installing '$moduleName' ($count of $total)"
                        PercentComplete = $percent
                    }
                    Write-Progress @progressParams

                    # clear the write-progress if we're done
                    if ($percent -eq 100) {
                        Write-Progress -Activity 'Installing PowerShell modules' -Completed
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