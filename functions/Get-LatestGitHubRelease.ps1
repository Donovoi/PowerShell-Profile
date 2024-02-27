<#
.SYNOPSIS
   This function retrieves the latest release from a specified GitHub repository and optionally downloads it to your system.

.DESCRIPTION
   The Get-LatestGitHubRelease function is designed to help you easily find and download the latest release from a GitHub repository.
   It can return details about the latest release, download assets, and even extract downloaded zip files automatically.
   The function will only prompt for a GitHub token if the repository is private.

.PARAMETER OwnerRepository
   Specifies the GitHub repository from which to retrieve the latest release. The format should be 'owner/repository'.

.PARAMETER AssetName
   Specifies the name of the asset to look for within the release. If not specified, the function will select the first asset it finds.

.PARAMETER DownloadPathDirectory
   Specifies the directory where the downloaded assets should be saved. If not specified, assets will be saved in the current directory.

.PARAMETER ExtractZip
   A switch parameter that, when used, instructs the function to automatically extract downloaded zip files.

.PARAMETER UseAria2
   A switch parameter that, when used, instructs the function to use Aria2 for downloading assets, if available.

.PARAMETER PreRelease
   A switch parameter that, when used, allows the function to consider pre-releases when looking for the latest release.

.PARAMETER VersionOnly
   A switch parameter that, when used, instructs the function to only return the version of the latest release, without downloading any assets.

.PARAMETER TokenName
   Specifies the name of the secret containing the GitHub token to be used for authentication. This is only required for private repositories and defaults to ReadOnlyGitHubToken.

.EXAMPLE
   Get-LatestGitHubRelease -OwnerRepository 'owner/repository' -TokenName 'your_secret_token_here'

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
        $Aria2cExePath = 'C:\aria2\aria2c.exe',

        [Parameter(Mandatory = $false)]
        [switch] $PreRelease,

        [Parameter(Mandatory = $false, ParameterSetName = 'VersionOnly')]
        [switch] $VersionOnly,

        [Parameter(Mandatory = $false)]
        [string] $Token,

        [Parameter(Mandatory = $false)]
        [switch] $PrivateRepo
    )

    begin {
        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12

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
            $preRelease = $releases | Where-Object { $_.prerelease -eq $true } | Select-Object -First 1
            if ($null -eq $preRelease) {
                Write-Error 'No pre-release found.'
                return
            }
    
            $asset = $preRelease.assets | Select-Object -First 1
            if ($null -eq $asset) {
                Write-Error 'No assets found in the pre-release.'
                return
            }
            $assetUrl = $asset.url

            if ($UseAria2) {
                if (-not(Test-Path -Path $Aria2cExePath -ErrorAction SilentlyContinue)) {
                    $aria2directory = Get-LatestGitHubRelease -OwnerRepository 'aria2/aria2' -AssetName '-win-64bit-' -ExtractZip
                    $Aria2cExePath = $(Get-ChildItem -Recurse -Path $aria2directory -Filter 'aria2c.exe').FullName
                }
                # Initialize an empty hashtable
                $downloadFileParams = @{}

                # Mandatory parameters
                $downloadFileParams['URL'] = $assetUrl
                $downloadFileParams['OutFiledirectory'] = Get-LongName -ShortName $DownloadPathDirectory

                # Conditionally add parameters
                $downloadFileParams['UseAria2'] = $true
                if ((Test-Path -Path $Aria2cExePath -ErrorAction silentlycontinue)) {
                    $downloadFileParams['aria2cexe'] = $Aria2cExePath
                }

                if ( (-not [string]::IsNullOrEmpty($Token)) -and $PrivateRepo) {
                    $downloadFileParams['SecretName'] = $TokenName
                    $downloadFileParams['IsPrivateRepo'] = $true
                }

                # Splat the parameters onto the function call
                Get-FileDownload @downloadFileParams
            }

            # add headers for the binary download
            $httpClient.DefaultRequestHeaders.Accept.Add((New-Object System.Net.Http.Headers.MediaTypeWithQualityHeaderValue('application/octet-stream')))

            $response = $httpClient.GetAsync($assetUrl, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).Result
            if (-not $response.IsSuccessStatusCode) {
                Write-Error "Failed to download pre-release asset from GitHub API with status code $($response.StatusCode)."
                return
            }
        
            $totalBytes = $response.Content.Headers.ContentLength
            $stream = $response.Content.ReadAsStreamAsync().Result
            $outputFilePath = Join-Path -Path $(Get-Location).ToString() -ChildPath $( $($Repository -replace '/', '_').tostring() + '_' + $($preRelease.tag_name).toString() + '.zip')
            $fileStream = [System.IO.File]::Create($outputFilePath)
        
            $bufferSize = 20MB
            $buffer = New-Object byte[] $bufferSize
            $bytesRead = 0
            $progress = 0
            # if powershell 5.1 do not show progress to speed up the download
            if ($PSVersionTable.PSVersion.Major -eq 5) {
                Write-Host "Downloading zip: $assetUrl"
                while (($read = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
                    $fileStream.Write($buffer, 0, $read)
                    $bytesRead += $read
                }
            }
            else {
                Write-Progress -Activity 'Downloading' -Status 'Downloading zip' -PercentComplete 0        
                while (($read = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
                    $fileStream.Write($buffer, 0, $read)
                    $bytesRead += $read
                    $newProgress = [math]::Round(($bytesRead / $totalBytes) * 100)
                    if ($newProgress -gt $progress) {
                        $progress = $newProgress
                        Write-Progress -PercentComplete $progress -Status 'Downloading' -Activity "Downloading zip: $assetUrl"
                    }
                }
            }
            Write-Progress -Completed -Status 'Download Completed' -Activity "Downloading zip: $assetUrl"
        }
        else {

            # Prepare API headers without Authorization
            $headers = @{
                'Accept'               = 'application/vnd.github+json'
                'X-GitHub-Api-Version' = '2022-11-28'
            }
        }
    }
    process {
        try {
            # Define API URL
            $apiurl = "https://api.github.com/repos/$OwnerRepository/releases"

            # Retrieve release information
            $Release = if ($PreRelease) {
                $releases = Invoke-RestMethod -Uri $apiurl -Headers $headers
                $releases | Sort-Object -Property created_at | Select-Object -Last 1
            }
            else {
                Invoke-RestMethod -Uri ($apiurl + '/latest') -Headers $headers
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
            else {
                $asset = $Release.assets | Where-Object { $_ -like "*$AssetName*" } | Select-Object -First 1
            }

            # Prepare for download
            if (-not (Test-Path $DownloadPathDirectory)) {
                New-Item -Path $DownloadPathDirectory -ItemType Directory -Force
            }

            # Download asset but make sure the variable is empty each time
            $DownloadedFile = ''
            $downloadedFile = if ($asset.Browser_Download_url) {
                if ($UseAria2) {
                    if (-not(Test-Path -Path $Aria2cExePath -ErrorAction SilentlyContinue)) {
                        $aria2directory = Get-LatestGitHubRelease -OwnerRepository 'aria2/aria2' -AssetName '-win-64bit-' -ExtractZip
                        $Aria2cExePath = $(Get-ChildItem -Recurse -Path $aria2directory -Filter 'aria2c.exe').FullName
                    }
                    # Initialize an empty hashtable
                    $downloadFileParams = @{}

                    # Mandatory parameters
                    $downloadFileParams['URL'] = $asset.Browser_Download_url
                    $downloadFileParams['OutFiledirectory'] = Get-LongName -ShortName $DownloadPathDirectory

                    # Conditionally add parameters
                    $downloadFileParams['UseAria2'] = $true
                    if ((Test-Path -Path $Aria2cExePath -ErrorAction silentlycontinue)) {
                        $downloadFileParams['aria2cexe'] = $Aria2cExePath
                    }

                    if ( (-not [string]::IsNullOrEmpty($Token)) -and $PrivateRepo) {
                        $downloadFileParams['SecretName'] = $TokenName
                        $downloadFileParams['IsPrivateRepo'] = $true
                    }

                    # Splat the parameters onto the function call
                    Get-FileDownload @downloadFileParams
                }
                else {
                    if ($asset.Name -like '*aria*') {
                        # Generate a random file name without extension
                        $randomFileName = [System.IO.Path]::GetRandomFileName()

                        # Replace the generated extension with '.zip'
                        $zipFileName = $randomFileName -replace '(\.[^.]+)$', '.zip'

                        $OutFile = $ENV:TEMP + '\' + $zipFileName
                    }
                    else {
                        $outFile = Join-Path -Path $DownloadPathDirectory -ChildPath $asset.Name
                    }
                    Invoke-WebRequest $asset.Browser_Download_url -OutFile $outFile
                    $OutFile
                }
            }
            else {
                if ($UseAria2) {
                    if ([string]::IsNullOrEmpty($manualDownloadurl)) {
                        Write-Logg -Message "Looks like the repo doesn't have the release titled $($AssetName), try changing the asset name" -Level error
                        Write-Logg -Message 'exiting script..' -Level warning
                        exit
                    }
                    $null = Get-FileDownload -URL $manualDownloadurl -OutFile (Join-Path -Path $DownloadPathDirectory -ChildPath ($manualDownloadurl -split '\/')[-1]) -UseAria2 -SecretName $TokenName
                }
                else {
                    if ([string]::IsNullOrEmpty($manualDownloadurl)) {
                        Write-Logg -Message "Looks like the repo doesn't have the release titled $($AssetName), try changing the asset name" -Level error
                        Write-Logg -Message 'exiting script..' -Level warning
                        exit
                    }
                    $outFile = Join-Path -Path $DownloadPathDirectory -ChildPath ($manualDownloadurl -split '\/')[-1]
                    Invoke-WebRequest $manualDownloadurl -OutFile $outFile
                    $outFile
                }
            }

            # Handle 'ExtractZip' parameter
            if ($ExtractZip) {
                if ($downloadedFile -notlike '*.zip') {
                    Write-Logg -Message 'The downloaded file is not a zip file, skipping extraction' -Level Warning
                    return $downloadedFile
                }
                if ($asset.Name -like '*aria*') {
                    # to make sure there are no locks on the file, we will expand it to a temp directory with a random name
                    $tempDir = Join-Path -Path $ENV:TEMP -ChildPath ([System.IO.Path]::GetRandomFileName())
                    Expand-Archive -Path $downloadedFile -DestinationPath $tempDir -Force
                    $ExtractedFiles = Join-Path -Path $tempDir -ChildPath ($asset.Name -replace '.zip', '')
                    Write-Logg -Message "Extracted $downloadedFile to $ExtractedFiles"
                    return $ExtractedFiles
                }
                else {
                    Expand-Archive -Path $downloadedFile -DestinationPath $DownloadPathDirectory -Force
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