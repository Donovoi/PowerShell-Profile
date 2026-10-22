function Get-FinalOutputPath {
    <#
    .SYNOPSIS
    Resolves a file destination without creating directories or overwriting files.
    .DESCRIPTION
    Use a trailing separator for a directory that does not yet exist.
    Existing files require -Force; the caller must also enforce this when publishing.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$BasePath,
        [string]$FileName,
        [switch]$Force
    )
    $path = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($BasePath)
    if ($BasePath -match '[/\\]$' -or [IO.Directory]::Exists($path)) {
        if (-not $FileName -or $FileName -in '.', '..' -or
            $FileName.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0 -or
            $FileName -match '[. ]$|^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])($|\.)') { throw 'FileName must be a safe file name, without a path.' }
        $path = [IO.Path]::Combine($path, $FileName)
    }
    if ([IO.Directory]::Exists($path)) { throw "Destination is a directory: $path" }
    if ([IO.File]::Exists($path) -and -not $Force) { throw "File exists; use -Force: $path" }
    $path
}
