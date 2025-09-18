function Install-Dependencies {
    [CmdletBinding()]
    param(
        [switch]$RemoveAllLocalModules,
        [switch]$RemoveAllInMemoryModules,
        [string[]]$PSModule,
        [hashtable]$NugetPackage,
        [switch]$NoPSModules,
        [switch]$NoNugetPackage,
        [switch]$InstallDefaultPSModules,
        [switch]$InstallDefaultNugetPackage,
        [switch]$AddDefaultAssemblies,
        [string[]]$AddCustomAssemblies,
        [string]$LocalModulesDirectory = $PWD,
        [string]$LocalNugetDirectory = $PWD,
        [switch]$SaveLocally
    )

    $FileScriptBlock = ''
    # (1) Import required cmdlets if missing
    $neededcmdlets = @(
        'Get-FileDownload',
        'Add-FileToAppDomain',
        'Invoke-AriaDownload',
        'Get-LongName',
        'Write-Logg',
        'Invoke-RunAsAdmin',
        'Install-PackageProviders',
        'Add-Assemblies',
        'Install-NugetDeps',
        'Install-PSModule',
        'Update-SessionEnvironment',
        'Get-EnvironmentVariable',
        'Get-EnvironmentVariableNames',
        'Add-NuGetDependencies'
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
            }            # Check if the returned value is a ScriptBlock and import it properly
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

    # (2) Run as admin if not already elevated
    Invoke-RunAsAdmin

    # (3) Install or verify package providers
    Install-PackageProviders

    if ($SaveLocally -and [string]::IsNullOrWhiteSpace($LocalNugetDirectory)) {
        Write-Logg -Message 'You specified -SaveLocally but did not provide a valid -LocalNugetDirectory.' -Level Error
    }
    if ($SaveLocally -and [string]::IsNullOrWhiteSpace($LocalModulesDirectory)) {
        Write-Logg -Message 'You specified -SaveLocally but did not provide a valid -LocalModulesDirectory.' -Level Error
    }

    # (4) Install PowerShell modules unless suppressed
    if (-not $NoPSModules -and ($PSModule.Count -gt 0)) {
        $null = Install-PSModule `
            -InstallDefaultPSModules:$InstallDefaultPSModules `
            -PSModule:$PSModule `
            -LocalModulesDirectory:$LocalModulesDirectory `
            -RemoveAllLocalModules:$RemoveAllLocalModules `
            -RemoveAllInMemoryModules:$RemoveAllInMemoryModules

    }

    # (5) Install NuGet dependencies unless suppressed
    if (-not $NoNugetPackage ) {
        $null = Install-NugetDeps `
            -InstallDefaultNugetPackage:$InstallDefaultNugetPackage `
            -NugetPackage:$NugetPackage `
            -SaveLocally:$SaveLocally `
            -LocalNugetDirectory:$LocalNugetDirectory
    }

    # (6) Add assemblies if requested
    if ($AddDefaultAssemblies -or $AddCustomAssemblies) {
        $null = Add-Assemblies `
            -UseDefault:$AddDefaultAssemblies `
            -CustomAssemblies:$AddCustomAssemblies

    }

    # (7) Refresh environment variables once at the end
    Update-SessionEnvironment
}