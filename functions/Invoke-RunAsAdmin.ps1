function Invoke-RunAsAdmin {
    <#
    .SYNOPSIS
    Compatibility wrapper for Start-AsAdmin; never terminates the caller.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([Diagnostics.Process])]
    param(
        [Alias('ScriptPath')] [string]$FilePath,
        [AllowEmptyString()] [string[]]$ArgumentList = @(),
        [switch]$WindowsPowerShell,
        [switch]$PassThru
    )
    if (-not (Get-Command Start-AsAdmin -ErrorAction Ignore)) {
        . (Join-Path $PSScriptRoot 'Start-AsAdmin.ps1')
    }
    $target = if ($FilePath) { $FilePath } else { 'PowerShell' }
    if ($PSCmdlet.ShouldProcess($target, 'Start elevated PowerShell')) {
        $parameters = @{} + $PSBoundParameters
        $parameters['Confirm'] = $false
        Start-AsAdmin @parameters
    }
}
