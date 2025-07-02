function Invoke-AllForensicCollection {
    <#
    .SYNOPSIS
    Retrieves and collects all available forensic artifacts.

    .DESCRIPTION
    Downloads forensic artifact definitions and processes all artifacts for collection,
    with optional filtering support.

    .PARAMETER CollectionPath
    Root path where artifacts will be collected.

    .PARAMETER ToolsPath
    Path where forensic tools are located.

    .PARAMETER SkipToolDownload
    Skip automatic download of forensic tools.

    .PARAMETER ArtifactFilter
    Array of strings to filter artifacts by name.

    .OUTPUTS
    PSCustomObject with overall collection results and statistics.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)]
        [string]$CollectionPath,
        
        [string]$ToolsPath = (Join-Path $PSScriptRoot 'Tools'),
        
        [switch]$SkipToolDownload,
        
        [string[]]$ArtifactFilter = @()
    )

    $requiredFunctions = @(
        'Install-Dependencies'     # For installing dependencies
        'Get-LatestGitHubRelease'  # For downloading aria2c if needed
        'Invoke-AriaDownload'
        'Get-FileDetailsFromResponse'
        'Get-OutputFilename'
        'Test-InPath'
        'Invoke-AriaRPCDownload'
        'Get-SYSTEM'
        'Invoke-RawCopy'
        'Copy-FileSystemUtilities'  # For copying files
        'Copy-ForensicArtifact'     # For copying artifacts
    )

    foreach ($cmd in $requiredFunctions) {
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

    # Override with local functions if they exist (for development/debugging)
    $localCopyForensicArtifact = Join-Path $PSScriptRoot 'Copy-ForensicArtifact.ps1'
    if (Test-Path $localCopyForensicArtifact) {
        Write-Verbose 'Loading local Copy-ForensicArtifact.ps1 for testing/development'
        . $localCopyForensicArtifact
    }

    $overallResult = [PSCustomObject]@{
        CollectionType      = 'All Artifacts'
        TotalArtifacts      = 0
        ProcessedArtifacts  = 0
        SuccessfulArtifacts = 0
        TotalFilesCollected = 0
        CollectionPath      = $CollectionPath
        StartTime           = Get-Date
        EndTime             = $null
        Duration            = $null
        ArtifactResults     = @()
        Errors              = @()
    }

    try {
        # Initialize dependencies (powershell-yaml)
        try {
            Import-Module powershell-yaml -ErrorAction Stop
            Write-Verbose 'powershell-yaml module loaded successfully'
        }
        catch {
            Write-Warning 'powershell-yaml module not found. Attempting to install...'
            try {
                if (Get-Command Install-Module -ErrorAction SilentlyContinue) {
                    Install-Module -Name powershell-yaml -Force -Scope CurrentUser -ErrorAction Stop
                    Import-Module powershell-yaml -ErrorAction Stop
                    Write-Verbose 'powershell-yaml module installed and loaded'
                }
                else {
                    throw 'Install-Module not available. Please install powershell-yaml module manually.'
                }
            }
            catch {
                $overallResult.Errors += "Failed to initialize dependencies: $($_.Exception.Message)"
                throw "Failed to initialize dependencies: $($_.Exception.Message)"
            }
        }

        # Create collection directory
        if (-not (Test-Path $CollectionPath)) {
            New-Item -Path $CollectionPath -ItemType Directory -Force | Out-Null
            Write-Verbose "Created collection directory: $CollectionPath"
        }

        # Download and process artifacts
        Write-Verbose 'Downloading forensic artifacts definitions...'
        $artifactsSourceUrl = 'https://raw.githubusercontent.com/ForensicArtifacts/artifacts/main/artifacts/data/windows.yaml'
        
        $yamlContent = Invoke-RestMethod -Uri $artifactsSourceUrl -ErrorAction Stop
        $artifactsData = ConvertFrom-Yaml -AllDocuments $yamlContent
        
        $overallResult.TotalArtifacts = $artifactsData.Count
        Write-Verbose "Processing $($artifactsData.Count) artifact definitions..."

        foreach ($artifact in $artifactsData) {
            try {
                # Apply artifact filter if specified
                $includeArtifact = $true
                if ($ArtifactFilter -and $ArtifactFilter.Count -gt 0) {
                    $includeArtifact = $false
                    foreach ($filter in $ArtifactFilter) {
                        if ($artifact.name -like "*$filter*") {
                            $includeArtifact = $true
                            break
                        }
                    }
                }
                
                if (-not $includeArtifact) {
                    continue
                }

                $overallResult.ProcessedArtifacts++

                # Process artifact data
                $artifactType = $artifact.sources.type
                $paths = @()
                
                # Extract paths based on artifact type
                switch ($artifactType) {
                    'REGISTRY_VALUE' {
                        if ($artifact.sources.attributes.key_value_pairs) {
                            foreach ($pair in $artifact.sources.attributes.key_value_pairs) {
                                $regPath = $pair.registry_path ?? $pair.path
                                if ($regPath) {
                                    $paths += $regPath 
                                }
                            }
                        }
                    }
                    'REGISTRY_KEY' {
                        if ($artifact.sources.attributes.keys) {
                            $paths += $artifact.sources.attributes.keys
                        }
                    }
                    'FILE' {
                        if ($artifact.sources.attributes.paths) {
                            $paths += $artifact.sources.attributes.paths
                        }
                    }
                    default {
                        if ($artifact.sources.attributes.paths) {
                            $paths += $artifact.sources.attributes.paths
                        }
                        if ($artifact.sources.attributes.keys) {
                            $paths += $artifact.sources.attributes.keys
                        }
                    }
                }
                
                # Expand paths
                $expandedPaths = @()
                if ($paths) {
                    foreach ($path in $paths) {
                        if (-not [string]::IsNullOrEmpty($path)) {
                            # Simple path expansion
                            $expandedPath = $path
                            $expandedPath = $expandedPath -replace '%%environ_systemroot%%', $env:SystemRoot
                            $expandedPath = $expandedPath -replace '%%environ_systemdrive%%', $env:SystemDrive
                            $expandedPath = $expandedPath -replace '%%environ_programfiles%%', $env:ProgramFiles
                            $expandedPath = $expandedPath -replace '%%environ_programfilesx86%%', ${env:ProgramFiles(x86)}
                            $expandedPath = $expandedPath -replace '%%environ_windir%%', $env:WINDIR
                            $expandedPath = $expandedPath -replace '%%environ_allusersprofile%%', $env:ALLUSERSPROFILE
                            $expandedPath = $expandedPath -replace '%%users\.appdata%%', $env:APPDATA
                            $expandedPath = $expandedPath -replace '%%users\.localappdata%%', $env:LOCALAPPDATA
                            $expandedPath = $expandedPath -replace '%%users\.userprofile%%', $env:USERPROFILE
                            
                            # Handle user profile path patterns - check if path starts with %%users.username%%
                            if ($expandedPath -match '^%%users\.username%%\\') {
                                # Replace with full user profile path
                                $expandedPath = $expandedPath -replace '^%%users\.username%%\\', "$env:USERPROFILE\"
                            }
                            else {
                                # For other occurrences, just replace with username
                                $expandedPath = $expandedPath -replace '%%users\.username%%', $env:USERNAME
                            }
                            
                            $expandedPath = $expandedPath -replace '%%users\.sid%%', '*'  # Use wildcard for SID matching
                            
                            # Fix known incorrect artifact paths
                            # The official ForensicArtifacts definition has L.%%users.username%% but Windows actually uses different directory naming
                            $expandedPath = $expandedPath -replace '\\ConnectedDevicesPlatform\\L\.([^\\]+)\\', '\ConnectedDevicesPlatform\*\'
                            
                            $expandedPath = [Environment]::ExpandEnvironmentVariables($expandedPath)
                            $expandedPaths += $expandedPath
                        }
                    }
                }
                
                # Create artifact object
                $processedArtifact = [PSCustomObject][Ordered]@{
                    Name           = $artifact.name
                    Description    = $artifact.doc
                    Type           = $artifactType
                    References     = $artifact.urls
                    Paths          = $paths
                    ExpandedPaths  = $expandedPaths
                    ProcessingDate = Get-Date
                }

                # Collect the artifact
                if ($processedArtifact.ExpandedPaths -and $processedArtifact.ExpandedPaths.Count -gt 0) {
                    $artifactResult = Invoke-ForensicCollection -Artifact $processedArtifact -CollectionPath $CollectionPath -ToolsPath $ToolsPath -SkipToolDownload:$SkipToolDownload
                    
                    $overallResult.ArtifactResults += $artifactResult
                    $overallResult.TotalFilesCollected += $artifactResult.FilesCollected
                    
                    if ($artifactResult.Success) {
                        $overallResult.SuccessfulArtifacts++
                    }
                    
                    $overallResult.Errors += $artifactResult.Errors
                    
                    Write-Verbose "Processed artifact '$($artifact.name)': $($artifactResult.FilesCollected) files collected"
                }
                else {
                    Write-Verbose "Skipping artifact '$($artifact.name)': No valid paths found"
                }
            }
            catch {
                $overallResult.Errors += "Error processing artifact '$($artifact.name)': $($_.Exception.Message)"
                Write-Warning "Error processing artifact '$($artifact.name)': $($_.Exception.Message)"
            }
        }

        $overallResult.EndTime = Get-Date
        $overallResult.Duration = $overallResult.EndTime - $overallResult.StartTime

        Write-Information 'Collection Summary:' -InformationAction Continue
        Write-Information "  Total Artifacts: $($overallResult.TotalArtifacts)" -InformationAction Continue
        Write-Information "  Processed Artifacts: $($overallResult.ProcessedArtifacts)" -InformationAction Continue
        Write-Information "  Successful Artifacts: $($overallResult.SuccessfulArtifacts)" -InformationAction Continue
        Write-Information "  Total Files Collected: $($overallResult.TotalFilesCollected)" -InformationAction Continue
        Write-Information "  Collection Path: $($overallResult.CollectionPath)" -InformationAction Continue
        Write-Information "  Duration: $($overallResult.Duration.TotalMinutes.ToString('F2')) minutes" -InformationAction Continue

        return $overallResult
    }
    catch {
        $overallResult.Errors += $_.Exception.Message
        $overallResult.EndTime = Get-Date
        $overallResult.Duration = $overallResult.EndTime - $overallResult.StartTime
        Write-Error "Failed to collect all forensic artifacts: $($_.Exception.Message)"
        return $overallResult
    }
}

function Invoke-ForensicCollection {
    <#
    .SYNOPSIS
    Collects forensic artifacts from the file system and registry.

    .DESCRIPTION
    Performs the actual collection of forensic artifacts, handling both file system
    and registry artifacts with appropriate error handling and forensic tool usage.
    When no specific artifact is provided, retrieves and collects all available artifacts.

    .PARAMETER Artifact
    The processed artifact object to collect. If not specified, all available artifacts will be retrieved and collected.

    .PARAMETER CollectionPath
    Root path where artifacts will be collected.

    .PARAMETER ToolsPath
    Path where forensic tools are located.

    .PARAMETER SkipToolDownload
    Skip automatic download of forensic tools.

    .PARAMETER ArtifactFilter
    Array of strings to filter artifacts by name when collecting all artifacts.

    .EXAMPLE
    $result = Invoke-ForensicCollection -Artifact $artifact -CollectionPath "C:\Investigation"

    .EXAMPLE
    Invoke-ForensicCollection -CollectionPath "C:\Investigation" -Verbose
    # Collects all available forensic artifacts

    .EXAMPLE
    Invoke-ForensicCollection -CollectionPath "C:\Investigation" -ArtifactFilter @("Browser", "Registry") -Verbose
    # Collects only browser and registry related artifacts

    .OUTPUTS
    PSCustomObject with collection results and statistics.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter()]
        [PSObject]$Artifact,
        
        [Parameter(Mandatory)]
        [string]$CollectionPath,
        
        [string]$ToolsPath = (Join-Path $PSScriptRoot 'Tools'),
        
        [switch]$SkipToolDownload,
        
        [string[]]$ArtifactFilter = @()
    )

    # If no specific artifact provided, retrieve and collect all artifacts
    if (-not $Artifact) {
        Write-Verbose 'No specific artifact provided - retrieving all available artifacts'
        return Invoke-AllForensicCollection -CollectionPath $CollectionPath -ToolsPath $ToolsPath -SkipToolDownload:$SkipToolDownload -ArtifactFilter $ArtifactFilter
    }

    $collectionResult = [PSCustomObject]@{
        ArtifactName   = $Artifact.Name
        Success        = $false
        FilesCollected = 0
        Errors         = @()
        CollectionPath = $null
    }

    try {
        # Create artifact-specific directory
        $artifactDir = Join-Path $CollectionPath ($Artifact.Name -replace '[\\/:*?"<>|]', '_')
        if (-not (Test-Path $artifactDir)) {
            New-Item -Path $artifactDir -ItemType Directory -Force | Out-Null
        }
        $collectionResult.CollectionPath = $artifactDir

        # Initialize forensic tools if not skipping
        $forensicTools = @()
        if (-not $SkipToolDownload) {
            $forensicTools = Initialize-ForensicTool -ToolsPath $ToolsPath
        }

        # Process each path in the artifact
        if ($Artifact.ExpandedPaths) {
            foreach ($path in $Artifact.ExpandedPaths) {
                try {
                    $pathResult = Copy-ForensicArtifact -SourcePath $path -DestinationPath $artifactDir -ForensicTools $forensicTools
                    if ($pathResult.Success) {
                        $collectionResult.FilesCollected += $pathResult.FilesCollected
                        $collectionResult.Success = $true
                    }
                    $collectionResult.Errors += $pathResult.Errors
                }
                catch {
                    $collectionResult.Errors += "Path '$path': $($_.Exception.Message)"
                    Write-Warning "Failed to collect from path '$path': $($_.Exception.Message)"
                }
            }
        }

        # Clean up empty directories
        if ($collectionResult.FilesCollected -eq 0) {
            try {
                $dirContents = Get-ChildItem -Path $artifactDir -ErrorAction SilentlyContinue
                if (-not $dirContents) {
                    Remove-Item -Path $artifactDir -Force -ErrorAction SilentlyContinue
                    $collectionResult.CollectionPath = $null
                }
            }
            catch {
                Write-Verbose "Could not clean up empty directory: $($_.Exception.Message)"
            }
        }

        Write-Verbose "Collection completed for '$($Artifact.Name)': $($collectionResult.FilesCollected) files collected"
        return $collectionResult
    }
    catch {
        $collectionResult.Errors += $_.Exception.Message
        Write-Error "Failed to collect artifact '$($Artifact.Name)': $($_.Exception.Message)"
        return $collectionResult
    }
}

function Initialize-ForensicTool {
    <#
    .SYNOPSIS
    Initializes and downloads forensic tools for collection operations.

    .DESCRIPTION
    Sets up the tools directory and downloads required forensic tools like RawCopy
    for copying locked files during artifact collection.

    .PARAMETER ToolsPath
    Directory where tools will be stored.

    .EXAMPLE
    $tools = Initialize-ForensicTool -ToolsPath "C:\Tools"

    .OUTPUTS
    Array of available forensic tool objects.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject[]])]
    param(
        [Parameter(Mandatory)]
        [string]$ToolsPath
    )

    # Use script-level caching to avoid repeated downloads
    if ($script:CachedForensicTools) {
        Write-Verbose 'Using cached forensic tools'
        return $script:CachedForensicTools
    }

    $forensicTools = @()

    try {
        # Create tools directory
        if (-not (Test-Path $ToolsPath)) {
            New-Item -Path $ToolsPath -ItemType Directory -Force | Out-Null
            Write-Verbose "Created tools directory: $ToolsPath"
        }

        # Check for Invoke-RawCopy function (preferred method)
        if (Get-Command Invoke-RawCopy -ErrorAction SilentlyContinue) {
            $forensicTools += [PSCustomObject]@{
                Name     = 'Invoke-RawCopy'
                Path     = 'Invoke-RawCopy'
                Type     = 'Function'
                Priority = 1
            }
            Write-Verbose 'Found Invoke-RawCopy function (preferred forensic copy method)'
        }
        else {
            # Try to load Invoke-RawCopy from the functions directory
            $rawCopyScript = Join-Path $PSScriptRoot 'Invoke-RawCopy.ps1'
            if (Test-Path $rawCopyScript) {
                try {
                    . $rawCopyScript
                    $forensicTools += [PSCustomObject]@{
                        Name     = 'Invoke-RawCopy'
                        Path     = 'Invoke-RawCopy'
                        Type     = 'Function'
                        Priority = 1
                    }
                    Write-Verbose 'Loaded and registered Invoke-RawCopy function'
                }
                catch {
                    Write-Verbose "Failed to load Invoke-RawCopy: $($_.Exception.Message)"
                }
            }
        }

        # Add built-in tools (lower priority than Invoke-RawCopy)
        $builtInTools = @(
            @{ Name = 'Robocopy'; Path = 'robocopy.exe'; Type = 'BuiltIn'; Priority = 3 },
            @{ Name = 'XCopy'; Path = 'xcopy.exe'; Type = 'BuiltIn'; Priority = 4 }
        )

        foreach ($tool in $builtInTools) {
            if (Get-Command $tool.Path -ErrorAction SilentlyContinue) {
                $forensicTools += [PSCustomObject]$tool
                Write-Verbose "Found built-in tool: $($tool.Name)"
            }
        }

        # Sort tools by priority (lower number = higher priority)
        $script:CachedForensicTools = $forensicTools | Sort-Object Priority, Name
        Write-Verbose "Initialized $($forensicTools.Count) forensic tools (Invoke-RawCopy preferred)"
        return $script:CachedForensicTools
    }
    catch {
        Write-Warning "Failed to initialize forensic tools: $($_.Exception.Message)"
        return @()
    }
}

function Install-RawCopyTool {
    <#
    .SYNOPSIS
    Downloads the RawCopy forensic tool from GitHub.

    .DESCRIPTION
    Attempts to download the RawCopy executable from the official GitHub repository
    for use in forensic file copying operations.

    .PARAMETER ToolsPath
    Directory where the tool will be saved.

    .EXAMPLE
    $success = Install-RawCopyTool -ToolsPath "C:\Tools"

    .OUTPUTS
    Boolean indicating whether the download was successful.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string]$ToolsPath
    )

    # Use script-level variable to track download attempts
    if ($script:RawCopyDownloadAttempted) {
        Write-Verbose 'RawCopy download already attempted'
        return $false
    }

    $script:RawCopyDownloadAttempted = $true
    $rawCopyPath = Join-Path $ToolsPath 'rawcopy.exe'

    try {
        Write-Verbose 'Downloading RawCopy from GitHub...'
        $downloadUrl = 'https://github.com/jschicht/RawCopy/releases/latest/download/RawCopy.exe'
        
        Invoke-WebRequest -Uri $downloadUrl -OutFile $rawCopyPath -TimeoutSec 30 -ErrorAction Stop
        
        if (Test-Path $rawCopyPath) {
            Write-Verbose "Successfully downloaded RawCopy to: $rawCopyPath"
            return $true
        }
        else {
            Write-Warning 'RawCopy download completed but file not found'
            return $false
        }
    }
    catch {
        Write-Verbose "Failed to download RawCopy: $($_.Exception.Message)"
        Write-Verbose 'You can manually download RawCopy from: https://github.com/jschicht/RawCopy'
        return $false
    }
}

function Copy-ForensicArtifact {
    <#
    .SYNOPSIS
    Copies individual forensic artifacts from source to destination.

    .DESCRIPTION
    Handles the copying of files and registry keys with support for locked files,
    recursive patterns, and multiple copy methods including forensic tools.

    .PARAMETER SourcePath
    The source path to copy from.

    .PARAMETER DestinationPath
    The destination directory for the artifact.

    .PARAMETER ForensicTools
    Array of available forensic tools for locked file copying.

    .EXAMPLE
    $result = Copy-ForensicArtifact -SourcePath $path -DestinationPath $dest -ForensicTools $tools

    .OUTPUTS
    PSCustomObject with copy operation results.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)]
        [string]$SourcePath,
        
        [Parameter(Mandatory)]
        [string]$DestinationPath,
        
        [PSCustomObject[]]$ForensicTools = @()
    )

    $copyResult = [PSCustomObject]@{
        Success        = $false
        FilesCollected = 0
        Errors         = @()
    }

    try {
        Write-Verbose "Processing source path: $SourcePath"

        # Handle registry paths
        if ($SourcePath -match '^HK(EY_)?(LOCAL_MACHINE|CURRENT_USER|CLASSES_ROOT|USERS|CURRENT_CONFIG|LM|CU|CR|U|CC)\\') {
            # Check if this is a wildcard registry path (ends with *)
            if ($SourcePath.EndsWith('\*')) {
                # Convert to PowerShell registry provider format and recurse
                $parentKeyPath = $SourcePath.TrimEnd('\*')
                $psRegistryPath = ConvertTo-PowerShellRegistryPath -RegistryPath $parentKeyPath
                if ($psRegistryPath) {
                    Write-Verbose "Recursing registry path: $psRegistryPath"
                    
                    # Create directory structure based on parent key path
                    $parentKeySanitized = $parentKeyPath -replace '[\\/:*?"<>|]', '_'
                    $parentKeyDir = Join-Path $DestinationPath "registry_$parentKeySanitized"
                    if (-not (Test-Path $parentKeyDir)) {
                        New-Item -Path $parentKeyDir -ItemType Directory -Force | Out-Null
                        Write-Verbose "Created parent registry directory: $parentKeyDir"
                    }
                    
                    try {
                        $subKeys = Get-ChildItem -Path $psRegistryPath -ErrorAction SilentlyContinue
                        foreach ($subKey in $subKeys) {
                            # Each subkey becomes a file in the parent directory
                            $subKeyName = $subKey.PSChildName
                            $subKeySanitized = $subKeyName -replace '[\\/:*?"<>|]', '_'
                            $subKeyFile = Join-Path $parentKeyDir "$subKeySanitized.reg"
                            
                            # Convert back to standard format for export
                            $subKeyFullPath = ConvertFrom-PowerShellRegistryPath -PowerShellPath $subKey.PSPath
                            Write-Verbose "Processing registry subkey: $subKeyFullPath -> $subKeyFile"
                            
                            # Export this specific subkey
                            $registryResult = Copy-RegistryArtifact -RegistryPath $subKeyFullPath -DestinationPath $parentKeyDir -OutputFileName "$subKeySanitized.reg"
                            if ($registryResult.Success) {
                                $copyResult.FilesCollected++
                                $copyResult.Success = $true
                            }
                            else {
                                $copyResult.Errors += $registryResult.Error
                            }
                        }
                    }
                    catch {
                        $copyResult.Errors += "Failed to enumerate registry subkeys: $($_.Exception.Message)"
                    }
                }
                else {
                    $copyResult.Errors += "Failed to convert registry path to PowerShell format: $SourcePath"
                }
            }
            else {
                # Single registry key export
                $registryResult = Copy-RegistryArtifact -RegistryPath $SourcePath -DestinationPath $DestinationPath
                $copyResult.Success = $registryResult.Success
                $copyResult.FilesCollected = if ($registryResult.Success) {
                    1 
                }
                else {
                    0 
                }
                if (-not $registryResult.Success) {
                    $copyResult.Errors += $registryResult.Error
                }
            }
            return $copyResult
        }

        # Handle file system paths
        $fileResult = Copy-FileSystemArtifact -SourcePath $SourcePath -DestinationPath $DestinationPath -ForensicTools $ForensicTools
        $copyResult.Success = $fileResult.Success
        $copyResult.FilesCollected = $fileResult.FilesCollected
        $copyResult.Errors += $fileResult.Errors

        return $copyResult
    }
    catch {
        $copyResult.Errors += $_.Exception.Message
        Write-Warning "Error copying artifact from '$SourcePath': $($_.Exception.Message)"
        return $copyResult
    }
}

function ConvertTo-PowerShellRegistryPath {
    <#
    .SYNOPSIS
    Converts forensic registry paths to PowerShell registry provider format.

    .DESCRIPTION
    Converts registry paths from formats like "HKEY_LOCAL_MACHINE\Software" 
    to PowerShell registry provider format like "HKLM:\Software".

    .PARAMETER RegistryPath
    The registry path to convert.

    .EXAMPLE
    $psPath = ConvertTo-PowerShellRegistryPath -RegistryPath "HKEY_LOCAL_MACHINE\Software"
    # Returns: "HKLM:\Software"

    .OUTPUTS
    String containing the PowerShell registry path, or null if invalid.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$RegistryPath
    )

    if ([string]::IsNullOrEmpty($RegistryPath)) {
        return $null
    }

    # Registry hive mappings to PowerShell providers
    $hiveMappings = @{
        '^HKEY_LOCAL_MACHINE\\'  = 'HKLM:\'
        '^HKLM\\'                = 'HKLM:\'
        '^HKEY_CURRENT_USER\\'   = 'HKCU:\'
        '^HKCU\\'                = 'HKCU:\'
        '^HKEY_CLASSES_ROOT\\'   = 'HKCR:\'
        '^HKCR\\'                = 'HKCR:\'
        '^HKEY_USERS\\'          = 'HKU:\'
        '^HKU\\'                 = 'HKU:\'
        '^HKEY_CURRENT_CONFIG\\' = 'HKCC:\'
        '^HKCC\\'                = 'HKCC:\'
    }

    $psPath = $RegistryPath

    # Apply hive mappings
    foreach ($mapping in $hiveMappings.GetEnumerator()) {
        if ($psPath -match $mapping.Key) {
            $psPath = $psPath -replace $mapping.Key, $mapping.Value
            break
        }
    }

    # Validate that we have a valid PowerShell registry path
    if ($psPath -match '^HK[LCRU][MCRU]*:') {
        return $psPath
    }

    return $null
}

function ConvertFrom-PowerShellRegistryPath {
    <#
    .SYNOPSIS
    Converts PowerShell registry provider paths back to standard registry format.

    .DESCRIPTION
    Converts registry paths from PowerShell provider format like "HKLM:\Software" 
    back to standard format like "HKEY_LOCAL_MACHINE\Software".

    .PARAMETER PowerShellPath
    The PowerShell registry path to convert.

    .EXAMPLE
    $stdPath = ConvertFrom-PowerShellRegistryPath -PowerShellPath "HKLM:\Software"
    # Returns: "HKEY_LOCAL_MACHINE\Software"

    .OUTPUTS
    String containing the standard registry path.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$PowerShellPath
    )

    if ([string]::IsNullOrEmpty($PowerShellPath)) {
        return $null
    }

    # Handle Microsoft.PowerShell.Core\Registry:: prefix
    $cleanPath = $PowerShellPath -replace '^Microsoft\.PowerShell\.Core\\Registry::', ''

    # Registry hive mappings from PowerShell providers
    $hiveMappings = @{
        '^HKLM:' = 'HKEY_LOCAL_MACHINE'
        '^HKCU:' = 'HKEY_CURRENT_USER'
        '^HKCR:' = 'HKEY_CLASSES_ROOT'
        '^HKU:'  = 'HKEY_USERS'
        '^HKCC:' = 'HKEY_CURRENT_CONFIG'
    }

    $stdPath = $cleanPath

    # Apply hive mappings
    foreach ($mapping in $hiveMappings.GetEnumerator()) {
        if ($stdPath -match $mapping.Key) {
            $stdPath = $stdPath -replace $mapping.Key, $mapping.Value
            break
        }
    }

    # Convert forward slashes to backslashes if any
    $stdPath = $stdPath -replace '/', '\'

    return $stdPath
}

# Example usage - collect all forensic artifacts
#Invoke-ForensicCollection -CollectionPath 'C:\ForensicCollection' -Verbose