function Get-PaginatedResults {
    [CmdletBinding()]
    param(
        [string]$Uri,
        [hashtable]$Headers
    )
    do {
        $Response = Invoke-WebRequest -Uri $Uri -Headers $Headers
        $Uri = $null
        if ($Response.Headers.Link -match '<(.+?)>; rel="next"') {
            $Uri = $matches[1]
        }
        $Response.Content | ConvertFrom-Json
    }
    while ($Uri)
}
