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

# Compatibility import surface. Canonical definitions live in command-named files.
foreach ($commandFile in @(
    'Copy-FileSystemArtifact','Copy-RecursivePattern','Copy-WildcardPattern',
    'Copy-DirectPath','Copy-StandardFile','Copy-LockedFile','Copy-DirectoryRecursive'
)) {
    . (Join-Path $PSScriptRoot ($commandFile + '.ps1'))
}
