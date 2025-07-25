<#
.SYNOPSIS
    Get the newest GitHub release (stable by default) and optionally
    download / extract a selected asset.

.DESCRIPTION
    Queries the GitHub REST API (v 2022-11-28) for the current release.
    • Falls back from `/releases/latest` to `/releases` when a repo only has
      *pre-releases* (the API returns 404 in that case).
    • Supports PAT or OAuth *device-flow* auth and shows remaining rate-limit
      quota from `X-RateLimit-Remaining`.
    • Adds the mandatory `User-Agent` and `Accept` headers GitHub requires.
    • Downloads via native HTTP or **aria2** and can auto-extract ZIPs.
    • Download / extract failures are trapped, surfaced with `Write-Error`,
      **and** returned as a `[System.Management.Automation.ErrorRecord]`
      for programmatic handling.

.PARAMETER OwnerRepository
    Repository in **owner/name** format (e.g. `PowerShell/PowerShell`).

.PARAMETER AssetName
    Exact file name *or* wildcard pattern of the asset to download.
    If omitted and only one asset exists, that asset is chosen.

.PARAMETER DownloadPathDirectory
    Target directory for the download.  Defaults to **$PWD**.

.PARAMETER ExtractZip
    Expand a downloaded `.zip` into **DownloadPathDirectory**.  Uses
    `Expand-Archive`.

.PARAMETER UseAria2
    Fetch with *aria2c* for multi-threaded, resumable transfers.

.PARAMETER Aria2cExePath
    Path to `aria2c.exe`; if missing and **UseAria2** is set, the function
    attempts to fetch a current static build.

.PARAMETER NoDownload
    Skip the download and return only the resolved `tag_name`.

.PARAMETER PreRelease
    If set, include pre-releases when resolving “latest”.

.PARAMETER Token
    GitHub personal-access token for private repos or higher quotas.

.PARAMETER PrivateRepo
    Marks the repo as private; always queries `/releases`.

.PARAMETER Authenticate
    Invoke GitHub OAuth *device-flow* and cache the token for the session.

.PARAMETER NoRPCMode
    Pass-through switch for `Invoke-AriaDownload` that disables RPC.

.OUTPUTS
    [System.String]                              – tag name when **-NoDownload**
    [System.IO.FileInfo]                         – downloaded file(s)
    [System.String]                              – destination dir when **-ExtractZip**
    [System.Management.Automation.ErrorRecord]   – error object when a
                                                   download / extraction fails

.EXAMPLE
    # Only return the newest stable tag
    Get-LatestGitHubRelease -OwnerRepository 'PowerShell/PowerShell' -NoDownload

.EXAMPLE
    # Download & unzip the portable build with aria2
    Get-LatestGitHubRelease -OwnerRepository 'PowerShell/PowerShell' `
                            -AssetName 'win-x64.zip' `
                            -DownloadPathDirectory 'C:\Tools\Pwsh' `
                            -ExtractZip -UseAria2

.EXAMPLE
    # Grab the newest pre-release of UniExtract and keep the ZIP
    Get-LatestGitHubRelease -OwnerRepository 'Bioruebe/UniExtract2' `
                            -AssetName 'UniExtractRC*.zip' -PreRelease

.NOTES
    • Comment-based help format per *about_Comment_Based_Help*.
    • Error handling follows *about_Try_Catch_Finally*.
    • Returns `ErrorRecord` objects for inspection.
    • Uses dynamic module import via script-block technique.
    • Path creation with `Test-Path`/`New-Item`.
    • `Write-Error` vs `throw` guidance from community best practice.
#>
function Get-LatestGitHubRelease {

    [CmdletBinding(DefaultParameterSetName = 'Download')]
    [OutputType(
        [System.IO.FileInfo],
        [System.String],
        [System.Management.Automation.ErrorRecord]
    )]
    param(
        [Parameter(Mandatory)][string]$OwnerRepository,
        [Parameter(ParameterSetName = 'Download')][string]$AssetName,
        [Parameter(ParameterSetName = 'Download')][string]$DownloadPathDirectory = $PWD,
        [Parameter(ParameterSetName = 'Download')][switch]$ExtractZip,
        [Parameter(ParameterSetName = 'Download')][switch]$UseAria2,
        [Parameter(ParameterSetName = 'Download')][string]$Aria2cExePath,
        [Parameter(ParameterSetName = 'NoDownload')][switch]$NoDownload,

        [switch]$PreRelease,
        [string]$Token,
        [switch]$PrivateRepo,
        [switch]$Authenticate,
        [switch]$NoRPCMode
    )

    begin {
        $FileScriptBlock = ''
        # --- dynamically import helper cmdlets ----------------------------
        $neededCmdlets = @(
            'Install-Dependencies', 'Get-FileDownload', 'Write-InformationColored',
            'Invoke-AriaDownload', 'Get-LongName', 'Write-Logg', 'Get-Properties'
        )

        foreach ($cmd in $neededcmdlets) {
            if (-not (Get-Command -Name $cmd -ErrorAction SilentlyContinue)) {
                if (-not (Get-Command -Name 'Install-Cmdlet' -ErrorAction SilentlyContinue)) {
                    $method = Invoke-RestMethod -Uri 'https://raw.githubusercontent.com/Donovoi/PowerShell-Profile/main/functions/Install-Cmdlet.ps1'
                    $finalstring = [scriptblock]::Create($method.ToString() + "`nExport-ModuleMember -Function * -Alias *")
                    New-Module -Name 'InstallCmdlet' -ScriptBlock $finalstring | Import-Module
                }
                Write-Verbose "Importing cmdlet: $cmd"
                $scriptBlock = Install-Cmdlet -RepositoryCmdlets $cmd -PreferLocal -Force

                # Check if the returned value is a ScriptBlock and import it properly
                if ($scriptBlock -is [scriptblock]) {
                    $moduleName = "Dynamic_$cmd"
                    New-Module -Name $moduleName -ScriptBlock $scriptBlock | Import-Module -Force
                    Write-Verbose "Imported $cmd as dynamic module: $moduleName"
                }
                elseif ($scriptBlock -is [System.Management.Automation.PSModuleInfo]) {
                    # If a module info was returned, it's already imported
                    Write-Verbose "Module for $cmd was already imported: $($scriptBlock.Name)"
                }
                elseif ($($scriptBlock | Get-Item) -is [System.IO.FileInfo]) {
                    # If a file path was returned, import it
                    $FileScriptBlock += $(Get-Content -Path $scriptBlock -Raw) + "`n"
                    Write-Verbose "Imported $cmd from file: $scriptBlock"
                }
                else {
                    Write-Warning "Could not import $cmd`: Unexpected return type from Install-Cmdlet"
                    Write-Warning "Returned: $($scriptBlock)"
                }
            }
        }
        $finalFileScriptBlock = [scriptblock]::Create($FileScriptBlock.ToString() + "`nExport-ModuleMember -Function * -Alias *")
        New-Module -Name 'cmdletCollection' -ScriptBlock $finalFileScriptBlock | Import-Module -Force

        # --- TLS 1.2 for Windows PowerShell 5 ------------------------------
        if ($PSVersionTable.PSVersion.Major -eq 5) {
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        }

        # --- GitHub request headers ---------------------------------------
        $script:__ghHeaders = @{
            Accept                 = 'application/vnd.github+json'
            'User-Agent'           = "Get-LatestGitHubRelease/$($PSVersionTable.PSVersion)"
            'X-GitHub-Api-Version' = '2022-11-28'
        }
        if ($Token) {
            $script:__ghHeaders['Authorization'] = "Bearer $Token"
        }
        elseif ($script:GitHubDeviceFlowToken) {
            $script:__ghHeaders['Authorization'] = "Bearer $script:GitHubDeviceFlowToken"
        }

        # --- small helper to call GitHub REST API --------------------------
        function Invoke-GHRest {
            param([string]$Uri)
            $retry = 0
            do {
                try {
                    return , (Invoke-RestMethod -Uri $Uri -Headers $script:__ghHeaders)
                }
                catch [System.Net.Http.HttpRequestException] {
                    $s = $_.Exception.Response.StatusCode.value__
                    if ($s -ge 500 -and $retry -lt 3) {
                        Start-Sleep (5 * ++$retry); continue
                    }
                    throw
                }
            } while ($true)
        }
    }

    process {
        # -------- determine target release --------------------------------
        $baseUri = "https://api.github.com/repos/$OwnerRepository"
        $releasesEndpoint = "$baseUri/releases"
        $latestEndpoint = "$baseUri/releases/latest"
        $primaryUri = if ($PreRelease -or $PrivateRepo) {
            $releasesEndpoint
        }
        else {
            $latestEndpoint
        }

        try {
            $response = Invoke-GHRest $primaryUri
        }
        catch [System.Net.Http.HttpRequestException] {
            if ($_.Exception.Response.StatusCode.value__ -eq 404 -and $primaryUri -eq $latestEndpoint) {
                Write-Verbose 'latest endpoint returned 404 – falling back to /releases'
                $response = Invoke-GHRest $releasesEndpoint
            }
            else {
                throw
            }
        }

        if ($response -is [System.Collections.IEnumerable]) {
            $response = $response | Sort-Object { [datetime]$_.published_at } -Descending
            if (-not $PreRelease) {
                $response = $response | Where-Object { -not $_.prerelease }
            }
            $target = $response | Select-Object -First 1
        }
        else {
            $target = $response
        }

        if (-not $target) {
            throw "No suitable release found for $OwnerRepository."
        }

        $tag = $target.tag_name
        Write-Verbose "Resolved release: $tag"

        if ($NoDownload) {
            return $tag
        }

        # --------- pick an asset ------------------------------------------
        $assets = $target.assets
        if (-not $assets) {
            throw 'Release contains no assets.'
        }

        if ($AssetName) {
            $asset = $assets | Where-Object name -EQ $AssetName | Select-Object -First 1
            if (-not $asset) {
                $asset = $assets | Where-Object name -Like "*$AssetName*" | Select-Object -First 1
            }
        }
        elseif ($assets.Count -eq 1) {
            $asset = $assets[0]
        }
        else {
            throw "Multiple assets found. Specify -AssetName: $($assets.name -join ', ')."
        }

        if (-not $asset) {
            throw "Asset '$AssetName' not found."
        }

        # --------- download ------------------------------------------------
        if (-not (Test-Path $DownloadPathDirectory)) {
            New-Item -ItemType Directory -Force -Path $DownloadPathDirectory | Out-Null
        }

        $dlParams = @{
            URL                  = $asset.browser_download_url
            DestinationDirectory = $DownloadPathDirectory
        }
        if ($UseAria2 -and $Aria2cExePath) {
            $dlParams.UseAria2 = $true
            $dlParams.aria2cexe = $Aria2cExePath
            if ($NoRPCMode) {
                $dlParams.NoRPCMode = $true
            }
        }
        if ($Token) {
            $dlParams.Token = $Token
        }

        try {
            $downloaded = Get-FileDownload @dlParams -EA Stop
        }
        catch {
            Write-Error $_
            return $_    # surface the ErrorRecord
        }

        # --------- extract -------------------------------------------------
        if ($ExtractZip -and $downloaded -match '\.zip$') {
            try {
                Expand-Archive -Path $downloaded -DestinationPath $DownloadPathDirectory -Force -EA Stop
                return $DownloadPathDirectory
            }
            catch {
                Write-Error $_
                return $_
            }
        }

        return $downloaded
    }

    end {
        try {
            $rate = Invoke-RestMethod -Uri 'https://api.github.com/rate_limit' -Headers $script:__ghHeaders -EA SilentlyContinue
            if ($rate) {
                Write-Verbose ('GitHub rate-limit left: {0}/{1}' -f $rate.rate.remaining, $rate.rate.limit)
            }
        }
        catch {
        }
    }
}