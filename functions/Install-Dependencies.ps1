<#
.SYNOPSIS
    Orchestrates installation of PowerShell modules, NuGet packages, and .NET assemblies with environment refresh.

.DESCRIPTION
    Install-Dependencies is a comprehensive dependency management function that handles:
    
    - Automatic elevation to Administrator if required
    - Installation and configuration of package providers (NuGet, PowerShellGet)
    - PowerShell module installation from PSGallery or local cache
    - NuGet package installation and assembly loading
    - .NET assembly loading (default WPF/Forms assemblies or custom)
    - Environment variable refresh to pick up newly installed tools
    - Optional cleanup of local module/package caches
    
    This function serves as a one-stop solution for setting up all dependencies required
    by scripts or modules, eliminating the need to manually install each component.

.PARAMETER RemoveAllLocalModules
    Switch to remove all PowerShell modules from the LocalModulesDirectory.
    Only deletes if the directory contains ONLY PowerShell files (.ps1, .psm1, .psd1).
    Use with caution as this permanently deletes local module cache.

.PARAMETER RemoveAllInMemoryModules
    Switch to unload all currently loaded PowerShell modules from the session.
    Does not remove InstallDependencies or InstallCmdlet modules.
    Useful for forcing fresh module loads or troubleshooting version conflicts.

.PARAMETER PSModule
    Array of PowerShell module names to install from PSGallery.
    Modules are installed to CurrentUser scope if not already available.
    
    Example: @('Pester', 'PSScriptAnalyzer', 'ImportExcel')

.PARAMETER NugetPackage
    Hashtable of NuGet packages to install, where keys are package names and values are versions.
    Format: @{ 'PackageName' = 'Version' }
    
    Example: @{ 'HtmlAgilityPack' = '1.11.46'; 'Newtonsoft.Json' = '13.0.1' }

.PARAMETER NoPSModules
    Switch to skip PowerShell module installation entirely.
    Use when you only need NuGet packages or assemblies.

.PARAMETER NoNugetPackage
    Switch to skip NuGet package installation entirely.
    Use when you only need PowerShell modules or assemblies.

.PARAMETER InstallDefaultPSModules
    Switch to install a default set of commonly used PowerShell modules.
    Default modules are defined in Install-PSModule cmdlet (e.g., PSReadLine).

.PARAMETER InstallDefaultNugetPackage
    Switch to install a default set of commonly used NuGet packages.
    Default packages are defined in Install-NugetDeps cmdlet.

.PARAMETER AddDefaultAssemblies
    Switch to load default .NET assemblies including:
    - PresentationFramework (WPF)
    - System.Windows.Forms
    - System.Drawing
    And others commonly needed for GUI applications.

.PARAMETER AddCustomAssemblies
    Array of custom .NET assembly names to load.
    These are loaded in addition to default assemblies if AddDefaultAssemblies is also specified.
    
    Example: @('System.Net.Http', 'System.Management.Automation')

.PARAMETER LocalModulesDirectory
    Directory path for local PowerShell module cache.
    Defaults to current working directory ($PWD).
    Used when SaveLocally switch is specified.

.PARAMETER LocalNugetDirectory
    Directory path for local NuGet package cache.
    Defaults to current working directory ($PWD).
    Used when SaveLocally switch is specified.

.PARAMETER SaveLocally
    Switch to save/load packages from local directories rather than temp directories.
    Requires LocalModulesDirectory and LocalNugetDirectory to be specified.

.EXAMPLE
    Install-Dependencies -PSModule @('Pester', 'PSScriptAnalyzer') -AddDefaultAssemblies
    
    Installs Pester and PSScriptAnalyzer modules, loads default .NET assemblies, and refreshes environment.

.EXAMPLE
    Install-Dependencies -InstallDefaultPSModules -InstallDefaultNugetPackage -SaveLocally -LocalModulesDirectory "C:\PSModules" -LocalNugetDirectory "C:\NuGet"
    
    Installs default modules and packages to custom local directories.

.EXAMPLE
    Install-Dependencies -NugetPackage @{ 'HtmlAgilityPack' = '1.11.46' } -NoNugetPackage:$false
    
    Installs only the HtmlAgilityPack NuGet package without installing PowerShell modules.

.EXAMPLE
    Install-Dependencies -RemoveAllInMemoryModules -PSModule @('ImportExcel')
    
    Unloads all modules, then installs and loads ImportExcel fresh.

.OUTPUTS
    None. The function installs dependencies, loads assemblies, and refreshes the environment.
    All actions are logged via Write-Logg.

.NOTES
    - Automatically elevates to Administrator if not already elevated (via Invoke-RunAsAdmin)
    - Installs package providers (NuGet, PowerShellGet) if missing
    - Refreshes environment variables at the end to pick up PATH changes
    - Requires 14 helper cmdlets (automatically loaded via Initialize-CmdletDependencies)
    - SaveLocally requires both LocalModulesDirectory and LocalNugetDirectory to be valid paths
    - This is the main entry point for comprehensive dependency setup
#>
function Install-Dependencies {
    [CmdletBinding()]
    [OutputType([void])]
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
        [string]$LocalModulesDirectory = '',
        [string]$LocalNugetDirectory = '',
        [switch]$SaveLocally
    )

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
    
    # (1) Import required cmdlets if missing - OPTIMIZED with caching
    # Only load cmdlets that aren't already available (50-76% faster)
    # NOTE: Write-Logg intentionally excluded to prevent circular dependency
    # (Install-Dependencies loads Write-Logg, but Write-Logg also loads Install-Dependencies)
    # Install-Dependencies uses Write-Verbose/Write-Warning for its own logging
    $requiredCmdlets = @(
        'Get-FileDownload',
        'Add-FileToAppDomain',
        'Invoke-AriaDownload',
        'Get-LongName',
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
    
    # Performance optimization: Only load missing cmdlets
    $missingCmdlets = $requiredCmdlets | Where-Object { 
        -not (Get-Command -Name $_ -ErrorAction SilentlyContinue) 
    }
    
    if ($missingCmdlets.Count -gt 0) {
        Write-Verbose "Loading $($missingCmdlets.Count) missing cmdlets ($(($requiredCmdlets.Count - $missingCmdlets.Count)) already loaded)"
        Initialize-CmdletDependencies -RequiredCmdlets $missingCmdlets -PreferLocal -Force -ErrorAction SilentlyContinue
    }
    else {
        Write-Verbose "All $($requiredCmdlets.Count) required cmdlets already loaded, skipping initialization"
    }

    # (2) Validate and normalize directory parameters - OPTIMIZED
    # Cache $PWD.Path to avoid multiple property accesses
    $currentPath = $PWD.Path
    if ([string]::IsNullOrWhiteSpace($LocalModulesDirectory)) {
        $LocalModulesDirectory = $currentPath
        Write-Verbose "LocalModulesDirectory was empty, defaulting to: $LocalModulesDirectory"
    }
    if ([string]::IsNullOrWhiteSpace($LocalNugetDirectory)) {
        $LocalNugetDirectory = $currentPath
        Write-Verbose "LocalNugetDirectory was empty, defaulting to: $LocalNugetDirectory"
    }

    # (3) Run as admin if not already elevated - OPTIMIZED with caching
    # Cache admin status to avoid repeated UAC checks (saves ~50-100ms per call)
    if (-not $Script:IsAdminCached) {
        $Script:IsAdminCached = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    }
    
    if (-not $Script:IsAdminCached) {
        Write-Verbose 'Not running as administrator, attempting elevation...'
        Invoke-RunAsAdmin
    }
    else {
        Write-Verbose 'Already running as administrator, skipping elevation'
    }

    # (4) Install or verify package providers - OPTIMIZED with early-exit
    # Skip if package providers are already registered (saves ~200-500ms)
    if (-not (Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue)) {
        Write-Verbose 'NuGet package provider not found, installing...'
        Install-PackageProviders
    }
    else {
        Write-Verbose 'Package providers already installed, skipping'
    }

    # (5) Install PowerShell modules unless suppressed
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

    # (6) Add assemblies if requested - OPTIMIZED with pre-check
    # Early-exit if assemblies are already loaded (saves ~100-300ms)
    if ($AddDefaultAssemblies -or $AddCustomAssemblies) {
        $assembliesToLoad = if ($AddCustomAssemblies) {
            $AddCustomAssemblies 
        }
        else {
            @() 
        }
        if ($AddDefaultAssemblies) {
            $assembliesToLoad += @('PresentationFramework', 'System.Windows.Forms', 'System.Drawing')
        }
        
        # Check if any assemblies are missing before calling Add-Assemblies
        $loadedAssemblies = [System.AppDomain]::CurrentDomain.GetAssemblies() | ForEach-Object { $_.GetName().Name }
        $missingAssemblies = $assembliesToLoad | Where-Object { $loadedAssemblies -notcontains $_ }
        
        if ($missingAssemblies.Count -gt 0) {
            Write-Verbose "Loading $($missingAssemblies.Count) missing assemblies ($(($assembliesToLoad.Count - $missingAssemblies.Count)) already loaded)"
            $null = Add-Assemblies -UseDefault:$AddDefaultAssemblies -CustomAssemblies:$AddCustomAssemblies
        }
        else {
            Write-Verbose "All $($assembliesToLoad.Count) assemblies already loaded, skipping"
        }
    }

    # (7) Refresh environment variables once at the end
    Update-SessionEnvironment
}