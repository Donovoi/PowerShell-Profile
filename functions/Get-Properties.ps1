<#
.SYNOPSIS
    Inspects an object and outputs a flattened view of its properties.
.DESCRIPTION
    Recursively walks through the properties of the provided object up to the specified depth, capturing type information and values, and optionally displays them in grid-based viewers.
.PARAMETER Object
    The object to inspect; accepts input from the pipeline.
.PARAMETER LevelsToEnumerate
    Maximum depth to traverse when expanding child properties.
.PARAMETER View
    Chooses the output mode: Console grid, traditional grid, or plain objects.
.PARAMETER PassThru
    When a grid view is used, returns the selected rows instead of discarding them.
.PARAMETER Title
    Title to use when displaying results in a grid view.
.EXAMPLE
    Get-Process | Get-Properties -LevelsToEnumerate 3 -View Console
    Displays the first three levels of each process object in the console grid view.
.NOTES
    Uses reference tracking to avoid infinite recursion and supports dictionaries and enumerables.
#>

function Get-Properties {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [psobject] $Object,

        [int] $LevelsToEnumerate = 5,

        # Default to console grid; change to 'Gui' or 'None' if you prefer
        [ValidateSet('Console', 'Gui', 'None')]
        [string] $View = 'Console',

        # When using a grid, return the selected rows (if any)
        [switch] $PassThru,

        # Optional grid title
        [string] $Title = 'Get-Properties'
    )

    begin {
        # Track visited objects by reference to prevent cycles
        $refComparer = [System.Collections.Generic.ReferenceEqualityComparer]::Instance
        $visited = [System.Collections.Generic.HashSet[object]]::new($refComparer)
        $results = [System.Collections.Generic.List[object]]::new()

        function Add-Row {
            param([string]$Path, [object]$Value, [int]$Depth)
            $typeName = if ($null -ne $Value) {
                $Value.GetType().FullName 
            }
            else {
                '[null]' 
            }
            $results.Add([pscustomobject]@{
                    Path  = $Path
                    Type  = $typeName
                    Depth = $Depth
                    Value = $Value
                }) | Out-Null
        }

        function Walk {
            param([object]$InputObject, [string]$Path = '', [int]$Depth = 0)

            if ($null -eq $InputObject) {
                return 
            }
            if (-not $visited.Add($InputObject)) {
                return 
            }
            if ($Depth -gt $LevelsToEnumerate) {
                return 
            }

            foreach ($p in $InputObject.PSObject.Properties) {
                $name = $p.Name
                $val = $p.Value
                $pp = if ($Path) {
                    "$Path.$name" 
                }
                else {
                    $name 
                }

                Add-Row -Path $pp -Value $val -Depth $Depth

                if ($null -ne $val -and $Depth -lt $LevelsToEnumerate) {
                    if ($val -is [System.Collections.IDictionary]) {
                        foreach ($key in $val.Keys) {
                            Walk -InputObject $val[$key] -Path "$pp[`"$key`"]" -Depth ($Depth + 1)
                        }
                        continue
                    }
                    if ($val -is [System.Collections.IEnumerable] -and $val -isnot [string]) {
                        $i = 0
                        foreach ($item in $val) {
                            Walk -InputObject $item -Path "$pp[$i]" -Depth ($Depth + 1)
                            $i++
                        }
                        continue
                    }
                    if ($val.PSObject.Properties.Count -gt 0) {
                        Walk -InputObject $val -Path $pp -Depth ($Depth + 1)
                    }
                }
            }
        }
    }

    process {
        Walk -InputObject $Object -Depth 0
    }

    end {
        switch ($View) {
            'Console' {
                $ocgv = Get-Command Out-ConsoleGridView -ErrorAction SilentlyContinue
                if ($ocgv) {
                    if ($PassThru) {
                        $results | Out-ConsoleGridView -PassThru -Title $Title
                    }
                    else {
                        $null = $results | Out-ConsoleGridView -Title $Title
                    }
                }
                else {
                    Write-Warning 'Out-ConsoleGridView not found. Install it: Install-Module Microsoft.PowerShell.ConsoleGuiTools -Scope CurrentUser'
                    $results
                }
            }
            'Gui' {
                $ogv = Get-Command Out-GridView -ErrorAction SilentlyContinue
                if ($ogv) {
                    if ($PassThru) {
                        $results | Out-GridView -PassThru -Title $Title
                    }
                    else {
                        $null = $results | Out-GridView -Title $Title
                    }
                }
                else {
                    Write-Warning 'Out-GridView is Windows-only and may not be available. Showing plain output instead.'
                    $results
                }
            }
            default {
                $results 
            }
        }
    }
}
