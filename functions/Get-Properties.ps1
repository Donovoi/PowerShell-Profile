<#
.SYNOPSIS
    Retrieves calendar board view data for a specific project board.

.DESCRIPTION
    This cmdlet fetches calendar view information from a project board using Microsoft Graph API.
    It retrieves board items, their associated buckets, and tasks, then organizes them into a 
    calendar board view format.

.PARAMETER Headers
    A hashtable containing the authorization headers required for Microsoft Graph API authentication.
    Typically includes the Bearer token for authentication.

.PARAMETER PlanId
    The unique identifier of the Microsoft Planner plan/board to retrieve calendar data from.

.OUTPUTS
    System.Management.Automation.PSCustomObject
    Returns a custom object containing:
    - boardItems: Array of board items with their details
    - boardBuckets: Array of buckets associated with the board
    - boardTasks: Array of tasks within the board

.EXAMPLE
    $headers = @{ "Authorization" = "Bearer $accessToken" }
    $calendarData = Get-CalendarBoardView -Headers $headers -PlanId "ABC123DEF456"
    
    Retrieves calendar board view data for the plan with ID "ABC123DEF456".

.NOTES
    Requires appropriate Microsoft Graph API permissions to access Planner data.
    Specifically needs Planner.Read or Planner.ReadWrite permissions.

.LINK
    https://docs.microsoft.com/en-us/graph/api/planner-list-tasks
    https://docs.microsoft.com/en-us/graph/api/planner-list-buckets
#>
function Get-Properties {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, ValueFromPipeline = $true)]
        [psobject] $Object,

        [Parameter()]
        [int] $LevelsToEnumerate = 5
    )

    begin {
        # Track visited objects by *reference* to avoid infinite loops
        $refComparer = [System.Collections.Generic.ReferenceEqualityComparer]::Instance
        $visited = [System.Collections.Generic.HashSet[object]]::new($refComparer)

        $results = New-Object System.Collections.Generic.List[object]

        function Add-Row {
            param(
                [string] $Path,
                [object] $Value,
                [int]    $Depth
            )
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
            param(
                [object] $InputObject,
                [string] $Path = '',
                [int]    $Depth = 0
            )

            if ($null -eq $InputObject) {
                return 
            }
            if (-not $visited.Add($InputObject)) {
                return 
            }   # already seen
            if ($Depth -gt $LevelsToEnumerate) {
                return 
            }

            foreach ($p in $InputObject.PSObject.Properties) {
                # Skip hidden/intrinsic if you want: if ($p.IsHidden) { continue }
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
                    # Dictionaries: walk values with key notation
                    if ($val -is [System.Collections.IDictionary]) {
                        foreach ($key in $val.Keys) {
                            Walk -InputObject $val[$key] -Path "$pp[`"$key`"]" -Depth ($Depth + 1)
                        }
                        continue
                    }

                    # Enumerables (but not strings): walk items with index notation
                    if ($val -is [System.Collections.IEnumerable] -and $val -isnot [string]) {
                        $i = 0
                        foreach ($item in $val) {
                            Walk -InputObject $item -Path "$pp[$i]" -Depth ($Depth + 1)
                            $i++
                        }
                        continue
                    }

                    # Non-collection complex object: recurse if it has properties
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
        $results
        # Pipe to grid manually if you want:
        # if (Get-Command Out-GridView -ErrorAction SilentlyContinue) { $results | Out-GridView }
    }
}
