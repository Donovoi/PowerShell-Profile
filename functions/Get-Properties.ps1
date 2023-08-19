function Get-Properties {
    param(
        [Parameter(Mandatory=$true, ValueFromPipeline=$true)]
        [PSObject]
        $Object
    )

    process {
        if ($Object -is [System.Collections.Specialized.OrderedDictionary]) {
            foreach ($key in $Object.Keys) {
                Write-Log -Message ("Name: " + $key)
                Write-Log -Message ("Type: " + $Object[$key].GetType().FullName)
                Write-Log -Message ("Value: " + $Object[$key])

                if ($Object[$key] -is [psobject]) {
                    Get-Properties -Object $Object[$key]
                }
            }
        } else {
            $Object.PSObject.Properties | ForEach-Object {
                Write-Log -Message ("Name: " + $_.Name)
                Write-Log -Message ("Type: " + $_.TypeNameOfValue)
                Write-Log -Message ("Value: " + $_.Value)

                if ($_.Value -is [psobject]) {
                    Get-Properties -Object $_.Value
                }
            }
        }
    }
}