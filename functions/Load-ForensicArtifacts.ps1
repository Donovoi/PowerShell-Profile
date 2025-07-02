# Forensic Artifacts Module Loader
# Loads all forensic artifact collection functions with proper dependency management

param(
    [switch]$Force,
    [switch]$PassThru
)

# Initialize script-level variables for caching
if (-not $script:DependenciesInitialized -or $Force) {
    $script:DependenciesInitialized = $false
    $script:CachedForensicTools = $null
    $script:RawCopyDownloadAttempted = $false
}

# Define module root
$ModuleRoot = $PSScriptRoot

# Define required modules in dependency order
$ForensicModules = @(
    'Initialize-ForensicEnvironment.ps1',
    'ConvertTo-ForensicArtifact.ps1', 
    'Copy-FileSystemUtilities.ps1',
    'Copy-ForensicArtifact.ps1',
    'Invoke-ForensicCollection.ps1',
    'Write-ForensicReport.ps1',
    'Get-ForensicArtifacts.ps1'
)

Write-Verbose "Loading Forensic Artifacts module from: $ModuleRoot"

try {
    # Load modules in order
    foreach ($module in $ForensicModules) {
        $modulePath = Join-Path $ModuleRoot $module
        
        if (Test-Path $modulePath) {
            Write-Verbose "Loading module: $module"
            . $modulePath
        }
        else {
            Write-Warning "Module file not found: $modulePath"
        }
    }

    # Verify core functions are available
    $CoreFunctions = @(
        'Get-ForensicArtifacts',
        'Initialize-ForensicDependencies', 
        'ConvertTo-ForensicArtifact',
        'Invoke-ForensicCollection'
    )

    $MissingFunctions = @()
    foreach ($function in $CoreFunctions) {
        if (-not (Get-Command $function -ErrorAction SilentlyContinue)) {
            $MissingFunctions += $function
        }
    }

    if ($MissingFunctions.Count -gt 0) {
        throw "Failed to load core functions: $($MissingFunctions -join ', ')"
    }

    Write-Verbose "Successfully loaded $($ForensicModules.Count) forensic artifact modules"
    Write-Information "Forensic Artifacts module loaded successfully!" -InformationAction Continue
    Write-Information "Available commands:" -InformationAction Continue
    Write-Information "  Get-ForensicArtifacts - Main function for artifact collection" -InformationAction Continue
    Write-Information "  Use Get-Help Get-ForensicArtifacts -Full for detailed usage" -InformationAction Continue

    if ($PassThru) {
        return [PSCustomObject]@{
            ModuleRoot = $ModuleRoot
            LoadedModules = $ForensicModules
            CoreFunctions = $CoreFunctions
            LoadTime = Get-Date
        }
    }
}
catch {
    Write-Error "Failed to load Forensic Artifacts module: $($_.Exception.Message)" -ErrorAction Stop
}

# Export module members (if running as a module)
if ($MyInvocation.InvocationName -eq '.') {
    Export-ModuleMember -Function @(
        'Get-ForensicArtifacts',
        'Initialize-ForensicDependencies',
        'ConvertTo-ForensicArtifact', 
        'Invoke-ForensicCollection',
        'Copy-ForensicArtifact',
        'Expand-ForensicPath',
        'Write-ForensicCollectionReport'
    )
}
