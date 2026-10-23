function Find-RustyFile {
    <#
    .SYNOPSIS
    Compatibility entry point for filename regex/glob searches without compiling Rust.
    .DESCRIPTION
    Regex matches file names at any depth with a one-second match timeout.
    Glob uses Find-FilesWithGlobPattern. Returns full paths, including Unicode names.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Pattern,
        [Parameter(Mandatory)][bool]$UseRegex,
        [string]$StartDir = $PWD
    )
    if (-not (Get-Command Initialize-CmdletDependencies -ErrorAction SilentlyContinue)) {
        $loader = Join-Path $PSScriptRoot 'Initialize-CmdletDependencies.ps1'
        if (Test-Path -LiteralPath $loader) { . $loader }
        else { . ([scriptblock]::Create((Invoke-RestMethod 'https://raw.githubusercontent.com/Donovoi/PowerShell-Profile/main/functions/Initialize-CmdletDependencies.ps1' -ErrorAction Stop))) }
    }
    Initialize-CmdletDependencies -RequiredCmdlets @('Find-FilesWithGlobPattern') -PreferLocal -ErrorAction Stop
    if ($UseRegex) {
        $regex = [regex]::new($Pattern, [Text.RegularExpressions.RegexOptions]::IgnoreCase, [TimeSpan]::FromSeconds(1))
        Find-FilesWithGlobPattern -Path $StartDir -GlobPattern '*' | Where-Object { $regex.IsMatch([IO.Path]::GetFileName($_)) }
    } else { Find-FilesWithGlobPattern -Path $StartDir -GlobPattern $Pattern }
}
