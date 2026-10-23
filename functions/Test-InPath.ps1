function Test-InPath {
    <#
    .SYNOPSIS
    Tests native executable resolution, including Windows PATHEXT.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory, Position = 0)] [ValidateNotNullOrEmpty()] [string]$ExeName)
    # CommandType avoids a function or alias being mistaken for an executable.
    return [bool](Get-Command -Name $ExeName -CommandType Application -ErrorAction Ignore | Select-Object -First 1)
}
