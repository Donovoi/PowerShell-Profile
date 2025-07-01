function Get-ForensicArtifacts {
    <#
    .SYNOPSIS
    Retrieves and optionally collects Windows forensic artifacts from the ForensicArtifacts repository.
    
    .DESCRIPTION
    This function downloads forensic artifact definitions from the ForensicArtifacts GitHub repository,
    processes them according to the specified parameters, and optionally collects the actual artifacts
    from the local system. Supports privilege elevation and comprehensive error handling.
    
    .PARAMETER CollectionPath
    The path where collected artifacts will be stored. If not specified and collection is enabled,
    a default path in the temp directory will be used.
    
    .PARAMETER CollectArtifacts
    Switch to enable actual collection of artifacts from the file system and registry.
    
    .PARAMETER ArtifactFilter
    Array of strings to filter artifacts by name. Only artifacts containing these strings will be processed.
    
    .PARAMETER ExpandPaths
    Switch to expand environment variables and path patterns in the output.
    
    .PARAMETER ElevateToSystem
    Switch to attempt elevation to SYSTEM privileges before collecting artifacts.
    
    .EXAMPLE
    Get-ForensicArtifacts
    Lists all available forensic artifacts without collecting them.
    
    .EXAMPLE
    Get-ForensicArtifacts -CollectArtifacts -CollectionPath "C:\Investigation" -Verbose
    Collects all forensic artifacts to the specified path with verbose output.
    
    .EXAMPLE
    Get-ForensicArtifacts -ArtifactFilter @("Browser", "Registry") -ExpandPaths
    Lists only browser and registry artifacts with expanded paths.
    
    .EXAMPLE
    Get-ForensicArtifacts -CollectArtifacts -ElevateToSystem -Verbose
    Collects artifacts with SYSTEM privileges for maximum access.
    
    .NOTES
    This function requires internet connectivity to download artifact definitions.
    Administrative privileges are recommended for comprehensive artifact collection.
    SYSTEM privileges provide access to the most protected artifacts.
    
    .LINK
    https://github.com/ForensicArtifacts/artifacts
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject[]])]
    param (
        [Parameter(
            Mandatory = $false,
            HelpMessage = 'Path where collected artifacts will be stored'
        )]
        [ValidateScript({
                if ($_ -and -not [string]::IsNullOrWhiteSpace($_)) {
                    $parentDir = Split-Path $_ -Parent
                    if (-not (Test-Path $parentDir -PathType Container)) {
                        throw "Parent directory of collection path '$parentDir' must exist"
                    }
                }
                $true
            })]
        [string]$CollectionPath,
        
        [Parameter(
            Mandatory = $false,
            HelpMessage = 'Enable collection of artifacts from the file system'
        )]
        [switch]$CollectArtifacts,
        
        [Parameter(
            Mandatory = $false,
            HelpMessage = 'Filter artifacts by name patterns'
        )]
        [ValidateNotNull()]
        [string[]]$ArtifactFilter = @(),
        
        [Parameter(
            Mandatory = $false,
            HelpMessage = 'Expand environment variables in paths'
        )]
        [switch]$ExpandPaths,
        
        [Parameter(
            Mandatory = $false,
            HelpMessage = 'Attempt to elevate to SYSTEM privileges'
        )]
        [switch]$ElevateToSystem
    )

    # Constants for better maintainability
    $ARTIFACTS_SOURCE_URL = 'https://raw.githubusercontent.com/ForensicArtifacts/artifacts/main/artifacts/data/windows.yaml'
    $CLEANUP_DELAY_SECONDS = 30
    $TEMP_SCRIPT_PREFIX = 'ForensicCollection_'
    $COLLECTION_DIR_PREFIX = 'ForensicArtifacts_'
    
    # Validation and initialization
    if ($CollectArtifacts -and -not $CollectionPath) {
        $CollectionPath = Join-Path $env:TEMP "$COLLECTION_DIR_PREFIX$(Get-Date -Format 'yyyyMMdd_HHmmss')"
        Write-Verbose "Auto-generated collection path: $CollectionPath"
    }
    
    # Early validation to fail fast
    if ($ArtifactFilter) {
        foreach ($filter in $ArtifactFilter) {
            if ([string]::IsNullOrWhiteSpace($filter)) {
                Write-Warning 'Empty filter detected and will be ignored'
            }
        }
        $ArtifactFilter = $ArtifactFilter | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    }

    # Check current privilege level and elevate if needed
    $currentUser = [Security.Principal.WindowsIdentity]::GetCurrent()
    $isAdmin = ([Security.Principal.WindowsPrincipal]$currentUser).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    $isSystem = $currentUser.IsSystem
    
    Write-Verbose "Current user: $($currentUser.Name)"
    Write-Verbose "Is Administrator: $isAdmin"
    Write-Verbose "Is SYSTEM: $isSystem"
    
    # If collecting artifacts and not running as SYSTEM, try to elevate
    if ($CollectArtifacts -and $ElevateToSystem -and -not $isSystem) {
        if (-not $isAdmin) {
            Write-Warning 'Administrative privileges required for SYSTEM elevation. Please run as administrator first.'
            return
        }
        
        Write-Information 'Elevating to SYSTEM privileges for forensic collection...' -InformationAction Continue
        
        # Check if Get-SYSTEM function is available
        if (-not (Get-Command Get-SYSTEM -ErrorAction SilentlyContinue)) {
            # Try to import it from the functions directory
            $getSystemPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'functions\Get-SYSTEM.ps1'
            if (Test-Path $getSystemPath) {
                . $getSystemPath
            }
            else {
                Write-Warning 'Get-SYSTEM function not found. Please ensure Get-SYSTEM.ps1 is available.'
                Write-Information 'Continuing with current privileges...' -InformationAction Continue
            }
        }
        
        # If Get-SYSTEM is available and we're not already SYSTEM, elevate
        if ((Get-Command Get-SYSTEM -ErrorAction SilentlyContinue) -and -not $isSystem) {
            try {
                # Build the command to run in the elevated context
                $filterString = if ($ArtifactFilter) { 
                    "@('" + ($ArtifactFilter -join "','") + "')" 
                }
                else { 
                    '@()' 
                }
                
                $scriptBlock = @"
# Import the forensic artifacts function
. '$($MyInvocation.MyCommand.Path)'
Get-ForensicArtifacts -CollectionPath '$CollectionPath' -CollectArtifacts -ArtifactFilter $filterString -Verbose
"@
                
                Write-Verbose 'Executing forensic collection as SYSTEM...'
                $tempScript = Join-Path $env:TEMP "$TEMP_SCRIPT_PREFIX$(Get-Date -Format 'yyyyMMddHHmmss').ps1"
                $scriptBlock | Out-File -FilePath $tempScript -Encoding UTF8
                
                # Launch as SYSTEM
                $systemArgs = "-NoProfile -ExecutionPolicy Bypass -File `"$tempScript`""
                $systemProcess = Get-SYSTEM -PowerShellArgs $systemArgs
                
                if ($systemProcess) {
                    Write-Information "Forensic collection started in SYSTEM context (PID: $($systemProcess.Id))" -InformationAction Continue
                    Write-Information 'Monitor the collection process and check the collection path when complete.' -InformationAction Continue
                    
                    # Clean up temp script after a delay using proper parameter binding
                    $cleanupScript = {
                        param([string]$ScriptPath, [int]$DelaySeconds)
                        Start-Sleep -Seconds $DelaySeconds
                        if (Test-Path $ScriptPath) {
                            Remove-Item $ScriptPath -Force -ErrorAction SilentlyContinue
                        }
                    }
                    $cleanup = Start-Job -ScriptBlock $cleanupScript -ArgumentList $tempScript, $CLEANUP_DELAY_SECONDS
                    $cleanup | Out-Null
                    
                    return $systemProcess
                }
                else {
                    Write-Warning 'Failed to elevate to SYSTEM. Continuing with current privileges.'
                }
            }
            catch {
                Write-Warning "Failed to elevate to SYSTEM: $($_.Exception.Message). Continuing with current privileges."
            }
        }
    }

    # Helper function to expand environment variables and Windows path patterns
    function Expand-ForensicPath {
        param([string]$Path)
        
        if ([string]::IsNullOrEmpty($Path)) {
            return $null 
        }
        
        # Handle Windows environment variables
        $expandedPath = $Path -replace '%%environ_systemroot%%', $env:SystemRoot
        $expandedPath = $expandedPath -replace '%%environ_systemdrive%%', $env:SystemDrive
        $expandedPath = $expandedPath -replace '%%environ_programfiles%%', $env:ProgramFiles
        $expandedPath = $expandedPath -replace '%%environ_programfilesx86%%', ${env:ProgramFiles(x86)}
        $expandedPath = $expandedPath -replace '%%environ_allusersprofile%%', $env:ALLUSERSPROFILE
        $expandedPath = $expandedPath -replace '%%environ_temp%%', $env:TEMP
        $expandedPath = $expandedPath -replace '%%environ_windir%%', $env:WINDIR
        $expandedPath = $expandedPath -replace '%%environ_commonprogramfiles%%', $env:CommonProgramFiles
        $expandedPath = $expandedPath -replace '%%environ_commonprogramfilesx86%%', ${env:CommonProgramFiles(x86)}
        
        # Handle user profile paths - these need to be expanded for all users potentially
        $expandedPath = $expandedPath -replace '%%users\.homedir%%', $env:USERPROFILE
        $expandedPath = $expandedPath -replace '%%users\.appdata%%', $env:APPDATA
        $expandedPath = $expandedPath -replace '%%users\.localappdata%%', $env:LOCALAPPDATA
        $expandedPath = $expandedPath -replace '%%users\.temp%%', $env:TEMP
        $expandedPath = $expandedPath -replace '%%users\.desktop%%', ([Environment]::GetFolderPath('Desktop'))
        
        # Handle URL encoding and special characters
        $expandedPath = $expandedPath -replace '%4', ':'  # URL encoding for colon
        $expandedPath = $expandedPath -replace '%20', ' ' # URL encoding for space
        
        # Handle standard Windows environment variables format
        $expandedPath = [Environment]::ExpandEnvironmentVariables($expandedPath)
        
        return $expandedPath
    }
    
    # Helper function to collect artifacts from specified paths
    function Copy-ForensicArtifact {
        param(
            [string]$SourcePath,
            [string]$DestinationRoot,
            [string]$ArtifactName
        )
        
        $success = $false
        try {
            $expandedSource = Expand-ForensicPath -Path $SourcePath
            if ([string]::IsNullOrEmpty($expandedSource)) {
                return $false 
            }
            
            Write-Verbose "Processing path: $expandedSource for artifact: $ArtifactName"
            
            # Create artifact-specific subdirectory
            $artifactDir = Join-Path $DestinationRoot $ArtifactName.Replace(' ', '_')
            if (-not (Test-Path $artifactDir)) {
                New-Item -Path $artifactDir -ItemType Directory -Force | Out-Null
            }
            
            # Handle registry paths
            if ($expandedSource -match '^HK(LM|CU|CR|U|CC)\\') {
                Write-Verbose "Registry path detected: $expandedSource"
                $regFileName = "registry_$(($expandedSource -replace '[\\/:*?"<>|]', '_')).reg"
                $regFile = Join-Path $artifactDir $regFileName
                try {
                    # Export registry key
                    $regPath = $expandedSource -replace '^HKLM\\', 'HKEY_LOCAL_MACHINE\'
                    $regPath = $regPath -replace '^HKCU\\', 'HKEY_CURRENT_USER\'
                    $regPath = $regPath -replace '^HKCR\\', 'HKEY_CLASSES_ROOT\'
                    $regPath = $regPath -replace '^HKU\\', 'HKEY_USERS\'
                    $regPath = $regPath -replace '^HKCC\\', 'HKEY_CURRENT_CONFIG\'
                    
                    $regExportResult = Start-Process -FilePath 'reg' -ArgumentList 'export', "`"$regPath`"", "`"$regFile`"", '/y' -Wait -PassThru -WindowStyle Hidden
                    if ($regExportResult.ExitCode -eq 0 -and (Test-Path $regFile)) {
                        Write-Verbose "Successfully exported registry: $regPath"
                        $success = $true
                    }
                    else {
                        Write-Verbose "Registry export failed or key doesn't exist: $regPath"
                        # Try to check if the key exists using Get-ItemProperty
                        try {
                            $keyExists = Test-Path "Registry::$regPath" -ErrorAction SilentlyContinue
                            if (-not $keyExists) {
                                Write-Verbose "Registry key does not exist: $regPath"
                            }
                        }
                        catch {
                            Write-Verbose "Cannot access registry key: $regPath"
                        }
                    }
                }
                catch {
                    Write-Warning "Failed to export registry path: $expandedSource - $($_.Exception.Message)"
                }
                return $success
            }
            
            # Handle file system paths with better error handling
            try {
                if (Test-Path $expandedSource -PathType Leaf -ErrorAction SilentlyContinue) {
                    # Single file
                    $fileName = Split-Path $expandedSource -Leaf
                    $destFile = Join-Path $artifactDir $fileName
                    Copy-Item -Path $expandedSource -Destination $destFile -Force -ErrorAction Stop
                    Write-Verbose "Copied file: $expandedSource -> $destFile"
                    $success = $true
                }
                elseif (Test-Path $expandedSource -PathType Container -ErrorAction SilentlyContinue) {
                    # Directory
                    $dirName = Split-Path $expandedSource -Leaf
                    $destDir = Join-Path $artifactDir $dirName
                    Copy-Item -Path $expandedSource -Destination $destDir -Recurse -Force -ErrorAction Stop
                    Write-Verbose "Copied directory: $expandedSource -> $destDir"
                    $success = $true
                }
                else {
                    # Path with wildcards or pattern matching
                    $parentPath = Split-Path $expandedSource -Parent
                    $fileName = Split-Path $expandedSource -Leaf
                    
                    if (Test-Path $parentPath -ErrorAction SilentlyContinue) {
                        $items = Get-ChildItem -Path $parentPath -Filter $fileName -Force -ErrorAction SilentlyContinue
                        if (-not $items) {
                            # Try without filter in case it's a complex pattern
                            $items = Get-ChildItem -Path $expandedSource -Force -ErrorAction SilentlyContinue
                        }
                        
                        foreach ($item in $items) {
                            $destItem = Join-Path $artifactDir $item.Name
                            if ($item.PSIsContainer) {
                                Copy-Item -Path $item.FullName -Destination $destItem -Recurse -Force -ErrorAction SilentlyContinue
                            }
                            else {
                                Copy-Item -Path $item.FullName -Destination $destItem -Force -ErrorAction SilentlyContinue
                            }
                            Write-Verbose "Copied: $($item.FullName) -> $destItem"
                            $success = $true
                        }
                        
                        if (-not $success) {
                            Write-Verbose "No files found matching pattern: $expandedSource"
                        }
                    }
                    else {
                        Write-Verbose "Parent path does not exist: $parentPath"
                    }
                }
            }
            catch {
                Write-Verbose "Error accessing path '$expandedSource': $($_.Exception.Message)"
            }
            
            # Clean up empty directories
            if (-not $success) {
                try {
                    $dirContents = Get-ChildItem -Path $artifactDir -ErrorAction SilentlyContinue
                    if (-not $dirContents) {
                        Remove-Item -Path $artifactDir -Force -ErrorAction SilentlyContinue
                        Write-Verbose "Removed empty directory: $artifactDir"
                    }
                }
                catch {
                    Write-Verbose "Could not clean up empty directory: $($_.Exception.Message)"
                }
            }
        }
        catch {
            Write-Warning "Error processing artifact '$ArtifactName' at path '$SourcePath': $($_.Exception.Message)"
        }
        
        return $success
    }

    $WindowsArtifacts = Invoke-RestMethod -Uri $ARTIFACTS_SOURCE_URL
    $obj = ConvertFrom-Yaml -AllDocuments $WindowsArtifacts -Verbose
    
    # Initialize collection if requested
    if ($CollectArtifacts -and [string]::IsNullOrEmpty($CollectionPath)) {
        $CollectionPath = Join-Path $env:TEMP "ForensicArtifacts_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
    }
    
    if ($CollectArtifacts) {
        Write-Verbose "Forensic artifact collection enabled. Destination: $CollectionPath"
        if (-not (Test-Path $CollectionPath)) {
            New-Item -Path $CollectionPath -ItemType Directory -Force | Out-Null
        }
    }
    
    foreach ($Artifact in $obj) {
        # Apply artifact filter if specified
        if ($ArtifactFilter -and $ArtifactFilter.Count -gt 0) {
            $match = $false
            foreach ($filter in $ArtifactFilter) {
                if ($Artifact.name -like "*$filter*") {
                    $match = $true
                    break
                }
            }
            if (-not $match) {
                continue 
            }
        }
        
        $artifactType = $Artifact.sources.type
        $pathKeyValuePairs = $Artifact.sources.attributes.key_value_pairs
        $paths = $Artifact.sources.attributes.paths
        $pathOnly = $null  # Initialize $pathOnly as $null
        $expandedPaths = @()  # Store expanded paths for collection

        if ($artifactType -eq 'REGISTRY_VALUE' -and $null -ne $pathKeyValuePairs -and $pathKeyValuePairs.Count -gt 0) {
            # Iterate through key_value_pairs to find the registry path
            foreach ($pair in $pathKeyValuePairs) {
                if ($pair['registry_path'] -or $pair['path']) {
                    $regPath = $pair['registry_path'] ? $pair['registry_path'] : $pair['path']
                    $pathOnly = $regPath
                    if ($ExpandPaths -or $CollectArtifacts) {
                        $expandedPaths += $regPath
                    }
                    break  # Exit the loop once the registry path is found
                }
            }
        }
        elseif ($null -ne $paths -and $paths.Count -gt 0) {
            # Handle file system paths
            if ($ExpandPaths -or $CollectArtifacts) {
                foreach ($path in $paths) {
                    $expandedPath = Expand-ForensicPath -Path $path
                    if ($expandedPath) {
                        $expandedPaths += $expandedPath
                    }
                }
                if ($ExpandPaths) {
                    $pathOnly = ($expandedPaths -join "`n")
                }
                else {
                    $pathOnly = ($paths -join "`n")
                }
            }
            else {
                $pathOnly = ($paths -join "`n")
            }
        }
        
        # Collect artifacts if requested
        if ($CollectArtifacts -and $expandedPaths.Count -gt 0) {
            Write-Progress -Activity 'Collecting Forensic Artifacts' -Status "Processing: $($Artifact.name)" -PercentComplete -1
            $collectionSuccess = $false
            foreach ($artifactPath in $expandedPaths) {
                $result = Copy-ForensicArtifact -SourcePath $artifactPath -DestinationRoot $CollectionPath -ArtifactName $Artifact.name
                if ($result) {
                    $collectionSuccess = $true 
                }
            }
            
            # If no artifacts were collected for this item, note it in verbose output
            if (-not $collectionSuccess) {
                Write-Verbose "No artifacts collected for: $($Artifact.name) - paths may not exist or be accessible"
            }
        }

        # Create a readable attributes object by directly converting the attributes
        $displayAttributes = $null
        if ($Artifact.sources.attributes) {
            # Use JSON conversion to properly serialize and deserialize the complex objects
            try {
                $attributesJson = $Artifact.sources.attributes | ConvertTo-Json -Depth 10 -Compress
                $tempAttributes = $attributesJson | ConvertFrom-Json
                
                # Force array expansion by creating a new hashtable with properly formatted values
                $attributeProperties = [ordered]@{}
                foreach ($property in $tempAttributes.PSObject.Properties) {
                    $value = $property.Value
                    if ($value -is [array] -and $value.Count -gt 0) {
                        # Convert arrays to comma-separated strings for better display
                        $attributeProperties[$property.Name] = ($value -join ', ')
                    }
                    elseif ($value -is [array] -and $value.Count -eq 0) {
                        $attributeProperties[$property.Name] = @()
                    }
                    else {
                        $attributeProperties[$property.Name] = $value
                    }
                }
                $displayAttributes = [PSCustomObject]$attributeProperties
            }
            catch {
                # Fallback: manual conversion if JSON fails
                $attributeProperties = [ordered]@{}
                foreach ($property in $Artifact.sources.attributes.PSObject.Properties) {
                    $propertyName = $property.Name
                    $propertyValue = $property.Value
                    
                    if ($propertyValue -is [System.Collections.IEnumerable] -and $propertyValue -isnot [string]) {
                        # Convert to array and join for display
                        $expandedArray = @($propertyValue | ForEach-Object { $_ })
                        if ($expandedArray.Count -gt 0) {
                            $attributeProperties[$propertyName] = ($expandedArray -join ', ')
                        }
                        else {
                            $attributeProperties[$propertyName] = @()
                        }
                    }
                    else {
                        $attributeProperties[$propertyName] = $propertyValue
                    }
                }
                $displayAttributes = [PSCustomObject]$attributeProperties
            }
        }

        $Artifacts = [pscustomobject][ordered]@{
            Name          = $Artifact.name
            Description   = $Artifact.doc
            References    = $Artifact.urls
            Attributes    = $displayAttributes
            Path          = $pathOnly
            ExpandedPaths = if ($ExpandPaths -or $CollectArtifacts) {
                $expandedPaths 
            }
            else {
                $null 
            }
            ArtifactType  = $artifactType
        }

        # Return the object instead of custom formatting
        $Artifacts
    }
    
    # Display completion message if artifacts were collected
    if ($CollectArtifacts) {
        Write-Progress -Activity 'Collecting Forensic Artifacts' -Completed
        Write-Information 'Forensic artifact collection completed!' -InformationAction Continue
        Write-Information "Artifacts saved to: $CollectionPath" -InformationAction Continue
        Write-Information "Total artifacts processed: $(($obj | Measure-Object).Count)" -InformationAction Continue
        
        # Get collection statistics
        $collectedDirs = Get-ChildItem -Path $CollectionPath -Directory -ErrorAction SilentlyContinue
        $successfulCollections = @()
        $emptyCollections = @()
        
        foreach ($dir in $collectedDirs) {
            $contents = Get-ChildItem -Path $dir.FullName -Recurse -ErrorAction SilentlyContinue
            if ($contents) {
                $fileCount = ($contents | Where-Object { -not $_.PSIsContainer } | Measure-Object).Count
                $successfulCollections += "$($dir.Name) ($fileCount files)"
            }
            else {
                $emptyCollections += $dir.Name
            }
        }
        
        # Create a summary report
        $summaryFile = Join-Path $CollectionPath 'collection_summary.txt'
        $privilegeInfo = if ($isSystem) {
            'SYSTEM' 
        }
        elseif ($isAdmin) {
            'Administrator' 
        }
        else {
            'Standard User' 
        }
        $summary = @"
Forensic Artifact Collection Summary
====================================
Collection Time: $(Get-Date)
Collection Path: $CollectionPath
Privilege Level: $privilegeInfo
Total Artifacts Processed: $(($obj | Measure-Object).Count)
Filters Applied: $($ArtifactFilter -join ', ')
Successful Collections: $($successfulCollections.Count)
Empty Collections: $($emptyCollections.Count)

Artifacts Successfully Collected:
$(if ($successfulCollections.Count -gt 0) { $successfulCollections | ForEach-Object { "✓ $_" } | Out-String } else { 'None' })

Artifacts with No Files Found:
$(if ($emptyCollections.Count -gt 0) { $emptyCollections | ForEach-Object { "✗ $_" } | Out-String } else { 'None' })

Collection Notes:
- Empty collections may indicate artifacts don't exist on this system
- Some artifacts may require elevated permissions to access
- Registry artifacts are exported as .reg files
- File system artifacts are copied preserving directory structure
- Running as $privilegeInfo provides access to system-level artifacts
"@
        $summary | Out-File -FilePath $summaryFile -Encoding UTF8
        Write-Information "Summary report created: $summaryFile" -InformationAction Continue
        Write-Information "Successfully collected: $($successfulCollections.Count) artifacts" -InformationAction Continue
        Write-Information "Empty collections: $($emptyCollections.Count) artifacts" -InformationAction Continue
        
        # Clean up empty directories if requested
        foreach ($emptyDir in $emptyCollections) {
            $emptyDirPath = Join-Path $CollectionPath $emptyDir
            try {
                Remove-Item -Path $emptyDirPath -Force -ErrorAction SilentlyContinue
                Write-Verbose "Removed empty collection directory: $emptyDir"
            }
            catch {
                Write-Verbose "Could not remove empty directory: $emptyDir"
            }
        }
    }
}