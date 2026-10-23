function Find-FilesRust {
    <#
    .SYNOPSIS
    Compatibility entry point for text-content regex searches without compiling Rust.
    .DESCRIPTION
    Returns Select-String MatchInfo objects with path, line number and matching line.
    Reads files as text using PowerShell's encoding detection. For filename searches
    use Find-RustyFile or Find-FilesWithGlobPattern.
    #>
    [CmdletBinding()]
    [OutputType([Microsoft.PowerShell.Commands.MatchInfo])]
    param([Parameter(Mandatory)][string]$SearchTerm,[Parameter(Mandatory)][string]$Directory)
    if (-not (Get-Command Initialize-CmdletDependencies -ErrorAction SilentlyContinue)) {
        $loader = Join-Path $PSScriptRoot 'Initialize-CmdletDependencies.ps1'
        if (Test-Path -LiteralPath $loader) { . $loader }
        else { . ([scriptblock]::Create((Invoke-RestMethod 'https://raw.githubusercontent.com/Donovoi/PowerShell-Profile/main/functions/Initialize-CmdletDependencies.ps1' -ErrorAction Stop))) }
    }
    Initialize-CmdletDependencies -RequiredCmdlets @('Find-FilesWithGlobPattern') -PreferLocal -ErrorAction Stop
    $null = [regex]::new($SearchTerm)
    foreach ($file in Find-FilesWithGlobPattern -Path $Directory -GlobPattern '*') {
        Select-String -LiteralPath $file -Pattern $SearchTerm -ErrorAction Stop
    }
}
