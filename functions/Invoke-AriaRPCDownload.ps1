function Invoke-AriaRPCDownload {
    <#
    .SYNOPSIS
    Downloads using an invocation-owned, authenticated loopback aria2 RPC process.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$URL,
        [Parameter(Mandatory)][string]$OutFile,
        [Parameter(Mandatory)][string]$Aria2cExePath,
        [string]$Token,
        [Collections.IDictionary]$Headers,
        [switch]$LogToFile,
        [string]$LoadCookiesFromFile,
        [string]$UserAgent = 'PowerShell-Profile',
        [ValidateSet('debug','info','notice','warn','error')][string]$AriaConsoleLogLevel = 'error',
        [switch]$Force,
        [switch]$AllowEmpty,
        [ValidateRange(1,86400)][int]$TimeoutSeconds = 600,
        [ValidateRange(-1,[long]::MaxValue)][long]$ExpectedLength = -1,
        [ValidatePattern('^[a-fA-F0-9]{64}$')][string]$ExpectedSHA256
    )
    if (-not (Get-Command Initialize-CmdletDependencies -ErrorAction SilentlyContinue)) {
        $loader = Join-Path $PSScriptRoot 'Initialize-CmdletDependencies.ps1'
        if (Test-Path -LiteralPath $loader) { . $loader }
        else { . ([scriptblock]::Create((Invoke-RestMethod 'https://raw.githubusercontent.com/Donovoi/PowerShell-Profile/main/functions/Initialize-CmdletDependencies.ps1' -ErrorAction Stop))) }
    }
    Initialize-CmdletDependencies -RequiredCmdlets @('Invoke-ValidatedDownload') -PreferLocal -ErrorAction Stop
    if ($PSCmdlet.ShouldProcess($OutFile, 'Download and verify using private aria2 RPC')) {
        $parameters = @{} + $PSBoundParameters
        $parameters.Confirm = $false; $parameters.WhatIf = $false
        Invoke-ValidatedDownload @parameters -Transport RPC
    }
}
