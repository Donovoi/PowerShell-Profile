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
    # Load all required cmdlets (replaces 100+ lines of boilerplate)
    Initialize-CmdletDependencies -RequiredCmdlets @(
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
    ) -PreferLocal -Force

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