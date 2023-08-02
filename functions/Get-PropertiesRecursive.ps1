function Get-PropertiesRecursive {
    param(
        [Parameter(Position = 0, Mandatory = $true)]
        [PSObject]$Object,

        [Parameter(Position = 1)]
        [string]$Indent = ''
    )

    $Object | Get-Member -Force | ForEach-Object {
        $propertyName = $_.Name
        $propertyValue = $Object.$propertyName

        Write-Host "$Indent$propertyName`: $propertyValue"

        # If the property value is an object with members, call this function recursively
        if ($propertyValue -is [PSObject] -and ($propertyValue | Get-Member -Force)) {
            Get-PropertiesRecursive -Object $propertyValue -Indent ("$Indent`t")
        }
    }
}