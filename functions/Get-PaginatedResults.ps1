function Get-PaginatedResults {
    [CmdletBinding()]
    param(
        [string]$Uri,
        [hashtable]$Headers
    )
    do {
        $Response = Invoke-WebRequest -Uri $Uri -Headers $Headers
        $Uri = $null
        $Pattern = '<(https?:\/\/(www\.)?[-a-zA-Z0-9@:%._\+~#=]{1,256}\.[a-zA-Z0-9()]{1,6}\b([-a-zA-Z0-9()!@:%_\+.~#?&\/\/=]*))>; rel="next"'
        $regexpatternmatch = [Regex]::Matches($Response.Headers.Link, $Pattern)
        if ($regexpatternmatch) {
            $Uri = $regexpatternmatch.Groups[1].Value
        }
        $Response.Content | ConvertFrom-Json
    }
    while ($Uri)
}