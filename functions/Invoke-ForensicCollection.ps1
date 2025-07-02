function Invoke-ForensicCollection {
    <#
    .SYNOPSIS
    Collects forensic artifacts from the file system and registry.

    .DESCRIPTION
    Performs the actual collection of forensic artifacts, handling both file system
    and registry artifacts with appropriate error handling and forensic tool usage.

    .PARAMETER Artifact
    The processed artifact object to collect.

    .PARAMETER CollectionPath
    Root path where artifacts will be collected.

    .PARAMETER ToolsPath
    Path where forensic tools are located.

    .PARAMETER SkipToolDownload
    Skip automatic download of forensic tools.

    .EXAMPLE
    $result = Invoke-ForensicCollection -Artifact $artifact -CollectionPath "C:\Investigation"

    .OUTPUTS
    PSCustomObject with collection results and statistics.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)]
        [PSObject]$Artifact,
        
        [Parameter(Mandatory)]
        [string]$CollectionPath,
        
        [string]$ToolsPath = (Join-Path $PSScriptRoot 'Tools'),
        
        [switch]$SkipToolDownload
    )

    $collectionResult = [PSCustomObject]@{
        ArtifactName = $Artifact.Name
        Success = $false
        FilesCollected = 0
        Errors = @()
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
        Write-Verbose "Using cached forensic tools"
        return $script:CachedForensicTools
    }

    $forensicTools = @()

    try {
        # Create tools directory
        if (-not (Test-Path $ToolsPath)) {
            New-Item -Path $ToolsPath -ItemType Directory -Force | Out-Null
            Write-Verbose "Created tools directory: $ToolsPath"
        }

        # Check for RawCopy
        $rawCopyPath = Join-Path $ToolsPath 'rawcopy.exe'
        if (Test-Path $rawCopyPath) {
            $forensicTools += [PSCustomObject]@{
                Name = 'RawCopy'
                Path = $rawCopyPath
                Type = 'Executable'
            }
            Write-Verbose "Found RawCopy tool at: $rawCopyPath"
        }
        else {
            Write-Verbose "RawCopy not found, attempting download..."
            if (Install-RawCopyTool -ToolsPath $ToolsPath) {
                $forensicTools += [PSCustomObject]@{
                    Name = 'RawCopy'
                    Path = $rawCopyPath
                    Type = 'Executable'
                }
            }
        }

        # Check for custom RawyCopy function
        if (Get-Command Invoke-RawyCopy -ErrorAction SilentlyContinue) {
            $forensicTools += [PSCustomObject]@{
                Name = 'RawyCopy'
                Path = 'Invoke-RawyCopy'
                Type = 'Function'
            }
            Write-Verbose "Found Invoke-RawyCopy function"
        }

        # Add built-in tools
        $builtInTools = @(
            @{ Name = 'Robocopy'; Path = 'robocopy.exe'; Type = 'BuiltIn' },
            @{ Name = 'XCopy'; Path = 'xcopy.exe'; Type = 'BuiltIn' }
        )

        foreach ($tool in $builtInTools) {
            if (Get-Command $tool.Path -ErrorAction SilentlyContinue) {
                $forensicTools += [PSCustomObject]$tool
                Write-Verbose "Found built-in tool: $($tool.Name)"
            }
        }

        $script:CachedForensicTools = $forensicTools
        Write-Verbose "Initialized $($forensicTools.Count) forensic tools"
        return $forensicTools
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
        Write-Verbose "RawCopy download already attempted"
        return $false
    }

    $script:RawCopyDownloadAttempted = $true
    $rawCopyPath = Join-Path $ToolsPath 'rawcopy.exe'

    try {
        Write-Verbose "Downloading RawCopy from GitHub..."
        $downloadUrl = 'https://github.com/jschicht/RawCopy/releases/latest/download/RawCopy.exe'
        
        Invoke-WebRequest -Uri $downloadUrl -OutFile $rawCopyPath -TimeoutSec 30 -ErrorAction Stop
        
        if (Test-Path $rawCopyPath) {
            Write-Verbose "Successfully downloaded RawCopy to: $rawCopyPath"
            return $true
        }
        else {
            Write-Warning "RawCopy download completed but file not found"
            return $false
        }
    }
    catch {
        Write-Verbose "Failed to download RawCopy: $($_.Exception.Message)"
        Write-Verbose "You can manually download RawCopy from: https://github.com/jschicht/RawCopy"
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
        Success = $false
        FilesCollected = 0
        Errors = @()
    }

    try {
        Write-Verbose "Processing source path: $SourcePath"

        # Handle registry paths
        if ($SourcePath -match '^HK(EY_)?(LOCAL_MACHINE|CURRENT_USER|CLASSES_ROOT|USERS|CURRENT_CONFIG|LM|CU|CR|U|CC)\\') {
            $registryResult = Copy-RegistryArtifact -RegistryPath $SourcePath -DestinationPath $DestinationPath
            $copyResult.Success = $registryResult.Success
            $copyResult.FilesCollected = if ($registryResult.Success) { 1 } else { 0 }
            if (-not $registryResult.Success) {
                $copyResult.Errors += $registryResult.Error
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
