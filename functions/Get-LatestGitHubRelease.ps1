function Get-LatestGitHubRelease {
    <#
    .SYNOPSIS
    Resolves a GitHub release and downloads one unambiguous, verified asset.
    .DESCRIPTION
    Private/authenticated assets use the asset API with octet-stream Accept.
    Tokens and headers remain invocation-local. NoDownload returns the tag.
    ExtractZip uses the profile's validated ZIP extractor. Existing files require Force.
    #>
    [CmdletBinding(DefaultParameterSetName='Download',SupportsShouldProcess)]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$')][string]$OwnerRepository,
        [Parameter(ParameterSetName='Download')][string]$AssetName,
        [Parameter(ParameterSetName='Download')][string]$DownloadPathDirectory = $PWD,
        [Parameter(ParameterSetName='Download')][switch]$ExtractZip,
        [Parameter(ParameterSetName='Download')][switch]$UseAria2,
        [Parameter(ParameterSetName='Download')][string]$Aria2cExePath,
        [Parameter(ParameterSetName='NoDownload')][switch]$NoDownload,
        [switch]$PreRelease,
        [string]$Token,
        [switch]$PrivateRepo,
        [switch]$Authenticate,
        [switch]$NoRPCMode,
        [switch]$Force,
        [ValidateRange(1,86400)][int]$TimeoutSeconds = 600
    )
    $ErrorActionPreference = 'Stop'
    if (-not $Token) {
        $cachedToken = Get-Variable GitHubDeviceFlowToken -ValueOnly -ErrorAction SilentlyContinue
        if ($cachedToken) { $Token = $cachedToken }
    }
    if (($PrivateRepo -or $Authenticate) -and -not $Token) { throw 'Supply -Token or sign in before requesting an authenticated release.' }
    $headers = @{ Accept = 'application/vnd.github+json'; 'User-Agent' = 'PowerShell-Profile'; 'X-GitHub-Api-Version' = '2022-11-28' }
    if ($Token) { $headers.Authorization = "Bearer $Token" }
    $baseUri = "https://api.github.com/repos/$OwnerRepository/releases"
    try {
        if ($PreRelease) { $releases = @(Invoke-RestMethod -Uri ($baseUri + '?per_page=100') -Headers $headers -TimeoutSec 30 -ErrorAction Stop) }
        else {
            try { $releases = @(Invoke-RestMethod -Uri ($baseUri + '/latest') -Headers $headers -TimeoutSec 30 -ErrorAction Stop) }
            catch {
                if ([int]$_.Exception.Response.StatusCode -ne 404) { throw }
                $releases = @(Invoke-RestMethod -Uri ($baseUri + '?per_page=100') -Headers $headers -TimeoutSec 30 -ErrorAction Stop)
            }
        }
        $target = $releases | Where-Object { -not $_.draft -and ($PreRelease -or -not $_.prerelease) } |
            Sort-Object { [datetime]$_.published_at } -Descending | Select-Object -First 1
    } catch { throw 'GitHub release lookup failed. Check repository access, authentication and rate limits.' }
    if (-not $target) { throw 'No suitable published release was found.' }
    if ($NoDownload) { return [string]$target.tag_name }
    $assets = @($target.assets)
    if ($AssetName) {
        $selected = @($assets | Where-Object name -EQ $AssetName)
        if (-not $selected.Count) { $selected = @($assets | Where-Object { $_.name.IndexOf($AssetName, [StringComparison]::OrdinalIgnoreCase) -ge 0 }) }
    } else { $selected = $assets }
    if ($selected.Count -ne 1) { throw "Select exactly one release asset with -AssetName; matching assets: $($selected.name -join ', ')." }
    $asset = $selected[0]
    if ($ExtractZip -and $asset.name -notmatch '\.zip$') { throw '-ExtractZip requires a ZIP asset.' }
    if (-not $PSCmdlet.ShouldProcess("$OwnerRepository/$($asset.name)", 'Download and verify release asset')) { return }
    if (-not (Get-Command Initialize-CmdletDependencies -ErrorAction SilentlyContinue)) {
        $loader = Join-Path $PSScriptRoot 'Initialize-CmdletDependencies.ps1'
        if (Test-Path -LiteralPath $loader) { . $loader }
        else { . ([scriptblock]::Create((Invoke-RestMethod 'https://raw.githubusercontent.com/Donovoi/PowerShell-Profile/main/functions/Initialize-CmdletDependencies.ps1' -ErrorAction Stop))) }
    }
    Initialize-CmdletDependencies -RequiredCmdlets @('Get-FileDownload','Extract-ZipFile') -PreferLocal -ErrorAction Stop
    $downloadHeaders = @{} + $headers
    $downloadHeaders.Accept = 'application/octet-stream'
    $parameters = @{
        URL = $(if ($Token) { $asset.url } else { $asset.browser_download_url })
        DestinationDirectory = $DownloadPathDirectory; FileName = $asset.name
        Headers = $downloadHeaders; GitHub = $true; IsPrivateRepo = $PrivateRepo
        UseAria2 = $UseAria2; NoRPCMode = $NoRPCMode; Force = $Force
        TimeoutSeconds = $TimeoutSeconds; ExpectedLength = [long]$asset.size; AllowEmpty = ([long]$asset.size -eq 0)
        Confirm = $false
    }
    if ($Token) { $parameters.Token = $Token }
    if ($Aria2cExePath) { $parameters.aria2cExe = $Aria2cExePath }
    if ($asset.digest -match '^sha256:([a-fA-F0-9]{64})$') { $parameters.ExpectedSHA256 = $Matches[1] }
    $downloaded = Get-FileDownload @parameters -ErrorAction Stop
    if ($ExtractZip) {
        Extract-ZipFile -zipFilePath $downloaded -outputFolderPath $DownloadPathDirectory -Force:$Force -Confirm:$false -ErrorAction Stop
        return $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($DownloadPathDirectory)
    }
    $downloaded
}
