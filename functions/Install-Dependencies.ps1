function Install-Dependencies {
    [CmdletBinding()]
    param(
        [switch]$RemoveAllModules,
        [string[]]$PSModule,
        [hashtable]$NugetPackage,
        [switch]$NoPSModules,
        [switch]$NoNugetPackage,
        [switch]$InstallDefaultPSModules,
        [switch]$InstallDefaultNugetPackage,
        [switch]$AddDefaultAssemblies,
        [string[]]$AddCustomAssemblies,
        [string]$LocalModulesDirectory,
        [string]$LocalNugetDirectory,
        [switch]$SaveLocally
    )

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

    # (4) Install NuGet dependencies unless suppressed
    if (-not $NoNugetPackage ) {
        $null = Install-NugetDeps `
            -InstallDefaultNugetPackage:$InstallDefaultNugetPackage `
            -NugetPackage:$NugetPackage `
            -SaveLocally:$SaveLocally `
            -LocalNugetDirectory:$LocalNugetDirectory
    }

    # (5) Add assemblies if requested
    if ($AddDefaultAssemblies -or $AddCustomAssemblies) {
        $null = Add-Assemblies `
            -UseDefault:$AddDefaultAssemblies `
            -CustomAssemblies:$AddCustomAssemblies

    }

    # (6) Install PowerShell modules unless suppressed
    if (-not $NoPSModules) {
        $null = Install-PSModule `
            -InstallDefaultPSModules:$InstallDefaultPSModules `
            -PSModule:$PSModule `
            -RemoveAllModules:$RemoveAllModules `
            -LocalModulesDirectory:$LocalModulesDirectory

    }

    # (7) Refresh environment variables once at the end
    Update-SessionEnvironment
}