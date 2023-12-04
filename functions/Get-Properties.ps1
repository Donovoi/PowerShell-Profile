function Get-Properties {
    param(
        [Parameter(Mandatory = $true, ValueFromPipeline = $true)]
        [PSObject]
        $Object
    )

    # Initialize a HashSet to keep track of visited objects and prevent infinite recursion
    $visited = New-Object 'System.Collections.Generic.HashSet[System.Object]'

    # Helper function for recursion
    function Get-NestedProperties {
        param(
            [Parameter(Mandatory = $true)]
            [PSObject]
            $NestedObject,
            [int]
            $Depth = 0
        )

        # Prefix for indentation
        $prefix = "-" * $Depth

        if ($visited.Add($NestedObject)) {
            if ($NestedObject -is [System.Collections.Specialized.OrderedDictionary]) {
                foreach ($key in $NestedObject.Keys) {
                    Write-Host "${prefix}Name: $key"
                    Write-Host "${prefix}Type: $($NestedObject[$key].GetType().FullName)"
                    Write-Host "${prefix}Value: $($NestedObject[$key])"
                    Get-NestedProperties -NestedObject $NestedObject[$key] -Depth ($Depth + 1)
                }
            }
            elseif ($NestedObject -is [System.Collections.ICollection] -and $NestedObject -is [System.Array]) {
                # Handle arrays
                $NestedObject | ForEach-Object {
                    Get-NestedProperties -NestedObject $_ -Depth ($Depth + 1)
                }
            }
            else {
                $NestedObject.PSObject.Properties | ForEach-Object {
                    Write-Host "${prefix}Name: $($_.Name)"
                    Write-Host "${prefix}Type: $($_.TypeNameOfValue)"
                    Write-Host "${prefix}Value: $($_.Value)"
                    if ($null -ne $_.Value) {
                        Get-NestedProperties -NestedObject $_.Value -Depth ($Depth + 1)
                    }
                }
            }
        }
    }
    Get-NestedProperties -NestedObject $Object

}