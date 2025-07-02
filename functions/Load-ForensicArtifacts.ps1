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

try {
    # Load modules in order
    $neededcmdlets = @(
        'Initialize-ForensicDependencies'     # For installing dependencies
        'ConvertTo-ForensicArtifact'
        'Copy-FileSystemUtilities'           # For copying files
        'Copy-ForensicArtifact'              # For copying artifacts
        'Invoke-ForensicCollection'          # For collecting artifacts
        'Write-ForensicReport'               # For writing reports
        'Get-ForensicArtifacts'               # Main function to get artifacts
    )

    foreach ($cmd in $neededcmdlets) {
        if (-not (Get-Command -Name 'Install-Cmdlet' -ErrorAction SilentlyContinue)) {
            $method = Invoke-RestMethod -Uri 'https://raw.githubusercontent.com/Donovoi/PowerShell-Profile/main/functions/Install-Cmdlet.ps1'
            $finalstring = [scriptblock]::Create($method.ToString() + "`nExport-ModuleMember -Function * -Alias *")
            New-Module -Name 'InstallCmdlet' -ScriptBlock $finalstring | Import-Module
        }
        Write-Verbose "Importing cmdlet: $cmd"
        $scriptBlock = Install-Cmdlet -RepositoryCmdlets $cmd -Force

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
        elseif ([System.IO.FileInfo]$scriptBlock -is [System.IO.FileInfo]) {
            # If a file path was returned, import it
            Import-Module -Name $scriptBlock -Force -Global
            Write-Verbose "Imported $cmd from file: $scriptBlock"
        }
        else {
            Write-Warning "Could not import $cmd`: Unexpected return type from Install-Cmdlet"
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
    Write-Information 'Forensic Artifacts module loaded successfully!' -InformationAction Continue
    Write-Information 'Available commands:' -InformationAction Continue
    Write-Information '  Get-ForensicArtifacts - Main function for artifact collection' -InformationAction Continue
    Write-Information '  Use Get-Help Get-ForensicArtifacts -Full for detailed usage' -InformationAction Continue

    if ($PassThru) {
        return [PSCustomObject]@{
            ModuleRoot    = $ModuleRoot
            LoadedModules = $ForensicModules
            CoreFunctions = $CoreFunctions
            LoadTime      = Get-Date
        }
    }
}
catch {
    Write-Error "Failed to load Forensic Artifacts module: $($_.Exception.Message)" -ErrorAction Stop
}

