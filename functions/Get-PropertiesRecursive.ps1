function Get-PropertiesRecursive {
    param(
        [Parameter(Position = 0, Mandatory = $true)]
        [PSObject]$Object,

        [Parameter(Position = 1)]
        [string]$Indent = ''
    )

    $Object | Get-Member -MemberType Property -Force | ForEach-Object {
        $propertyName = $_.Name
        $propertyValue = $Object.$propertyName

        Write-Host "$Indent$propertyName`: $propertyValue"

        # If the property value is an object with properties, call this function recursively
        if ($propertyValue -is [PSObject] -and ($propertyValue | Get-Member -MemberType Property -Force)) {
            Get-PropertiesRecursive -Object $propertyValue -Indent ("$Indent`t")
        }
    }
}

$exception = $_
Get-PropertiesRecursive -Object $exception
