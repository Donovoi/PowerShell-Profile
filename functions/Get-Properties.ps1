function Get-Properties {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, ValueFromPipeline = $true)]
        [PSObject]$Object,

        [Parameter(Mandatory = $false)]
        [Int64]$LevelsToEnumerate = 99
    )

    # Initialize a HashSet to keep track of visited objects and prevent infinite recursion
    $visited = New-Object 'System.Collections.Generic.HashSet[System.Object]'

    function Get-NestedProperties {
        [CmdletBinding()]
        param(
            [Parameter(Mandatory = $true)]
            [PSObject]$NestedObject,

            [Parameter(Mandatory = $false)]
            [Int64]$CurrentDepth = 0,

            [Parameter(Mandatory = $false)]
            [System.Collections.ArrayList]$PropertyList = [System.Collections.ArrayList]::new()
        )

        # Check if the object has already been visited
        if ($visited.Add($NestedObject)) {
            foreach ($property in $NestedObject.PSObject.Properties) {
                $name = $property.Name
                $type = if ($null -ne $property.Value) {
                    $property.Value.GetType().FullName
                }
                else {
                    '[NULL]'
                }
                $value = if ($null -ne $property.Value) {
                    $property.Value
                }
                else {
                    '[NULL VALUE]'
                }

                $propertyObject = [PSCustomObject]@{
                    Name  = $name
                    Type  = $type
                    Value = $value
                    Depth = $CurrentDepth
                }
                $PropertyList.Add($propertyObject) | Out-Null

                if ($null -ne $property.Value -and $property.Value -is [System.Collections.IEnumerable] -and $property.Value -isnot [String] -and $CurrentDepth -lt $LevelsToEnumerate) {
                    if ($property.Value -is [System.Collections.IDictionary]) {
                        foreach ($key in $property.Value.Keys) {
                            Get-NestedProperties -NestedObject $property.Value[$key] -CurrentDepth ($CurrentDepth + 1) -PropertyList $PropertyList
                        }
                    }
                    elseif ($property.Value -is [System.Collections.ICollection]) {
                        foreach ($item in $property.Value) {
                            Get-NestedProperties -NestedObject $item -CurrentDepth ($CurrentDepth + 1) -PropertyList $PropertyList
                        }
                    }
                    else {
                        Get-NestedProperties -NestedObject $property.Value -CurrentDepth ($CurrentDepth + 1) -PropertyList $PropertyList
                    }
                }
            }
        }

        # At the top level, output the results to Out-GridView
        if ($CurrentDepth -eq 0) {
            $PropertyList | Out-GridView
        }
    }

    Get-NestedProperties -NestedObject $Object
}