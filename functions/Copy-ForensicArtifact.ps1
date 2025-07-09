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

    .PARAMETER OutputFileName
    Optional custom filename for the export. If not specified, generates one from the registry path.

    .EXAMPLE
    $result = Copy-RegistryArtifact -RegistryPath "HKLM\Software\Microsoft" -DestinationPath "C:\Collection"

    .EXAMPLE
    $result = Copy-RegistryArtifact -RegistryPath "HKLM\Software\Microsoft\SubKey" -DestinationPath "C:\Collection" -OutputFileName "SubKey.reg"

    .OUTPUTS
    PSCustomObject with Success and Error properties.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)]
        [string]$RegistryPath,

        [Parameter(Mandatory)]
        [string]$DestinationPath,

        [Parameter()]
        [string]$OutputFileName
    )

    $result = [PSCustomObject]@{
        Success = $false
        Error   = $null
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
        if ($OutputFileName) {
            $exportFile = Join-Path $DestinationPath $OutputFileName
        }
        else {
            $sanitizedName = $RegistryPath -replace '[\\/:*?"<>|]', '_'
            $exportFile = Join-Path $DestinationPath "registry_$sanitizedName.reg"
        }

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
            }
            else {
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
        '^HKLM\\'                = 'HKEY_LOCAL_MACHINE\'
        '^HKCU\\'                = 'HKEY_CURRENT_USER\'
        '^HKCR\\'                = 'HKEY_CLASSES_ROOT\'
        '^HKU\\'                 = 'HKEY_USERS\'
        '^HKCC\\'                = 'HKEY_CURRENT_CONFIG\'
        '^HKEY_LOCAL_MACHINE\\'  = 'HKEY_LOCAL_MACHINE\'
        '^HKEY_CURRENT_USER\\'   = 'HKEY_CURRENT_USER\'
        '^HKEY_CLASSES_ROOT\\'   = 'HKEY_CLASSES_ROOT\'
        '^HKEY_USERS\\'          = 'HKEY_USERS\'
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
        Success        = $false
        FilesCollected = 0
        Errors         = @()
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
        Success        = $false
        FilesCollected = 0
        Errors         = @()
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
        }
        else {
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

function Copy-WildcardPattern {
    <#
    .SYNOPSIS
    Handles wildcard file patterns (*) in forensic artifact paths.

    .DESCRIPTION
    Processes paths containing wildcards by expanding them to actual
    file locations and copying the matching files.

    .PARAMETER SourcePath
    Source path containing wildcard patterns.

    .PARAMETER DestinationPath
    Destination directory.

    .PARAMETER ForensicTools
    Available forensic tools.

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
        Success        = $false
        FilesCollected = 0
        Errors         = @()
    }

    try {
        Write-Verbose "Processing wildcard pattern: $SourcePath"

        # Use Get-ChildItem with -Path to resolve wildcards
        $items = Get-ChildItem -Path $SourcePath -Force -ErrorAction SilentlyContinue

        if (-not $items) {
            Write-Verbose "No files found matching pattern: $SourcePath"
            $result.Errors += "No files found matching pattern: $SourcePath"
            return $result
        }

        Write-Verbose "Found $($items.Count) items matching wildcard pattern"

        foreach ($item in $items) {
            try {
                if ($item.PSIsContainer) {
                    # Handle directories - we might want to skip or copy contents
                    Write-Verbose "Skipping directory: $($item.FullName)"
                    continue
                }

                # Create destination file path
                $destFile = Join-Path $DestinationPath $item.Name

                # For forensic artifacts, prefer forensic copy tools for system files
                $isSystemFile = $item.FullName -match '(\\Windows\\|\\System32\\|\\SysWOW64\\|AppCompat\\|\\config\\|\.hve$|\.dat$|\.log$)'

                if ($isSystemFile -and $ForensicTools -and $ForensicTools.Count -gt 0) {
                    # Try forensic copy first for system files
                    if (Copy-LockedFile -SourceFile $item.FullName -DestinationFile $destFile -ForensicTools $ForensicTools) {
                        $result.FilesCollected++
                        $result.Success = $true
                        Write-Verbose "Forensic copied system file: $($item.FullName)"
                    }
                    else {
                        $result.Errors += "Failed to copy system file: $($item.FullName)"
                    }
                }
                else {
                    # Standard copy flow for non-system files
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
            }
            catch {
                $result.Errors += "Error copying '$($item.FullName)': $($_.Exception.Message)"
            }
        }

        return $result
    }
    catch {
        $result.Errors += $_.Exception.Message
        Write-Warning "Error processing wildcard pattern '$SourcePath': $($_.Exception.Message)"
        return $result
    }
}

function Copy-DirectPath {
    <#
    .SYNOPSIS
    Handles direct file/directory copy operations.

    .DESCRIPTION
    Copies a specific file or directory when no patterns are involved.

    .PARAMETER SourcePath
    Direct source path.

    .PARAMETER DestinationPath
    Destination directory.

    .PARAMETER ForensicTools
    Available forensic tools.

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
        Success        = $false
        FilesCollected = 0
        Errors         = @()
    }

    try {
        $item = Get-Item -LiteralPath $SourcePath -Force -ErrorAction Stop

        if ($item.PSIsContainer) {
            # Handle directory copy
            Write-Verbose "Copying directory: $SourcePath"
            $destDir = Join-Path $DestinationPath $item.Name

            if (-not (Test-Path $destDir)) {
                New-Item -Path $destDir -ItemType Directory -Force | Out-Null
            }

            # Copy all files in the directory
            $files = Get-ChildItem -Path $SourcePath -Force -File -ErrorAction SilentlyContinue
            foreach ($file in $files) {
                $destFile = Join-Path $destDir $file.Name

                if (Copy-StandardFile -SourceFile $file.FullName -DestinationFile $destFile) {
                    $result.FilesCollected++
                    $result.Success = $true
                    Write-Verbose "Copied: $($file.FullName)"
                }
                else {
                    if (Copy-LockedFile -SourceFile $file.FullName -DestinationFile $destFile -ForensicTools $ForensicTools) {
                        $result.FilesCollected++
                        $result.Success = $true
                        Write-Verbose "Forensic copied: $($file.FullName)"
                    }
                    else {
                        $result.Errors += "Failed to copy: $($file.FullName)"
                    }
                }
            }
        }
        else {
            # Handle single file copy
            $destFile = Join-Path $DestinationPath $item.Name

            # For forensic artifacts, prefer forensic copy tools for system files
            $isSystemFile = $SourcePath -match '(\\Windows\\|\\System32\\|\\SysWOW64\\|AppCompat\\|\\config\\|\.hve$|\.dat$|\.log$)'
            Write-Verbose "Direct path copy - Source: $SourcePath, IsSystemFile: $isSystemFile, ForensicTools count: $($ForensicTools.Count)"

            if ($isSystemFile -and $ForensicTools -and $ForensicTools.Count -gt 0) {
                # Try forensic copy first for system files
                if (Copy-LockedFile -SourceFile $SourcePath -DestinationFile $destFile -ForensicTools $ForensicTools) {
                    $result.FilesCollected++
                    $result.Success = $true
                    Write-Verbose "Forensic copied system file: $SourcePath"
                }
                else {
                    $result.Errors += "Failed to copy system file: $SourcePath"
                }
            }
            else {
                # Standard copy flow for non-system files
                if (Copy-StandardFile -SourceFile $SourcePath -DestinationFile $destFile) {
                    $result.FilesCollected++
                    $result.Success = $true
                    Write-Verbose "Copied: $SourcePath"
                }
                else {
                    if (Copy-LockedFile -SourceFile $SourcePath -DestinationFile $destFile -ForensicTools $ForensicTools) {
                        $result.FilesCollected++
                        $result.Success = $true
                        Write-Verbose "Forensic copied: $SourcePath"
                    }
                    else {
                        $result.Errors += "Failed to copy: $SourcePath"
                    }
                }
            }
        }

        return $result
    }
    catch {
        $result.Errors += $_.Exception.Message
        Write-Warning "Error copying direct path '$SourcePath': $($_.Exception.Message)"
        return $result
    }
}

function Copy-StandardFile {
    <#
    .SYNOPSIS
    Attempts standard file copy operation.

    .PARAMETER SourceFile
    Source file path.

    .PARAMETER DestinationFile
    Destination file path.

    .OUTPUTS
    Boolean indicating success.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string]$SourceFile,

        [Parameter(Mandatory)]
        [string]$DestinationFile
    )

    try {
        # Ensure destination directory exists
        $destDir = Split-Path $DestinationFile -Parent
        if (-not (Test-Path $destDir)) {
            New-Item -Path $destDir -ItemType Directory -Force | Out-Null
        }

        Copy-Item -LiteralPath $SourceFile -Destination $DestinationFile -Force -ErrorAction Stop
        return $true
    }
    catch {
        Write-Verbose "Standard copy failed for '$SourceFile': $($_.Exception.Message)"
        return $false
    }
}

function Copy-LockedFile {
    <#
    .SYNOPSIS
    Attempts forensic copy of locked files using available tools.

    .PARAMETER SourceFile
    Source file path.

    .PARAMETER DestinationFile
    Destination file path.

    .PARAMETER ForensicTools
    Available forensic tools.

    .OUTPUTS
    Boolean indicating success.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string]$SourceFile,

        [Parameter(Mandatory)]
        [string]$DestinationFile,

        [PSCustomObject[]]$ForensicTools = @()
    )

    # Check if file should be skipped (temporary files, transaction logs)
    $fileName = Split-Path $SourceFile -Leaf
    if ($fileName -match '\.(LOG\d*|TMP|TEMP)$') {
        Write-Verbose "Skipping temporary/transaction log file: $SourceFile"
        return $false
    }

    # Try Invoke-RawCopy first if available
    Write-Verbose "Copy-LockedFile - Available tools: $($ForensicTools | ForEach-Object { $_.Name }) (Count: $($ForensicTools.Count))"
    $rawCopyTool = $ForensicTools | Where-Object { $_.Name -eq 'Invoke-RawCopy' } | Select-Object -First 1
    if ($rawCopyTool) {
        try {
            Write-Verbose "Attempting Invoke-RawCopy for locked file: $SourceFile"
            $result = Invoke-RawCopy -Path $SourceFile -Destination $DestinationFile -Overwrite -ErrorAction Stop
            if ($result) {
                Write-Verbose "Forensic copied system file: $SourceFile"
                return $true
            }
        }
        catch {
            Write-Verbose "Invoke-RawCopy failed for '$SourceFile': $($_.Exception.Message)"
            # For certain types of failures, skip fallback to avoid infinite loops
            if ($_.Exception.Message -match "file length was too large|SetLength") {
                Write-Verbose "Skipping fallback tools due to file size/length issue: $SourceFile"
                return $false
            }
        }
    }

    # Try other forensic tools
    foreach ($tool in $ForensicTools | Where-Object { $_.Name -ne 'Invoke-RawCopy' }) {
        try {
            switch ($tool.Name) {
                'Robocopy' {
                    $sourceDir = Split-Path $SourceFile -Parent
                    $fileName = Split-Path $SourceFile -Leaf
                    $destDir = Split-Path $DestinationFile -Parent

                    # Use explicit no-retry, no-wait parameters to prevent infinite loops
                    $robocopyArgs = @("`"$sourceDir`"", "`"$destDir`"", "`"$fileName`"", '/B', '/NP', '/NJH', '/NJS', '/R:0', '/W:0')
                    Write-Verbose "Robocopy command: robocopy $($robocopyArgs -join ' ')"
                    $process = Start-Process -FilePath $tool.Path -ArgumentList $robocopyArgs -Wait -NoNewWindow -PassThru

                    if ($process.ExitCode -eq 0 -or $process.ExitCode -eq 1) {
                        Write-Verbose "Robocopy succeeded for: $SourceFile"
                        return $true
                    }
                    else {
                        Write-Verbose "Robocopy failed with exit code $($process.ExitCode) for: $SourceFile"
                    }
                }
            }
        }
        catch {
            Write-Verbose "$($tool.Name) failed for '$SourceFile': $($_.Exception.Message)"
        }
    }

    return $false
}
