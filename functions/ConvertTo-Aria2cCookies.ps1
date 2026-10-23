function ConvertTo-Aria2cCookies {
    <#
    .SYNOPSIS
    Writes cookies in the Netscape cookie-file format used by aria2.
    .DESCRIPTION
    Domain accepts a host or an absolute HTTP(S) URL. Expiration uses Unix seconds;
    session cookies use zero. HttpOnly is represented by the #HttpOnly_ prefix.
    Protect the resulting file like a credential.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][Net.CookieContainer]$Cookies,
        [Parameter(Mandatory)][string]$CookieFilePath,
        [Parameter(Mandatory)][string]$Domain
    )
    $uri = if ($Domain -match '^https?://') { [uri]$Domain } else { [uri]("https://" + $Domain.TrimStart('.')) }
    if ($uri.Scheme -notin 'http','https') { throw 'Domain must be an HTTP(S) host or URL.' }
    $lines = [Collections.Generic.List[string]]::new()
    $lines.Add('# Netscape HTTP Cookie File')
    foreach ($cookie in $Cookies.GetCookies($uri)) {
        $expires = if ($cookie.Expires -eq [datetime]::MinValue) { 0 } else { ([DateTimeOffset]$cookie.Expires.ToUniversalTime()).ToUnixTimeSeconds() }
        $domainField = if ($cookie.HttpOnly) { '#HttpOnly_' + $cookie.Domain } else { $cookie.Domain }
        $fields = @($domainField, $cookie.Domain.StartsWith('.').ToString().ToUpperInvariant(),
            $cookie.Path, $cookie.Secure.ToString().ToUpperInvariant(), [string]$expires, $cookie.Name, $cookie.Value)
        if (@($fields | Where-Object { $_ -match '[\r\n\t]' }).Count) { throw 'Cookie contains a delimiter that cannot be represented in Netscape format.' }
        $lines.Add($fields -join "`t")
    }
    $path = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($CookieFilePath)
    [IO.File]::WriteAllLines($path, $lines, [Text.UTF8Encoding]::new($false))
    $path
}
