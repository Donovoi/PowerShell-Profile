function Copy-RegistryArtifact {
    <#
    .SYNOPSIS
    Copies registry artifacts to files for forensic collection.

    .DESCRIPTION
    Exports registry keys and values to .reg files for preservation and analysis.
    Handles different registry hive formats and cleans paths for registry export.

    .PARAMETER RegistryPath
    The registry path to export.

    .PARAMETER DestinationPath
    Directory where the registry export will be saved.

    .EXAMPLE
    $result = Copy-RegistryArtifact -RegistryPath "HKLM\Software\Microsoft" -DestinationPath "C:\Collection"

    .OUTPUTS
    PSCustomObject with Success and Error properties.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)]
        [string]$RegistryPath,
        
        [Parameter(Mandatory)]
        [string]$DestinationPath
    )

    $result = [PSCustomObject]@{
        Success = $false
        Error = $null
    }

    try {
        Write-Verbose "Exporting registry path: $RegistryPath"

        # Normalize registry path for reg.exe
        $normalizedPath = ConvertTo-RegistryExportPath -RegistryPath $RegistryPath
        if (-not $normalizedPath) {
            $result.Error = "Invalid registry path format: $RegistryPath"
            return $result
        }

        # Generate export filename
        $sanitizedName = $RegistryPath -replace '[\\/:*?"<>|]', '_'
        $exportFile = Join-Path $DestinationPath "registry_$sanitizedName.reg"

        # Execute registry export
        $exportArgs = @('export', "`"$normalizedPath`"", "`"$exportFile`"", '/y')
        Write-Verbose "Executing: reg.exe $($exportArgs -join ' ')"
        
        $regProcess = Start-Process -FilePath 'reg.exe' -ArgumentList $exportArgs -Wait -PassThru -WindowStyle Hidden -ErrorAction Stop
        
        if ($regProcess.ExitCode -eq 0 -and (Test-Path $exportFile)) {
            Write-Verbose "Successfully exported registry: $normalizedPath"
            $result.Success = $true
        }
        else {
            # Check if key exists
            $keyExists = Test-Path "Registry::$normalizedPath" -ErrorAction SilentlyContinue
            $errorMsg = if (-not $keyExists) {
                "Registry key does not exist: $normalizedPath"
            } else {
                "Registry export failed (Exit code: $($regProcess.ExitCode))"
            }
            $result.Error = $errorMsg
            Write-Verbose $errorMsg
        }

        return $result
    }
    catch {
        $result.Error = "Registry export error: $($_.Exception.Message)"
        Write-Warning $result.Error
        return $result
    }
}

function ConvertTo-RegistryExportPath {
    <#
    .SYNOPSIS
    Converts forensic registry paths to reg.exe compatible format.

    .DESCRIPTION
    Normalizes registry paths from various formats (short form, long form) into
    the full format required by reg.exe for registry exports.

    .PARAMETER RegistryPath
    The registry path to normalize.

    .EXAMPLE
    $normalized = ConvertTo-RegistryExportPath -RegistryPath "HKLM\Software"

    .OUTPUTS
    String containing the normalized registry path, or null if invalid.
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

    # Registry hive mappings
    $hiveMappings = @{
        '^HKLM\\' = 'HKEY_LOCAL_MACHINE\'
        '^HKCU\\' = 'HKEY_CURRENT_USER\'
        '^HKCR\\' = 'HKEY_CLASSES_ROOT\'
        '^HKU\\' = 'HKEY_USERS\'
        '^HKCC\\' = 'HKEY_CURRENT_CONFIG\'
        '^HKEY_LOCAL_MACHINE\\' = 'HKEY_LOCAL_MACHINE\'
        '^HKEY_CURRENT_USER\\' = 'HKEY_CURRENT_USER\'
        '^HKEY_CLASSES_ROOT\\' = 'HKEY_CLASSES_ROOT\'
        '^HKEY_USERS\\' = 'HKEY_USERS\'
        '^HKEY_CURRENT_CONFIG\\' = 'HKEY_CURRENT_CONFIG\'
    }

    $normalizedPath = $RegistryPath

    # Apply hive mappings
    foreach ($mapping in $hiveMappings.GetEnumerator()) {
        if ($normalizedPath -match $mapping.Key) {
            $normalizedPath = $normalizedPath -replace $mapping.Key, $mapping.Value
            break
        }
    }

    # Remove wildcard patterns that reg.exe doesn't understand
    $normalizedPath = $normalizedPath -replace '\\?\*$', ''

    Write-Verbose "Normalized '$RegistryPath' to '$normalizedPath'"
    return $normalizedPath
}

function Copy-FileSystemArtifact {
    <#
    .SYNOPSIS
    Copies file system artifacts with support for locked files and patterns.

    .DESCRIPTION
    Handles copying of files and directories, including recursive patterns,
    wildcard matching, and locked file handling using forensic tools.

    .PARAMETER SourcePath
    The file system path to copy from.

    .PARAMETER DestinationPath
    The destination directory.

    .PARAMETER ForensicTools
    Array of available forensic tools.

    .EXAMPLE
    $result = Copy-FileSystemArtifact -SourcePath $path -DestinationPath $dest -ForensicTools $tools

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

    $result = [PSCustomObject]@{
        Success = $false
        FilesCollected = 0
        Errors = @()
    }

    try {
        # Handle recursive patterns (**)
        if ($SourcePath.Contains('**')) {
            $recursiveResult = Copy-RecursivePattern -SourcePath $SourcePath -DestinationPath $DestinationPath -ForensicTools $ForensicTools
            return $recursiveResult
        }

        # Handle wildcard patterns
        if ($SourcePath.Contains('*') -or $SourcePath.Contains('?')) {
            $wildcardResult = Copy-WildcardPattern -SourcePath $SourcePath -DestinationPath $DestinationPath -ForensicTools $ForensicTools
            return $wildcardResult
        }

        # Handle direct file/directory copy
        if (Test-Path -LiteralPath $SourcePath -ErrorAction SilentlyContinue) {
            $directResult = Copy-DirectPath -SourcePath $SourcePath -DestinationPath $DestinationPath -ForensicTools $ForensicTools
            return $directResult
        }
        else {
            Write-Verbose "Source path does not exist: $SourcePath"
            $result.Errors += "Source path does not exist: $SourcePath"
        }

        return $result
    }
    catch {
        $result.Errors += $_.Exception.Message
        Write-Warning "Error copying file system artifact '$SourcePath': $($_.Exception.Message)"
        return $result
    }
}

function Copy-RecursivePattern {
    <#
    .SYNOPSIS
    Handles recursive file patterns (**) in forensic artifact paths.

    .DESCRIPTION
    Processes paths containing recursive wildcards by expanding them to actual
    file locations and copying the matching files while preserving directory structure.

    .PARAMETER SourcePath
    Source path containing recursive patterns.

    .PARAMETER DestinationPath
    Destination directory.

    .PARAMETER ForensicTools
    Available forensic tools.

    .OUTPUTS
    PSCustomObject with copy results.
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

    $result = [PSCustomObject]@{
        Success = $false
        FilesCollected = 0
        Errors = @()
    }

    try {
        # Parse recursive pattern
        $basePath = $SourcePath -replace '\\?\*\*.*$', ''
        $pattern = $SourcePath -replace '^.*\\?\*\*\\?', ''

        Write-Verbose "Recursive pattern - Base: '$basePath', Pattern: '$pattern'"

        if (-not (Test-Path $basePath -PathType Container -ErrorAction SilentlyContinue)) {
            $result.Errors += "Base path does not exist: $basePath"
            return $result
        }

        # Find matching files
        $items = if ([string]::IsNullOrEmpty($pattern) -or $pattern -eq '**') {
            Get-ChildItem -Path $basePath -Recurse -Force -File -ErrorAction SilentlyContinue
        } else {
            Get-ChildItem -Path $basePath -Recurse -Force -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -like $pattern }
        }

        Write-Verbose "Found $($items.Count) files matching recursive pattern"

        foreach ($item in $items) {
            try {
                # Preserve directory structure
                $relativePath = $item.FullName.Substring($basePath.Length).TrimStart('\')
                $destFile = Join-Path $DestinationPath $relativePath
                $destDir = Split-Path $destFile -Parent

                # Create destination directory
                if (-not (Test-Path $destDir)) {
                    New-Item -Path $destDir -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null
                }

                # Attempt standard copy first
                if (Copy-StandardFile -SourceFile $item.FullName -DestinationFile $destFile) {
                    $result.FilesCollected++
                    $result.Success = $true
                    Write-Verbose "Copied: $($item.FullName)"
                }
                else {
                    # Try forensic copy for locked files
                    if (Copy-LockedFile -SourceFile $item.FullName -DestinationFile $destFile -ForensicTools $ForensicTools) {
                        $result.FilesCollected++
                        $result.Success = $true
                        Write-Verbose "Forensic copied: $($item.FullName)"
                    }
                    else {
                        $result.Errors += "Failed to copy: $($item.FullName)"
                    }
                }
            }
            catch {
                $result.Errors += "Error copying '$($item.FullName)': $($_.Exception.Message)"
            }
        }

        return $result
    }
    catch {
        $result.Errors += $_.Exception.Message
        return $result
    }
}
