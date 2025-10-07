<#
.SYNOPSIS
    Installs and imports PowerShell modules from PSGallery or local cache with progress tracking.

.DESCRIPTION
    The Install-PSModule function manages PowerShell module installation and loading with features including:
    
    - Installation of modules from PSGallery (CurrentUser scope)
    - Loading modules from local cache directories
    - Optional removal of all in-memory loaded modules
    - Optional removal of all local cached modules
    - Progress bar showing installation status
    - Automatic fallback from local to PSGallery if not found locally
    - Safe deletion validation (only removes directories with PowerShell files)
    
    The function can install a default set of modules or specific modules provided via parameter.
    All installations use -Force and -AllowClobber to handle conflicts automatically.

.PARAMETER InstallDefaultPSModules
    Boolean value ($true/$false) to install a default set of commonly used PowerShell modules.
    When $true, installs default modules (e.g., PSReadLine).
    When $false or omitted, only installs modules specified in PSModule parameter.

.PARAMETER PSModule
    Array of PowerShell module names to install from PSGallery.
    Each module will be:
    1. Checked in local cache (LocalModulesDirectory) if specified
    2. Installed from PSGallery if not found locally
    3. Imported into the current session
    
    Example: @('Pester', 'PSScriptAnalyzer', 'ImportExcel')

.PARAMETER RemoveAllLocalModules
    Switch to remove all modules from the LocalModulesDirectory before installation.
    Includes safety check: only deletes if directory contains ONLY PowerShell files (.ps1, .psm1, .psd1).
    If non-PowerShell files are found, deletion is aborted with an error message.
    Use with extreme caution as this permanently deletes the local module cache.

.PARAMETER RemoveAllInMemoryModules
    Switch to unload all currently loaded PowerShell modules before installation.
    Does not remove 'InstallDependencies' or 'InstallCmdlet' modules.
    Useful for forcing clean module loads or resolving version conflicts.

.PARAMETER LocalModulesDirectory
    Directory path to use for local module cache.
    Defaults to current working directory ($PWD).
    
    If specified, the function will:
    - First check this directory for existing modules
    - Import from here if found (faster than downloading)
    - Fall back to PSGallery if not found locally
    
    Example: "C:\PSModules" or "$HOME\Documents\PowerShell\Modules"

.EXAMPLE
    Install-PSModule -PSModule @('Pester', 'PSScriptAnalyzer')
    
    Installs and imports Pester and PSScriptAnalyzer from PSGallery.

.EXAMPLE
    Install-PSModule -InstallDefaultPSModules $true
    
    Installs and imports the default set of PowerShell modules (PSReadLine, etc.).

.EXAMPLE
    Install-PSModule -PSModule @('ImportExcel') -LocalModulesDirectory "C:\PSModules"
    
    Checks C:\PSModules for ImportExcel, imports if found, otherwise downloads from PSGallery.

.EXAMPLE
    Install-PSModule -RemoveAllInMemoryModules -PSModule @('Pester')
    
    Unloads all modules, then installs and imports Pester fresh.

.EXAMPLE
    Install-PSModule -RemoveAllLocalModules -LocalModulesDirectory "C:\TempModules" -PSModule @('PSReadLine')
    
    Deletes all cached modules in C:\TempModules (if safe), then installs PSReadLine.

.OUTPUTS
    None. Modules are installed/imported into the session and progress is displayed.
    All actions are logged via Write-Logg.

.NOTES
    - Uses Install-Module with -Scope CurrentUser (no admin rights required)
    - Progress bar shows installation status for multiple modules
    - Safe deletion validation prevents accidental data loss
    - Automatically handles module conflicts with -AllowClobber
    - Skips publisher check validation for faster installation
    - Suppresses warnings during installation and import
    - Requires Write-Logg cmdlet (automatically loaded via Initialize-CmdletDependencies)
#>
function Install-PSModule {
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [bool]$InstallDefaultPSModules,
        [string[]]$PSModule,
        [switch]$RemoveAllLocalModules,
        [switch]$RemoveAllInMemoryModules,
        [string]$LocalModulesDirectory = ''
    )

    process {
        # Validate and normalize LocalModulesDirectory parameter
        if ([string]::IsNullOrWhiteSpace($LocalModulesDirectory)) {
            $LocalModulesDirectory = $PWD.Path
            Write-Verbose "LocalModulesDirectory was empty, defaulting to: $LocalModulesDirectory"
        }
        # Load shared dependency loader if not already available
        if (-not (Get-Command -Name 'Initialize-CmdletDependencies' -ErrorAction SilentlyContinue)) {
            try {
                $callStack = Get-PSCallStack -ErrorAction SilentlyContinue | Where-Object ScriptName -ErrorAction SilentlyContinue | Select-Object -First 1 -ErrorAction SilentlyContinue
                if ($callStack -and $callStack.ScriptName) {
                    $cmdletRoot = (Resolve-Path (Join-Path -Path $callStack.ScriptName -ChildPath '..') -ErrorAction SilentlyContinue).Path
                }
                else {
                    $cmdletRoot = $PWD.Path
                }
                $initScript = Join-Path $cmdletRoot 'Initialize-CmdletDependencies.ps1'
                if (Test-Path $initScript -ErrorAction SilentlyContinue) {
                    . $initScript
                }
                else {
                    Write-Warning "Initialize-CmdletDependencies.ps1 not found in $cmdletRoot"
                    Write-Warning 'Falling back to direct download'
                    $method = Invoke-RestMethod -Uri 'https://raw.githubusercontent.com/Donovoi/PowerShell-Profile/main/functions/cmdlets/Initialize-CmdletDependencies.ps1' -ErrorAction Stop
                    $scriptBlock = [scriptblock]::Create($method)
                    . $scriptBlock
                }
            }
            catch {
                Write-Warning "Failed to load Initialize-CmdletDependencies: $($_.Exception.Message)"
                Write-Warning 'Some cmdlets may not be available'
            }
        }
        
        # (1) Import required cmdlets if missing
        # Load all required cmdlets (replaces 100+ lines of boilerplate)
        Initialize-CmdletDependencies -RequiredCmdlets @('Write-Logg') -PreferLocal -Force

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
                            if (Test-Path -Path $LocalModulePath -PathType Container -ErrorAction SilentlyContinue) {
                                Write-Logg -Message "Module '$moduleName' found locally. Importing..." -Level VERBOSE
                                try {
                                    Import-Module -Name $LocalModulePath -Force -ErrorAction Stop -WarningAction SilentlyContinue
                                }
                                catch {
                                    Write-Logg -Message "Failed to import local module '$moduleName': $($_.Exception.Message). Trying PSGallery..." -Level WARNING
                                    try {
                                        Install-Module -Name $moduleName -Force -Confirm:$false -ErrorAction Stop `
                                            -Scope CurrentUser -AllowClobber -SkipPublisherCheck -WarningAction SilentlyContinue
                                    }
                                    catch {
                                        Write-Logg -Message "Failed to install module '$moduleName' from PSGallery: $($_.Exception.Message)" -Level WARNING
                                    }
                                }
                            }
                            else {
                                Write-Logg -Message "Module '$moduleName' not found locally. Installing from PSGallery..." -Level VERBOSE
                                try {
                                    Install-Module -Name $moduleName -Force -Confirm:$false -ErrorAction Stop `
                                        -Scope CurrentUser -AllowClobber -SkipPublisherCheck -WarningAction SilentlyContinue
                                }
                                catch {
                                    Write-Logg -Message "Failed to install module '$moduleName': $($_.Exception.Message)" -Level WARNING
                                }
                            }
                        }
                        else {
                            Write-Logg -Message "Module '$moduleName' not found locally. Installing from PSGallery..." -Level VERBOSE
                            try {
                                Install-Module -Name $moduleName -Force -Confirm:$false -ErrorAction Stop `
                                    -Scope CurrentUser -AllowClobber -SkipPublisherCheck -WarningAction SilentlyContinue
                            }
                            catch {
                                Write-Logg -Message "Failed to install module '$moduleName': $($_.Exception.Message)" -Level WARNING
                            }
                        }
                    }

                    # Try to import the module, but don't fail if assembly is already loaded
                    try {
                        Import-Module -Name $moduleName -Force -ErrorAction Stop -WarningAction SilentlyContinue
                    }
                    catch {
                        # If it's an assembly conflict, check if module is actually available
                        if ($_.Exception.Message -match 'Assembly with same name is already loaded') {
                            Write-Logg -Message "Module '$moduleName' assembly already loaded, checking if commands are available..." -Level VERBOSE
                            if (Get-Module -Name $moduleName -ErrorAction SilentlyContinue) {
                                Write-Logg -Message "Module '$moduleName' is already loaded and available" -Level VERBOSE
                            }
                            else {
                                Write-Logg -Message "Module '$moduleName' assembly loaded but module not imported. This may cause issues." -Level WARNING
                            }
                        }
                        else {
                            Write-Logg -Message "Failed to import module '$moduleName': $($_.Exception.Message)" -Level WARNING
                        }
                    }
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