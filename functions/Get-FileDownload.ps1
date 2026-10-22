function Get-FileDownload {
    <#
    .SYNOPSIS
    Downloads each URL and emits one verified path per successful download.
    .DESCRIPTION
    Automatic aria2 installation occurs only on invocation with -UseAria2.
    Each URL has independent transport/fallback state. Existing files require
    -Force. Use -FileName for an asset API URL; it requires a single URL.
    Google Drive requires a direct download URL and an authenticated WebSession;
    interactive confirmation pages are not a supported download protocol.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([string])]
    param(
        [Parameter(Mandatory,ValueFromPipeline,Position=0)][string[]]$URL,
        [Parameter(Mandatory,Position=1)][Alias('OutputDir')][string]$DestinationDirectory,
        [switch]$UseAria2,
        [string]$aria2cExe,
        [string]$Token,
        [Collections.IDictionary]$Headers,
        [switch]$IsPrivateRepo,
        [switch]$GitHub,
        [switch]$NoRPCMode,
        [ValidateSet('debug','info','notice','warn','error')][string]$AriaConsoleLogLevel = 'error',
        [switch]$LogToFile,
        [string]$LoadCookiesFromFile,
        [switch]$ForceNativeDownload,
        [Microsoft.PowerShell.Commands.WebRequestSession]$WebSession,
        [string]$FileName,
        [switch]$Force,
        [switch]$AllowEmpty,
        [ValidateRange(1,86400)][int]$TimeoutSeconds = 600,
        [ValidateRange(-1,[long]::MaxValue)][long]$ExpectedLength = -1,
        [ValidatePattern('^[a-fA-F0-9]{64}$')][string]$ExpectedSHA256
    )
    begin {
    if (-not (Get-Command Initialize-CmdletDependencies -ErrorAction SilentlyContinue)) {
        $loader = Join-Path $PSScriptRoot 'Initialize-CmdletDependencies.ps1'
        if (Test-Path -LiteralPath $loader) { . $loader }
        else { . ([scriptblock]::Create((Invoke-RestMethod 'https://raw.githubusercontent.com/Donovoi/PowerShell-Profile/main/functions/Initialize-CmdletDependencies.ps1' -ErrorAction Stop))) }
    }
        Initialize-CmdletDependencies -RequiredCmdlets @('Invoke-ValidatedDownload','Get-OutputFilename','Get-LatestGitHubRelease') -PreferLocal -ErrorAction Stop
        $transportReady = $false
        $destination = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($DestinationDirectory)
        $namedCount = 0
    }
    process {
        foreach ($download in $URL) {
            if ($FileName) {
                $namedCount++
                if ($namedCount -gt 1 -or $URL.Count -gt 1) { throw '-FileName requires exactly one URL.' }
                if ($FileName -in '.', '..' -or $FileName.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0 -or $FileName -match '[. ]$|^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])($|\.)') { throw 'FileName must be a safe leaf name.' }
                $output = [IO.Path]::Combine($destination, $FileName)
            } else {
                $nameHeaders = @{}
                if ($Headers) { foreach ($key in $Headers.Keys) { $nameHeaders[$key] = $Headers[$key] } }
                if ($Token -and ([uri]$download).Host -in 'github.com','api.github.com') { $nameHeaders.Authorization = "Bearer $Token" }
                $output = Get-OutputFilename -Url $download -DestDir $destination -HeadersToUse $nameHeaders
            }
            if (-not $PSCmdlet.ShouldProcess($output, 'Download and verify file')) { continue }
            if ($UseAria2 -and -not $ForceNativeDownload -and -not $transportReady) {
                if (-not $aria2cExe) { $aria2cExe = (Get-Command aria2c.exe -CommandType Application -ErrorAction SilentlyContinue).Source }
                if (-not $aria2cExe) {
                    $tools = Join-Path $destination '.profile-tools'
                    $null = Get-LatestGitHubRelease -OwnerRepository 'aria2/aria2' -AssetName '-win-64bit-' -ExtractZip -DownloadPathDirectory $tools -Force
                    $aria2cExe = Get-ChildItem -LiteralPath $tools -Filter aria2c.exe -Recurse -File | Select-Object -First 1 -ExpandProperty FullName
                    if (-not $aria2cExe) { throw 'aria2 installation did not produce aria2c.exe.' }
                }
                $transportReady = $true
            }
            $parameters = @{
                URL = $download; OutFile = $output; Headers = $Headers; Force = $Force
                AllowEmpty = $AllowEmpty; TimeoutSeconds = $TimeoutSeconds; ExpectedLength = $ExpectedLength
                Confirm = $false; AriaConsoleLogLevel = $AriaConsoleLogLevel; LogToFile = $LogToFile
            }
            if ($Token) { $parameters.Token = $Token }
            if ($ExpectedSHA256) { $parameters.ExpectedSHA256 = $ExpectedSHA256 }
            if ($WebSession) { $parameters.WebSession = $WebSession }
            if ($LoadCookiesFromFile) { $parameters.LoadCookiesFromFile = $LoadCookiesFromFile }
            if ($UseAria2 -and -not $ForceNativeDownload) {
                $parameters.Transport = if ($NoRPCMode) { 'Aria2' } else { 'RPC' }
                $parameters.Aria2cExePath = $aria2cExe
                try { Invoke-ValidatedDownload @parameters -ErrorAction Stop }
                catch {
                    if ($LoadCookiesFromFile) { throw } # Native cannot silently discard cookie-file authentication.
                    Write-Warning 'aria2 failed; retrying this URL with the native downloader.'
                    $parameters.Transport = 'Native'
                    Invoke-ValidatedDownload @parameters -ErrorAction Stop
                }
            } else { Invoke-ValidatedDownload @parameters -ErrorAction Stop }
        }
    }
}
