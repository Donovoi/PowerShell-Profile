function Copy-WildcardPattern {
    <#
    .SYNOPSIS
    Handles wildcard patterns in forensic artifact paths.

    .DESCRIPTION
    Processes paths containing wildcards (* and ?) by expanding them to matching
    files and copying them to the destination.

    .PARAMETER SourcePath
    Source path containing wildcards.

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
        # Parse wildcard pattern
        $basePath = Split-Path $SourcePath -Parent
        $fileName = Split-Path $SourcePath -Leaf

        Write-Verbose "Wildcard pattern - Base: '$basePath', Pattern: '$fileName'"

        if (-not (Test-Path $basePath -PathType Container -ErrorAction SilentlyContinue)) {
            $result.Errors += "Base path does not exist: $basePath"
            return $result
        }

        # Find matching items
        $items = Get-ChildItem -Path $basePath -Force -ErrorAction SilentlyContinue | Where-Object {
            $_.Name -like $fileName
        }

        Write-Verbose "Found $($items.Count) items matching wildcard pattern"

        foreach ($item in $items) {
            try {
                $destFile = Join-Path $DestinationPath $item.Name

                if ($item.PSIsContainer) {
                    # Handle directory - copy recursively
                    if (Copy-DirectoryRecursive -SourceDir $item.FullName -DestinationDir $destFile -ForensicTools $ForensicTools) {
                        $result.FilesCollected++
                        $result.Success = $true
                        Write-Verbose "Copied directory: $($item.FullName)"
                    }
                    else {
                        $result.Errors += "Failed to copy directory: $($item.FullName)"
                    }
                }
                else {
                    # Handle file
                    if (Copy-StandardFile -SourceFile $item.FullName -DestinationFile $destFile) {
                        $result.FilesCollected++
                        $result.Success = $true
                        Write-Verbose "Copied file: $($item.FullName)"
                    }
                    else {
                        # Try forensic copy
                        if (Copy-LockedFile -SourceFile $item.FullName -DestinationFile $destFile -ForensicTools $ForensicTools) {
                            $result.FilesCollected++
                            $result.Success = $true
                            Write-Verbose "Forensic copied file: $($item.FullName)"
                        }
                        else {
                            $result.Errors += "Failed to copy file: $($item.FullName)"
                        }
                    }
                }
            }
            catch {
                $result.Errors += "Error processing '$($item.FullName)': $($_.Exception.Message)"
            }
        }

        return $result
    }
    catch {
        $result.Errors += $_.Exception.Message
        return $result
    }
}

function Copy-DirectPath {
    <#
    .SYNOPSIS
    Copies a direct file or directory path.

    .DESCRIPTION
    Handles direct copying of a specific file or directory to the destination,
    with fallback to forensic tools for locked files.

    .PARAMETER SourcePath
    Direct source path.

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
        $item = Get-Item -LiteralPath $SourcePath -Force -ErrorAction Stop
        $destPath = Join-Path $DestinationPath $item.Name

        if ($item.PSIsContainer) {
            # Copy directory recursively
            if (Copy-DirectoryRecursive -SourceDir $item.FullName -DestinationDir $destPath -ForensicTools $ForensicTools) {
                $result.FilesCollected++
                $result.Success = $true
                Write-Verbose "Copied directory: $($item.FullName)"
            }
            else {
                $result.Errors += "Failed to copy directory: $($item.FullName)"
            }
        }
        else {
            # Copy single file
            if (Copy-StandardFile -SourceFile $item.FullName -DestinationFile $destPath) {
                $result.FilesCollected++
                $result.Success = $true
                Write-Verbose "Copied file: $($item.FullName)"
            }
            else {
                # Try forensic copy
                if (Copy-LockedFile -SourceFile $item.FullName -DestinationFile $destPath -ForensicTools $ForensicTools) {
                    $result.FilesCollected++
                    $result.Success = $true
                    Write-Verbose "Forensic copied file: $($item.FullName)"
                }
                else {
                    $result.Errors += "Failed to copy file: $($item.FullName)"
                }
            }
        }

        return $result
    }
    catch {
        $result.Errors += $_.Exception.Message
        return $result
    }
}

function Copy-StandardFile {
    <#
    .SYNOPSIS
    Attempts standard file copy operation.

    .DESCRIPTION
    Performs a standard PowerShell Copy-Item operation with error handling.
    Returns true if successful, false if the file is locked or inaccessible.

    .PARAMETER SourceFile
    Source file path.

    .PARAMETER DestinationFile
    Destination file path.

    .OUTPUTS
    Boolean indicating copy success.
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
            New-Item -Path $destDir -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null
        }

        # Use -LiteralPath to handle special characters in filenames
        Copy-Item -LiteralPath $SourceFile -Destination $DestinationFile -Force -ErrorAction Stop
        return $true
    }
    catch {
        # Check if this is a locked file scenario
        $isLockedFile = $_.Exception.Message -like '*being used by another process*' -or
                       $_.Exception.Message -like '*Access*denied*' -or
                       $_.Exception.Message -like '*cannot access the file*'

        if ($isLockedFile) {
            Write-Verbose "File appears to be locked: $SourceFile"
        }
        else {
            Write-Verbose "Standard copy failed for '$SourceFile': $($_.Exception.Message)"
        }
        return $false
    }
}

function Copy-LockedFile {
    <#
    .SYNOPSIS
    Attempts to copy locked files using forensic tools.

    .DESCRIPTION
    Tries various forensic tools in order of preference to copy files that
    are locked by the system or other processes.

    .PARAMETER SourceFile
    Source file path.

    .PARAMETER DestinationFile
    Destination file path.

    .PARAMETER ForensicTools
    Array of available forensic tools.

    .OUTPUTS
    Boolean indicating copy success.
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

    if (-not $ForensicTools -or $ForensicTools.Count -eq 0) {
        Write-Verbose "No forensic tools available for locked file copy"
        return $false
    }

    # Ensure destination directory exists
    $destDir = Split-Path $DestinationFile -Parent
    if (-not (Test-Path $destDir)) {
        New-Item -Path $destDir -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null
    }

    # Try tools in order of preference: Function > Executable > BuiltIn
    $sortedTools = $ForensicTools | Sort-Object @{
        Expression = {
            switch ($_.Type) {
                'Function' { 1 }
                'Executable' { 2 }
                'BuiltIn' { 3 }
                default { 99 }
            }
        }
    }

    foreach ($tool in $sortedTools) {
        try {
            Write-Verbose "Attempting forensic copy with $($tool.Name): $SourceFile"

            $success = switch ($tool.Name) {
                'Invoke-RawCopy' {
                    # Use our advanced Invoke-RawCopy function with VSS support
                    try {
                        $invokeRawCopyParams = @{
                            Path = $SourceFile
                            Destination = $DestinationFile
                            Overwrite = $true
                        }
                        # Use call operator to invoke the function
                        & $tool.Path @invokeRawCopyParams
                        Test-Path -LiteralPath $DestinationFile
                    }
                    catch {
                        Write-Verbose "Invoke-RawCopy failed: $($_.Exception.Message)"
                        $false
                    }
                }

                'RawCopy' {
                    # Use RawCopy executable (legacy fallback)
                    try {
                        $rawCopyArgs = @("/FileNamePath:`"$SourceFile`"", "/OutputPath:`"$DestinationFile`"")
                        $process = Start-Process -FilePath $tool.Path -ArgumentList $rawCopyArgs -Wait -PassThru -WindowStyle Hidden -ErrorAction Stop
                        $process.ExitCode -eq 0 -and (Test-Path -LiteralPath $DestinationFile)
                    }
                    catch {
                        Write-Verbose "RawCopy executable failed: $($_.Exception.Message)"
                        $false
                    }
                }

                'Robocopy' {
                    # Use Robocopy for locked files
                    try {
                        $sourceDir = Split-Path $SourceFile -Parent
                        $sourceFileName = Split-Path $SourceFile -Leaf
                        $destDir = Split-Path $DestinationFile -Parent

                        # Escape special characters for Robocopy
                        $robocopyArgs = @("`"$sourceDir`"", "`"$destDir`"", "`"$sourceFileName`"", '/B', '/NP', '/R:0', '/W:0')
                        $process = Start-Process -FilePath $tool.Path -ArgumentList $robocopyArgs -Wait -PassThru -WindowStyle Hidden -ErrorAction Stop
                        ($process.ExitCode -le 7) -and (Test-Path -LiteralPath $DestinationFile)
                    }
                    catch {
                        Write-Verbose "Robocopy failed: $($_.Exception.Message)"
                        $false
                    }
                }

                'XCopy' {
                    # Use XCopy for basic file copying
                    try {
                        $xcopyArgs = @("`"$SourceFile`"", "`"$DestinationFile`"", '/H', '/Y')
                        $process = Start-Process -FilePath $tool.Path -ArgumentList $xcopyArgs -Wait -PassThru -WindowStyle Hidden -ErrorAction Stop
                        $process.ExitCode -eq 0 -and (Test-Path -LiteralPath $DestinationFile)
                    }
                    catch {
                        Write-Verbose "XCopy failed: $($_.Exception.Message)"
                        $false
                    }
                }

                default {
                    Write-Verbose "Unknown tool type: $($tool.Name)"
                    $false
                }
            }

            if ($success) {
                Write-Verbose "Successfully copied locked file with $($tool.Name): $SourceFile"
                return $true
            }
        }
        catch {
            Write-Verbose "Forensic tool $($tool.Name) failed: $($_.Exception.Message)"
            continue
        }
    }

    Write-Verbose "All forensic copy methods failed for: $SourceFile"
    return $false
}

function Copy-DirectoryRecursive {
    <#
    .SYNOPSIS
    Recursively copies a directory with forensic tool support.

    .DESCRIPTION
    Copies an entire directory tree, handling locked files with forensic tools
    where necessary.

    .PARAMETER SourceDir
    Source directory path.

    .PARAMETER DestinationDir
    Destination directory path.

    .PARAMETER ForensicTools
    Available forensic tools.

    .OUTPUTS
    Boolean indicating overall copy success.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string]$SourceDir,

        [Parameter(Mandatory)]
        [string]$DestinationDir,

        [PSCustomObject[]]$ForensicTools = @()
    )

    try {
        # Create destination directory
        if (-not (Test-Path $DestinationDir)) {
            New-Item -Path $DestinationDir -ItemType Directory -Force | Out-Null
        }

        $success = $false
        $allItems = Get-ChildItem -Path $SourceDir -Recurse -Force -ErrorAction SilentlyContinue

        foreach ($item in $allItems) {
            try {
                $relativePath = $item.FullName.Substring($SourceDir.Length).TrimStart('\')
                $destPath = Join-Path $DestinationDir $relativePath

                if ($item.PSIsContainer) {
                    # Create directory
                    if (-not (Test-Path $destPath)) {
                        New-Item -Path $destPath -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null
                    }
                }
                else {
                    # Copy file
                    if (Copy-StandardFile -SourceFile $item.FullName -DestinationFile $destPath) {
                        $success = $true
                    }
                    elseif (Copy-LockedFile -SourceFile $item.FullName -DestinationFile $destPath -ForensicTools $ForensicTools) {
                        $success = $true
                    }
                }
            }
            catch {
                Write-Verbose "Error copying directory item '$($item.FullName)': $($_.Exception.Message)"
            }
        }

        return $success
    }
    catch {
        Write-Warning "Directory copy failed for '$SourceDir': $($_.Exception.Message)"
        return $false
    }
}
