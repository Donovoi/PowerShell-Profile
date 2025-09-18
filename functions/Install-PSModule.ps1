function Install-PSModule {
    [CmdletBinding()]
    param(
        [bool]$InstallDefaultPSModules,
        [string[]]$PSModule,
        [switch]$RemoveAllLocalModules,
        [switch]$RemoveAllInMemoryModules,
        [string]$LocalModulesDirectory = $PWD
    )

    process {
        $FileScriptBlock = ''
        # (1) Import required cmdlets if missing
        $neededcmdlets = @(
            'Write-Logg'

        )
        foreach ($cmd in $neededcmdlets) {
            if (-not (Get-Command -Name $cmd -ErrorAction SilentlyContinue)) {
                if (-not (Get-Command -Name 'Install-Cmdlet' -ErrorAction SilentlyContinue)) {
                    # Retry mechanism for downloading Install-Cmdlet.ps1
                    $maxRetries = 20
                    $retryCount = 0
                    $success = $false
                    $method = $null
                    
                    while (-not $success -and $retryCount -lt $maxRetries) {
                        try {
                            $retryCount++
                            if ($retryCount -gt 1) {
                                Write-Verbose "Retrying download attempt $retryCount of $maxRetries..."
                                Start-Sleep -Seconds 5
                            }
                            
                            Write-Verbose "Downloading Install-Cmdlet.ps1 from GitHub (attempt $retryCount)..."
                            $method = Invoke-RestMethod -Uri 'https://raw.githubusercontent.com/Donovoi/PowerShell-Profile/main/functions/Install-Cmdlet.ps1'
                            $success = $true
                            Write-Verbose 'Successfully downloaded Install-Cmdlet.ps1'
                        }
                        catch {
                            Write-Warning "Failed to download Install-Cmdlet.ps1 (attempt $retryCount): $($_.Exception.Message)"
                            if ($retryCount -eq $maxRetries) {
                                Write-Error "Failed to download Install-Cmdlet.ps1 after $maxRetries attempts. Please check your internet connection and try again."
                                throw
                            }
                        }
                    }
                    
                    $finalstring = [scriptblock]::Create($method.ToString() + "`nExport-ModuleMember -Function * -Alias *")
                    New-Module -Name 'InstallCmdlet' -ScriptBlock $finalstring | Import-Module
                }
                Write-Verbose "Importing cmdlet: $cmd"
                
                # Retry mechanism for downloading individual cmdlets
                $maxCmdletRetries = 20
                $cmdletRetryCount = 0
                $cmdletSuccess = $false
                $scriptBlock = $null
                
                while (-not $cmdletSuccess -and $cmdletRetryCount -lt $maxCmdletRetries) {
                    try {
                        $cmdletRetryCount++
                        if ($cmdletRetryCount -gt 1) {
                            Write-Verbose "Retrying cmdlet download attempt $cmdletRetryCount of $maxCmdletRetries for $cmd..."
                            Start-Sleep -Seconds 5
                        }
                        
                        Write-Verbose "Downloading cmdlet: $cmd (attempt $cmdletRetryCount)..."
                        $scriptBlock = Install-Cmdlet -RepositoryCmdlets $cmd -PreferLocal -Force
                        $cmdletSuccess = $true
                        Write-Verbose "Successfully downloaded cmdlet: $cmd"
                    }
                    catch {
                        Write-Warning "Failed to download cmdlet '$cmd' (attempt $cmdletRetryCount): $($_.Exception.Message)"
                        if ($cmdletRetryCount -eq $maxCmdletRetries) {
                            Write-Error "CRITICAL ERROR: Failed to download required dependency '$cmd' after $maxCmdletRetries attempts. This cmdlet is required for the script to function properly. Exiting script."
                            Write-Host "Script execution terminated due to missing critical dependency: $cmd" -ForegroundColor Red
                            exit 1
                        }
                    }
                }

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
            if ($RemoveAllInMemoryModules) {
                Write-Logg -Message 'RemoveAllInMemoryModules is specified. Unloading any currently loaded modules.' -Level VERBOSE
                Get-Module | ForEach-Object {
                    if ($_.Name -ne 'InstallDependencies' -and $_.Name -ne 'InstallCmdlet') {
                        Remove-Module -Name $_.Name -Force -ErrorAction SilentlyContinue
                    }
                }
            }

            if ($RemoveAllLocalModules) {
                Write-Logg -Message '$RemoveAllLocalModules is specified. Checking directory for safe deletion.' -Level VERBOSE
                if (Test-Path -Path $LocalModulesDirectory -PathType Container) {
                    # Find any files that are NOT PowerShell module files
                    $nonPsFiles = Get-ChildItem -Path $LocalModulesDirectory -Recurse -File | Where-Object { $_.Extension -notin '.ps1', '.psm1', '.psd1' }

                    if ($nonPsFiles.Count -eq 0) {
                        # Safe to delete
                        Write-Logg -Message "Directory only contains PowerShell files. Removing '$LocalModulesDirectory'." -Level VERBOSE
                        Remove-Item -Path $LocalModulesDirectory -Recurse -Force -ErrorAction SilentlyContinue | Out-Null
                        Write-Logg -Message "Successfully removed all local modules from '$LocalModulesDirectory'." -Level VERBOSE
                    }
                    else {
                        # Found other file types, abort deletion
                        $fileList = ($nonPsFiles | Select-Object -ExpandProperty FullName) -join "`n"
                        Write-Error "Deletion aborted. Directory '$LocalModulesDirectory' contains non-PowerShell files:`n$fileList"
                    }
                }
                else {
                    Write-Logg -Message "Local modules directory '$LocalModulesDirectory' does not exist. Nothing to remove." -Level VERBOSE
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
                        Write-Logg -Message "Installing module $moduleName" -Level VERBOSE

                        if (-not [string]::IsNullOrEmpty($LocalModulesDirectory)) {
                            $LocalModulePath = Join-Path -Path $LocalModulesDirectory -ChildPath $moduleName
                            if (Test-Path -Path $LocalModulePath -PathType Container) {
                                Write-Logg -Message "Module '$moduleName' found locally. Importing..." -Level VERBOSE
                                Import-Module -Name $LocalModulePath -Force -ErrorAction SilentlyContinue -WarningAction SilentlyContinue
                            }
                            else {
                                Write-Logg -Message "Module '$moduleName' not found locally. Installing from PSGallery..." -Level VERBOSE
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
                Write-Logg -Message 'No modules to install.' -Level VERBOSE
            }
        }
        catch {
            Write-Error "An error occurred in Install-PSModule: $_"
        }
    }
}