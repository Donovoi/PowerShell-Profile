function ConvertTo-ForensicArtifact {
    <#
    .SYNOPSIS
    Converts raw artifact data into a standardized forensic artifact object.

    .DESCRIPTION
    Processes artifact definition data and creates a normalized PowerShell object
    with expanded paths and metadata for further processing or collection.

    .PARAMETER ArtifactData
    Raw artifact data from the YAML definitions.

    .PARAMETER ExpandPaths
    Whether to expand environment variables and path patterns.

    .EXAMPLE
    $artifact = ConvertTo-ForensicArtifact -ArtifactData $rawData -ExpandPaths

    .OUTPUTS
    PSCustomObject representing the processed forensic artifact.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)]
        [PSObject]$ArtifactData,

        [switch]$ExpandPaths
    )

    try {
        $artifactType = $ArtifactData.sources.type
        $paths = Get-ArtifactPaths -ArtifactData $ArtifactData

        # Expand paths if requested
        $expandedPaths = @()
        if ($ExpandPaths -and $paths) {
            $expandedPaths = $paths | ForEach-Object {
                Expand-ForensicPath -Path $_
            } | Where-Object { -not [string]::IsNullOrEmpty($_) }
        }

        # Process attributes for display
        $displayAttributes = Get-ProcessedAttributes -Attributes $ArtifactData.sources.attributes

        return [PSCustomObject][Ordered]@{
            Name = $ArtifactData.name
            Description = $ArtifactData.doc
            Type = $artifactType
            References = $ArtifactData.urls
            Attributes = $displayAttributes
            Paths = $paths
            ExpandedPaths = if ($ExpandPaths) { $expandedPaths } else { $null }
            ProcessingDate = Get-Date
        }
    }
    catch {
        Write-Error "Failed to process artifact '$($ArtifactData.name)': $($_.Exception.Message)" -ErrorAction Stop
    }
}

function Get-ArtifactPaths {
    <#
    .SYNOPSIS
    Extracts file system and registry paths from artifact data.

    .DESCRIPTION
    Processes different artifact types (REGISTRY_VALUE, REGISTRY_KEY, FILE) and
    extracts the relevant paths for collection or display.

    .PARAMETER ArtifactData
    The artifact data object containing source information.

    .EXAMPLE
    $paths = Get-ArtifactPaths -ArtifactData $artifact

    .OUTPUTS
    String array of paths found in the artifact definition.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)]
        [PSObject]$ArtifactData
    )

    $paths = @()
    $artifactType = $ArtifactData.sources.type
    $attributes = $ArtifactData.sources.attributes

    switch ($artifactType) {
        'REGISTRY_VALUE' {
            if ($attributes.key_value_pairs) {
                foreach ($pair in $attributes.key_value_pairs) {
                    $regPath = $pair.registry_path ?? $pair.path
                    if ($regPath) {
                        $paths += $regPath
                    }
                }
            }
        }

        'REGISTRY_KEY' {
            if ($attributes.keys) {
                $paths += $attributes.keys
            }
        }

        'FILE' {
            if ($attributes.paths) {
                $paths += $attributes.paths
            }
        }

        default {
            # Handle other types or mixed attributes
            if ($attributes.paths) {
                $paths += $attributes.paths
            }
            if ($attributes.keys) {
                $paths += $attributes.keys
            }
        }
    }

    return $paths | Where-Object { -not [string]::IsNullOrEmpty($_) }
}

function Expand-ForensicPath {
    <#
    .SYNOPSIS
    Expands environment variables and Windows-specific path patterns in forensic paths.

    .DESCRIPTION
    Handles forensic artifact path patterns including Windows environment variables,
    user profile variables, and URL encoding to create usable file system paths.

    .PARAMETER Path
    The path string to expand.

    .EXAMPLE
    $expandedPath = Expand-ForensicPath -Path "%%environ_systemroot%%\System32\config\SAM"

    .OUTPUTS
    String containing the expanded path, or null if path is invalid.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Path
    )

    if ([string]::IsNullOrEmpty($Path)) {
        return $null
    }

    Write-Verbose "Expanding path: '$Path'"

    try {
        # Handle forensic artifact environment variables
        $expandedPath = $Path

        # System environment variables
        $environmentMappings = @{
            '%%environ_systemroot%%' = $env:SystemRoot
            '%%environ_systemdrive%%' = $env:SystemDrive
            '%%environ_programfiles%%' = $env:ProgramFiles
            '%%environ_programfilesx86%%' = ${env:ProgramFiles(x86)}
            '%%environ_allusersprofile%%' = $env:ALLUSERSPROFILE
            '%%environ_temp%%' = $env:TEMP
            '%%environ_windir%%' = $env:WINDIR
            '%%environ_commonprogramfiles%%' = $env:CommonProgramFiles
            '%%environ_commonprogramfilesx86%%' = ${env:CommonProgramFiles(x86)}
        }

        # User-specific variables
        $currentUser = [Security.Principal.WindowsIdentity]::GetCurrent()
        $userMappings = @{
            '%%users.homedir%%' = $env:USERPROFILE
            '%%users.appdata%%' = $env:APPDATA
            '%%users.localappdata%%' = $env:LOCALAPPDATA
            '%%users.temp%%' = $env:TEMP
            '%%users.desktop%%' = [Environment]::GetFolderPath('Desktop')
            '%%users.username%%' = $currentUser.Name.Split('\')[-1]
            '%%users.sid%%' = $currentUser.User.Value
        }

        # Apply all mappings
        foreach ($mapping in ($environmentMappings + $userMappings).GetEnumerator()) {
            if ($expandedPath -match [regex]::Escape($mapping.Key)) {
                $expandedPath = $expandedPath -replace [regex]::Escape($mapping.Key), $mapping.Value
            }
        }

        # Handle URL encoding
        $expandedPath = $expandedPath -replace '%4', ':' -replace '%20', ' '

        # Final environment variable expansion
        $expandedPath = [Environment]::ExpandEnvironmentVariables($expandedPath)

        Write-Verbose "Expanded to: '$expandedPath'"
        return $expandedPath
    }
    catch {
        Write-Warning "Failed to expand path '$Path': $($_.Exception.Message)"
        return $Path
    }
}

function Get-ProcessedAttributes {
    <#
    .SYNOPSIS
    Processes and formats artifact attributes for display.

    .DESCRIPTION
    Converts complex attribute objects into a readable format suitable for display
    and reporting, handling arrays and nested objects appropriately.

    .PARAMETER Attributes
    The attributes object from the artifact definition.

    .EXAMPLE
    $processed = Get-ProcessedAttributes -Attributes $artifact.sources.attributes

    .OUTPUTS
    PSCustomObject with formatted attribute properties.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [PSObject]$Attributes
    )

    if (-not $Attributes) {
        return $null
    }

    try {
        $attributeProperties = [Ordered]@{}

        foreach ($property in $Attributes.PSObject.Properties) {
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

        return [PSCustomObject]$attributeProperties
    }
    catch {
        Write-Warning "Failed to process attributes: $($_.Exception.Message)"
        return $Attributes
    }
}
