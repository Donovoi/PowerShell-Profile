function Get-OutputFilename {
    <#
    .SYNOPSIS
    Resolves a safe download name from the URL or Content-Disposition.
    .DESCRIPTION
    Uses a bounded HEAD request only when the URL has no filename extension.
    Header-derived names are reduced to a safe leaf; no response body is downloaded.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$DestDir,
        [Collections.IDictionary]$HeadersToUse,
        [ValidateRange(1, 86400)][int]$TimeoutSeconds = 30
    )
    $uri = [uri]$Url
    if (-not $uri.IsAbsoluteUri -or $uri.Scheme -notin 'http','https') { throw 'Only absolute HTTP(S) URLs are supported.' }
    $fileName = [uri]::UnescapeDataString([IO.Path]::GetFileName($uri.AbsolutePath))
    if (-not [IO.Path]::HasExtension($fileName)) {
        try {
            $response = Invoke-WebRequest -Uri $uri -Method Head -Headers $HeadersToUse -TimeoutSec $TimeoutSeconds -ErrorAction Stop
            $disposition = [string]($response.Headers['Content-Disposition'] -join ';')
            if ($disposition) {
                $parsed = [Net.Http.Headers.ContentDispositionHeaderValue]::Parse($disposition)
                $candidate = $parsed.FileNameStar
                if (-not $candidate) { $candidate = $parsed.FileName }
                if ($candidate) { $fileName = $candidate.Trim('"') }
            }
        }
        catch { Write-Verbose 'No usable download filename was supplied by the server.' }
    }
    $fileName = [IO.Path]::GetFileName($fileName.Replace('/', '\'))
    foreach ($char in [IO.Path]::GetInvalidFileNameChars()) { $fileName = $fileName.Replace([string]$char, '_') }
    $fileName = $fileName.TrimEnd('.', ' ')
    if (-not $fileName -or $fileName -match '^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])($|\.)') { $fileName = 'Download-' + [guid]::NewGuid().ToString('N') }
    [IO.Path]::Combine($ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($DestDir), $fileName)
}
