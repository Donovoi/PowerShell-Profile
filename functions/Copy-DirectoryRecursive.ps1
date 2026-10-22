function Copy-DirectoryRecursive {
    <# .SYNOPSIS
    Recursively copies a directory's contents with complete-success boolean semantics.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$SourceDir,[Parameter(Mandatory)][string]$DestinationDir,[pscustomobject[]]$ForensicTools=@())
    if (-not (Get-Command Initialize-CmdletDependencies -ErrorAction SilentlyContinue)) {
        $loader = Join-Path $PSScriptRoot 'Initialize-CmdletDependencies.ps1'
        if (Test-Path -LiteralPath $loader) { . $loader }
        else { . ([scriptblock]::Create((Invoke-RestMethod 'https://raw.githubusercontent.com/Donovoi/PowerShell-Profile/main/functions/Initialize-CmdletDependencies.ps1' -ErrorAction Stop))) }
    }
    Initialize-CmdletDependencies -RequiredCmdlets @('Copy-FileSystemArtifact') -PreferLocal -ErrorAction Stop
    $source = (Get-Item -LiteralPath $SourceDir -Force -ErrorAction Stop).FullName
    $result = Copy-FileSystemArtifact -SourcePath (Join-Path $source '**/*') -DestinationPath $DestinationDir -ForensicTools $ForensicTools
    [bool]$result.Success
}
