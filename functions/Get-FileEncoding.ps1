function Get-FileEncoding {
    <#
    .SYNOPSIS
    Gets a Unicode BOM encoding, or an explicitly supplied fallback encoding.
    .DESCRIPTION
    Returns null for BOMless files unless FallbackEncoding is supplied. A BOMless
    file cannot reliably be distinguished as ASCII, UTF-8 or a legacy code page.
    UTF-7 is deliberately not inferred; use an explicit encoding if needed.
    .EXAMPLE
    Get-FileEncoding -Path .\data.txt -FallbackEncoding ([Text.Encoding]::UTF8)
    #>
    [CmdletBinding()]
    [OutputType([Text.Encoding])]
    param(
        [Parameter(Mandatory, Position = 0)] [Alias('LiteralPath')]
        [ValidateNotNullOrEmpty()] [string]$Path,
        [Text.Encoding]$FallbackEncoding
    )
    if (-not (Get-Command Test-ByteOrderMark -ErrorAction Ignore)) {
        . (Join-Path $PSScriptRoot 'Test-ByteOrderMark.ps1')
    }
    $encoding = Test-ByteOrderMark -Path $Path
    if ($encoding -is [Text.Encoding]) { return $encoding }
    return $FallbackEncoding
}
