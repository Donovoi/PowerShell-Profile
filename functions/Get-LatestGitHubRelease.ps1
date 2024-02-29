<#
.SYNOPSIS
    Retrieves the latest release from a GitHub repository and optionally downloads an asset.

.DESCRIPTION
    The Get-LatestGitHubRelease function retrieves the latest release from a specified GitHub repository. It can also download a specific asset from the release if specified.

.PARAMETER OwnerRepository
    Specifies the owner and repository name in the format "owner/repository". This parameter is mandatory.

.PARAMETER AssetName
    Specifies the name of the asset to download. This parameter is mandatory when the 'Download' parameter set is used.

.PARAMETER DownloadPathDirectory
    Specifies the directory where the asset will be downloaded. If not specified, the current working directory is used.

.PARAMETER ExtractZip
    Indicates whether to extract the downloaded asset if it is a zip file. By default, extraction is not performed.

.PARAMETER UseAria2
    Indicates whether to use the aria2 download utility for faster downloads. By default, aria2 is not used.

.PARAMETER Aria2cExePath
    Specifies the path to the aria2c.exe executable. This parameter is only used when 'UseAria2' is set to true.

.PARAMETER PreRelease
    Indicates whether to include pre-release versions in the search for the latest release. By default, pre-release versions are excluded.

.PARAMETER VersionOnly
    Indicates whether to return only the version number of the latest release. If specified, no asset is downloaded.

.PARAMETER Token
    Specifies a personal access token to access a private repository. This parameter is only used when 'PrivateRepo' is set to true.

.PARAMETER PrivateRepo
    Indicates whether the repository is private. If set to true, a personal access token must be provided.

.OUTPUTS
    Returns the version number of the latest release if the 'VersionOnly' parameter is used. Otherwise, returns the path to the downloaded asset or the extracted files.

.EXAMPLE
    Get-LatestGitHubRelease -OwnerRepository 'Microsoft/PowerShell' -AssetName 'PowerShell-7.2.0-win-x64.msi' -DownloadPathDirectory 'C:\Downloads'

    Retrieves the latest release from the 'Microsoft/PowerShell' repository and downloads the 'PowerShell-7.2.0-win-x64.msi' asset to the 'C:\Downloads' directory.

.EXAMPLE
    Get-LatestGitHubRelease -OwnerRepository 'Microsoft/PowerShell' -VersionOnly

    Retrieves the latest release from the 'Microsoft/PowerShell' repository and returns only the version number of the release.

#>


function Get-LatestGitHubRelease {
    [CmdletBinding(DefaultParameterSetName = 'Download')]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [string] $OwnerRepository,

        [Parameter(Mandatory = $true, ParameterSetName = 'Download')]
        [string] $AssetName,

        # I've hardcoded aria2 to download to a temp directory with a random name to avoid file lock issues
        [Parameter(Mandatory = $false, ParameterSetName = 'Download')]
        [string] $DownloadPathDirectory = $PWD,

        [Parameter(Mandatory = $false, ParameterSetName = 'Download')]
        [switch] $ExtractZip,

        [Parameter(Mandatory = $false, ParameterSetName = 'Download')]
        [switch] $UseAria2,

        [Parameter(Mandatory = $false, ParameterSetName = 'Download')]
        [string]
        $Aria2cExePath,

        [Parameter(Mandatory = $false)]
        [switch] $PreRelease,

        [Parameter(Mandatory = $false, ParameterSetName = 'VersionOnly')]
        [switch] $VersionOnly,

        [Parameter(Mandatory = $false)]
        [string] $Token,

        [Parameter(Mandatory = $false)]
        [switch] $PrivateRepo
    )
    process {

        if (-not (Get-Command -Name 'Install-Cmdlet' -ErrorAction SilentlyContinue)) {
            $method = Invoke-RestMethod -Uri 'https://raw.githubusercontent.com/Donovoi/PowerShell-Profile/main/functions/Install-Cmdlet.ps1'
            $finalstring = [scriptblock]::Create($method.ToString() + "`nExport-ModuleMember -Function * -Alias *")
            New-Module -Name 'InstallCmdlet' -ScriptBlock $finalstring | Import-Module
        }
        $cmdlets = @('Install-Dependencies', 'Get-FileDownload', 'Invoke-AriaDownload', 'Get-LongName', 'Write-Logg', 'Get-Properties', 'Extract-ZIpFile')
        Write-Verbose -Message "Importing cmdlets: $cmdlets"
        $Cmdletstoinvoke = Install-Cmdlet -donovoicmdlets $cmdlets
        $Cmdletstoinvoke | Import-Module -Force

        # fix any certificate issues
        if ($PSVersionTable.PSVersion.Major -eq 5) {
            [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
        }

        # if it is a private repo we will use the token to access the release and download the asset
        if ($PrivateRepo) {
            # We will first make sure we can access the repo with the token
            $headers = @{
                'Authorization' = "token $token"
                'User-Agent'    = 'PowerShell'
            }

            $apiUrl = "https://api.github.com/repos/$Repository/releases"
            $httpClient = New-Object System.Net.Http.HttpClient
            $httpClient.DefaultRequestHeaders.Clear()

            foreach ($key in $headers.Keys) {
                $httpClient.DefaultRequestHeaders.Add($key, $headers[$key])
            }


            $response = $httpClient.GetAsync($apiUrl).Result
            if (-not $response.IsSuccessStatusCode) {
                Write-Error "Failed to get releases from GitHub API with status code $($response.StatusCode)."
                return
            }

            $releases = ConvertFrom-Json $response.Content.ReadAsStringAsync().Result
            $Latestrelease = $null
            if (-not $PreRelease) {
                $LatestRelease = $releases | Where-Object { $_.prerelease -eq $false } | Select-Object -First 1
            }
            else {
                $LatestRelease = $releases | Where-Object { $_.prerelease -eq $true } | Select-Object -First 1
            }

            if ($null -eq $LatestRelease) {
                Write-Error 'No release found.'
                return
            }

            $asset = $LatestRelease.assets | Where-Object -FilterScript { $_ -like "*$AssetName*" } | Select-Object -First 1
            if ($null -eq $asset) {
                Write-Error 'No assets found in the release.'
                return
            }
            $Release = $asset.Browser_Download_url
        }
        else {

            # Prepare API headers without Authorization
            $headers = @{
                'Accept'               = 'application/vnd.github+json'
                'X-GitHub-Api-Version' = '2022-11-28'
            }
        }


        try {
            if (-not $PrivateRepo) {
                # Define API URL
                $apiurl = "https://api.github.com/repos/$OwnerRepository/releases"

                # Retrieve release information
                $Release = $null
                if ($PreRelease) {
                    $releases = Invoke-RestMethod -Uri $apiurl -Headers $headers
                    $Release = $releases | Sort-Object -Property created_at | Select-Object -Last 1
                }
                else {
                    $Releaseinfo = Invoke-WebRequest -Uri ($apiurl + '/latest') -Headers $headers
                    $Releaseparsedjson = ConvertFrom-Json -InputObject $Releaseinfo.Content
                    $Release = $Releaseparsedjson.assets.Browser_Download_url | Where-Object -FilterScript { $_ -like "*$AssetName*" }
                }

                # Handle 'Not Found' response
                if ($Release -like '*Not Found*') {
                    Write-Logg -Message "Looks like the repo doesn't have a latest tag, let's try another way" -Level Warning
                    $ManualRelease = Invoke-RestMethod -Uri $apiurl -Headers $headers | Sort-Object -Property created_at | Select-Object -Last 1
                    $manualDownloadurl = $ManualRelease.assets.Browser_Download_url | Select-Object -First 1
                    if ([string]::IsNullOrEmpty($manualDownloadurl)) {
                        Write-Logg -Message "Looks like the repo doesn't have the release titled $($AssetName), try changing the asset name" -Level error
                        Write-Logg -Message 'exiting script..' -Level warning
                        exit
                    }
                }

                # Handle 'VersionOnly' parameter
                if ($PSBoundParameters.ContainsKey('VersionOnly')) {
                    $Version = $Release.name.Split(' ')[0]
                    return $Version
                }
                # Prepare for download
                if (-not (Test-Path $DownloadPathDirectory)) {
                    New-Item -Path $DownloadPathDirectory -ItemType Directory -Force
                }
            }

            if ($Release -or $manualDownloadurl) {
                if ((-not(Test-Path -Path $Aria2cExePath -ErrorAction SilentlyContinue)) -and $UseAria2) {
                    $aria2directory = Get-LatestGitHubRelease -OwnerRepository 'aria2/aria2' -AssetName '-win-64bit-' -ExtractZip
                    $Aria2cExePath = $(Get-ChildItem -Recurse -Path $aria2directory -Filter 'aria2c.exe').FullName
                }

                # Download asset but make sure the variable is empty each time
                $DownloadedFile = ''

                # take the 3 variables as a array and download all of them that are not empty
                $downloadFileParams = @{}
                if ($PrivateRepo) {
                    $downloadFileParams['Token'] = $Token
                    $downloadFileParams['IsPrivateRepo'] = $true
                }
                if ($Release) {
                    $downloadFileParams['URL'] = $Release
                    $downloadFileParams['OutFiledirectory'] = Get-LongName -ShortName $DownloadPathDirectory

                    if ($UseAria2) {
                        $downloadFileParams['UseAria2'] = $UseAria2
                        $downloadFileParams['aria2cexe'] = $Aria2cExePath
                    }

                }
                else {
                    $downloadFileParams['URL'] = $manualDownloadurl
                    $downloadFileParams['OutFiledirectory'] = Get-LongName -ShortName $DownloadPathDirectory

                    if ($UseAria2) {
                        $downloadFileParams['UseAria2'] = $UseAria2
                        $downloadFileParams['aria2cexe'] = $Aria2cExePath
                    }
                }
                # Splat the parameters onto the function call
                $DownloadedFile = Get-FileDownload @downloadFileParams
            }

            # Handle 'ExtractZip' parameter
            if ($ExtractZip) {
                if ($downloadedFile -notlike '*.zip') {
                    Write-Logg -Message 'The downloaded file is not a zip file, skipping extraction' -Level Warning
                    return $downloadedFile
                }
                if ($DownloadedFile -like '*aria*') {
                    # to make sure there are no locks on the file, we will expand it to a temp directory with a random name
                    $tempDir = Join-Path -Path $ENV:TEMP -ChildPath ([System.IO.Path]::GetRandomFileName())
                    Extract-ZipFile -zipFilePath $downloadedFile -outputFolderPath $tempDir
                    $ExtractedFiles = Join-Path -Path $tempDir -ChildPath ($asset.Name -replace '.zip', '')
                    Write-Logg -Message "Extracted $downloadedFile to $ExtractedFiles"
                    return $ExtractedFiles
                }
                else {
                    Extract-ZipFile -zipFilePath $downloadedFile -outputFolderPath $DownloadPathDirectory
                    $ExtractedFiles = Join-Path -Path $DownloadPathDirectory -ChildPath ($asset.Name -replace '.zip', '')
                    Write-Logg -Message "Extracted $downloadedFile to $ExtractedFiles"
                    return $ExtractedFiles
                }
            }
            else {
                Write-Logg -Message "Downloaded $downloadedFile to $DownloadPathDirectory"
                return $downloadedFile
            }
        }
        catch {
            Write-Logg -Message "An error occurred: $_" -Level Error
            throw
        }

    }
}