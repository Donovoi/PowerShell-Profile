function Invoke-AriaDownload {
    <#
    .SYNOPSIS
    Downloads through aria2 and returns only verified file paths.
    .DESCRIPTION
    URLFile accepts one HTTP(S) URL per nonblank line. aria2 per-item option lines
    are rejected so they cannot bypass destination/overwrite safeguards.
    Headers, cookies and timeout apply equally in direct and RPC modes.
    #>
    [CmdletBinding(DefaultParameterSetName='URL',SupportsShouldProcess)]
    [OutputType([string])]
    param(
        [Parameter(Mandatory,ParameterSetName='URL')][string]$URL,
        [Parameter(Mandatory,ParameterSetName='URL')][string]$OutFile,
        [Parameter(Mandatory,ParameterSetName='URLFile')][string]$URLFile,
        [Parameter(Mandatory,ParameterSetName='URLFile')][string]$DownloadDirectory,
        [Parameter(Mandatory)][string]$Aria2cExePath,
        [string]$Token,
        [Collections.IDictionary]$Headers,
        [ValidateSet('debug','info','notice','warn','error')][string]$AriaConsoleLogLevel = 'error',
        [switch]$LogToFile,
        [switch]$RPCMode,
        [string]$LoadCookiesFromFile,
        [Microsoft.PowerShell.Commands.WebRequestSession]$WebSession,
        [string]$UserAgent = 'PowerShell-Profile',
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
    Initialize-CmdletDependencies -RequiredCmdlets @('Invoke-ValidatedDownload','Get-OutputFilename') -PreferLocal -ErrorAction Stop
    $parameters = @{} + $PSBoundParameters
    foreach ($key in 'URL','OutFile','URLFile','DownloadDirectory','RPCMode') { $parameters.Remove($key) }
    $parameters.Transport = if ($RPCMode) { 'RPC' } else { 'Aria2' }
    if ($PSCmdlet.ParameterSetName -eq 'URLFile') {
        $urls = @(Get-Content -LiteralPath $URLFile -ErrorAction Stop | Where-Object { $_.Trim() -and -not $_.StartsWith('#') })
        foreach ($entry in $urls) {
            if ($entry -notmatch '^https?://\S+$') { throw 'URLFile requires one HTTP(S) URL per line, without aria2 option lines.' }
        }
        foreach ($entry in $urls) {
            $output = Get-OutputFilename -Url $entry -DestDir $DownloadDirectory -HeadersToUse $Headers
            if (-not $PSCmdlet.ShouldProcess($output, 'Download and verify with aria2')) { continue }
            $parameters.Confirm = $false; $parameters.WhatIf = $false
            Invoke-ValidatedDownload @parameters -URL $entry -OutFile $output
        }
    } elseif ($PSCmdlet.ShouldProcess($OutFile, 'Download and verify with aria2')) {
        $parameters.Confirm = $false; $parameters.WhatIf = $false
        Invoke-ValidatedDownload @parameters -URL $URL -OutFile $OutFile
    }
}
