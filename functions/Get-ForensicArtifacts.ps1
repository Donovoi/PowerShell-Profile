function Get-ForensicArtifacts {
    [CmdletBinding()]
    param ()

    $WindowsArtifacts = Invoke-RestMethod -Uri 'https://raw.githubusercontent.com/ForensicArtifacts/artifacts/main/artifacts/data/windows.yaml'
    $obj = ConvertFrom-Yaml -AllDocuments $WindowsArtifacts -Verbose
    foreach ($Artifact in $obj) {
        $artifactType = $Artifact.sources.type
        $pathKeyValuePairs = $Artifact.sources.attributes.key_value_pairs
        $paths = $Artifact.sources.attributes.paths
        $pathOnly = $null  # Initialize $pathOnly as $null

        if ($artifactType -eq 'REGISTRY_VALUE' -and $null -ne $pathKeyValuePairs -and $pathKeyValuePairs.Count -gt 0) {
            # Iterate through key_value_pairs to find the registry path
            foreach ($pair in $pathKeyValuePairs) {
                if ($pair['registry_path'] -or $pair['path']) {
                    $pathOnly = $pair['registry_path'] ? $pair['registry_path'] : $pair['path']
                    break  # Exit the loop once the registry path is found
                }
            }
        }
        elseif ($null -ne $paths -and $paths.Count -gt 0) {
            # Concatenate all paths into a single string, separated by newlines
            $pathOnly = ($paths -join "`n")
        }

        $Artifacts = [pscustomobject][ordered]@{
            Name        = $Artifact.name
            Description = $Artifact.doc
            References  = $Artifact.urls
            Attributes  = $Artifact.sources.attributes
            Path        = $pathOnly  # Use the extracted registry path or paths, separated by newlines if applicable
        }
        $Artifacts | Format-List
    }
}