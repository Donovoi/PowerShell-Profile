function Get-Properties {
    param(
        [Parameter(Mandatory=$true, ValueFromPipeline=$true)]
        [PSObject]
        $Object
    )

    process {
        if ($Object -is [System.Collections.Specialized.OrderedDictionary]) {
            foreach ($key in $Object.Keys) {
                Write-Host ("Name: " + $key)
                Write-Host ("Type: " + $Object[$key].GetType().FullName)
                Write-Host ("Value: " + $Object[$key])

                if ($Object[$key] -is [psobject]) {
                    Get-Properties -Object $Object[$key]
                }
            }
        } else {
            $Object.PSObject.Properties | ForEach-Object {
                Write-Host ("Name: " + $_.Name)
                Write-Host ("Type: " + $_.TypeNameOfValue)
                Write-Host ("Value: " + $_.Value)

                if ($_.Value -is [psobject]) {
                    Get-Properties -Object $_.Value
                }
            }
        }
    }
}