function Test-ByteOrderMark {
    <#
    .SYNOPSIS
    Returns a file's BOM encoding, or false when there is no recognized BOM.
    .DESCRIPTION
    Reads at most four bytes. Checks UTF-32 before its overlapping UTF-16 prefix.
    The absence of a BOM does not establish a file's text encoding.
    #>
    [CmdletBinding()]
    [OutputType([Text.Encoding], [bool])]
    param(
        [Parameter(Mandatory, Position = 0)] [Alias('LiteralPath')]
        [ValidateNotNullOrEmpty()] [string]$Path
    )
    $filePath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    $stream = [IO.File]::Open($filePath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    try {
        $bytes = [byte[]]::new(4)
        $count = $stream.Read($bytes, 0, 4)
    }
    finally { $stream.Dispose() }
    if ($count -ge 4) {
        if ($bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE -and $bytes[2] -eq 0 -and $bytes[3] -eq 0) {
            return [Text.UTF32Encoding]::new($false, $true)
        }
        if ($bytes[0] -eq 0 -and $bytes[1] -eq 0 -and $bytes[2] -eq 0xFE -and $bytes[3] -eq 0xFF) {
            return [Text.UTF32Encoding]::new($true, $true)
        }
    }
    if ($count -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        return [Text.UTF8Encoding]::new($true)
    }
    if ($count -ge 2) {
        if ($bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) { return [Text.UnicodeEncoding]::new($false, $true) }
        if ($bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF) { return [Text.UnicodeEncoding]::new($true, $true) }
    }
    return $false
}
