function Get-PaginatedResults {
    [CmdletBinding()]
    param(
        [string]$Uri,
        [hashtable]$Headers
    )
    do {
        $Response = Invoke-WebRequest -Uri $Uri -Headers $Headers
        $Uri = $null
        $regexpatternmatch = $Response.Headers.Link -match '^<(.+?)>; rel=.+,'
        if ($regexpatternmatch) {
            $Uri = $regexpatternmatch.Split(',')[0].Split(';')[0].Trim('<','>')
        }
        $Response.Content | ConvertFrom-Json
    }
    while ($Uri)
}