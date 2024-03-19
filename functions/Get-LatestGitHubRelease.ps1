<#
.SYNOPSIS
    Retrieves the latest release from a GitHub repository and optionally downloads an asset.

.DESCRIPTION
    The Get-LatestGitHubRelease function retrieves the latest release from a GitHub repository. It can be used to get information about the release, such as the version number, and optionally download a specific asset from the release.

.PARAMETER OwnerRepository
    Specifies the owner and repository name in the format "owner/repository". This parameter is mandatory.

.PARAMETER AssetName
    Specifies the name of the asset to download. This parameter is optional.

.PARAMETER DownloadPathDirectory
    Specifies the directory where the asset should be downloaded. If not specified, the current working directory is used.

.PARAMETER ExtractZip
    Specifies whether to extract the downloaded asset if it is a zip file. This parameter is optional.

.PARAMETER UseAria2
    Specifies whether to use the aria2 download manager to download the asset. This parameter is optional.

.PARAMETER Aria2cExePath
    Specifies the path to the aria2c.exe executable. This parameter is optional and only used if UseAria2 is set to true.

.PARAMETER PreRelease
    Specifies whether to include pre-release versions in the search for the latest release. This parameter is optional.

.PARAMETER NoDownload
    Specifies whether to skip the download and only return the version number of the latest release. This parameter is optional.

.PARAMETER Token
    Specifies the GitHub personal access token to use for accessing private repositories. This parameter is optional.

.PARAMETER PrivateRepo
    Specifies whether the repository is private. If set to true, the function will use the Token parameter to access the release and download the asset. This parameter is optional.

.OUTPUTS
    The function outputs a string representing the version number of the latest release. If the NoDownload parameter is specified, the function only returns the version number and does not download the asset.

.EXAMPLE
    Get-LatestGitHubRelease -OwnerRepository "owner/repository" -AssetName "asset.zip" -DownloadPathDirectory "C:\Downloads" -ExtractZip

    Retrieves the latest release from the specified GitHub repository and downloads the asset with the name "asset.zip" to the "C:\Downloads" directory. If the asset is a zip file, it will be extracted.

.EXAMPLE
    Get-LatestGitHubRelease -OwnerRepository "owner/repository" -NoDownload

    Retrieves the latest release from the specified GitHub repository and returns the version number of the release without downloading any assets.

#>


function Get-LatestGitHubRelease {
    [CmdletBinding(DefaultParameterSetName = 'Download')]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [string] $OwnerRepository,

        [Parameter(Mandatory = $false, ParameterSetName = 'Download')]
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

        [Parameter(Mandatory = $false, ParameterSetName = 'NoDownload')]
        [switch] $NoDownload,

        [Parameter(Mandatory = $false)]
        [string] $Token,

        [Parameter(Mandatory = $false)]
        [switch] $PrivateRepo
    )
    process {
        # Import the required cmdlets
        $neededcmdlets = @('Install-Dependencies', 'Get-FileDownload', 'Invoke-AriaDownload', 'Get-LongName', 'Write-Logg', 'Get-Properties')
        $neededcmdlets | ForEach-Object {
            if (-not (Get-Command -Name $_ -ErrorAction SilentlyContinue)) {
                if (-not (Get-Command -Name 'Install-Cmdlet' -ErrorAction SilentlyContinue)) {
                    $method = Invoke-RestMethod -Uri 'https://raw.githubusercontent.com/Donovoi/PowerShell-Profile/main/functions/Install-Cmdlet.ps1'
                    $finalstring = [scriptblock]::Create($method.ToString() + "`nExport-ModuleMember -Function * -Alias *")
                    New-Module -Name 'InstallCmdlet' -ScriptBlock $finalstring | Import-Module
                }
                Write-Verbose -Message "Importing cmdlet: $_"
                $Cmdletstoinvoke = Install-Cmdlet -donovoicmdlets $_
                $Cmdletstoinvoke | Import-Module -Force
            }
        }

        # fix any certificate issues
        if ($PSVersionTable.PSVersion.Major -eq 5) {
            [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
        }
        $VersionOnly = $null

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
            $VersionOnly = $Latestrelease.tag_name
            $Release = $asset.url
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
                    $releases = Invoke-WebRequest -Uri $apiurl -Headers $headers
                    $Releaseparsedjson = ConvertFrom-Json -InputObject $releases.Content | Where-Object -FilterScript { $_.prerelease -eq $true }
                    $Release = $Releaseparsedjson.assets.Browser_Download_url | Where-Object -FilterScript { $_ -like "*$AssetName*" } | Select-Object -First 1
                    $VersionOnly = $Releaseparsedjson.tag_name
                }
                else {
                    $Releaseinfo = Invoke-WebRequest -Uri ($apiurl + '/latest') -Headers $headers -SkipHttpErrorCheck
                    if (-not($Releaseinfo.StatusCode -like '40*')) {
                        $Releaseparsedjson = ConvertFrom-Json -InputObject $Releaseinfo.Content
                        $Release = $Releaseparsedjson.assets.Browser_Download_url | Where-Object -FilterScript { $_ -like "*$AssetName*" } | Select-Object -First 1
                        $VersionOnly = $Releaseparsedjson.tag_name
                    }
                    else {
                        Write-Logg -Message "Looks like the repo doesn't have a latest tag, let's try another way" -Level Warning
                        # Handle the case where the repo doesn't have a latest tag
                        $ManualRelease = Invoke-RestMethod -Uri $apiurl -Headers $headers | Sort-Object -Property created_at | Select-Object -Last 1
                        $manualDownloadurl = $ManualRelease.assets.Browser_Download_url | Select-Object -First 1
                        if ([string]::IsNullOrEmpty($manualDownloadurl)) {
                            Write-Logg -Message "Looks like the repo doesn't have the release titled $($AssetName), try changing the asset name" -Level error
                            Write-Logg -Message 'exiting script..' -Level warning
                            exit
                        }
                    }
                }
            }

            # Handle 'NoDownload' parameter
            if ($PSBoundParameters.ContainsKey('NoDownload')) {
                return $VersionOnly
            }
            # Prepare for download
            if (-not (Test-Path $DownloadPathDirectory)) {
                New-Item -Path $DownloadPathDirectory -ItemType Directory -Force
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
                    Expand-Archive -Path $downloadedFile -DestinationPath $tempDir -Force
                    $ExtractedFiles = Join-Path -Path $tempDir -ChildPath $([System.IO.Path]::GetFileNameWithoutExtension($DownloadedFile))
                    Write-Logg -Message "Extracted $downloadedFile to $ExtractedFiles"
                    return $ExtractedFiles
                }
                else {
                    Expand-Archive -Path $downloadedFile -DestinationPath $DownloadPathDirectory -Force
                    $ExtractedFiles = Join-Path -Path $DownloadPathDirectory -ChildPath $([System.IO.Path]::GetFileNameWithoutExtension($DownloadedFile))
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