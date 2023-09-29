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
   Specifies the name of the secret containing the GitHub token to be used for authentication. This is only required for private repositories and defaults to 'GitHubToken'.

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

        [Parameter(Mandatory = $false, ParameterSetName = 'Download')]
        [string] $DownloadPathDirectory = $PWD,

        [Parameter(Mandatory = $false, ParameterSetName = 'Download')]
        [switch] $ExtractZip,

        [Parameter(Mandatory = $false, ParameterSetName = 'Download')]
        [switch] $UseAria2,

        [Parameter(Mandatory = $false)]
        [switch] $PreRelease,

        [Parameter(Mandatory = $false, ParameterSetName = 'VersionOnly')]
        [switch] $VersionOnly,

        [Parameter(Mandatory = $false)]
        [string] $TokenName = 'GitHubToken'
    )
    
    begin {

          # Prepare API headers without Authorization
          $headers = @{
            'Accept'               = 'application/vnd.github+json'
            'X-GitHub-Api-Version' = '2022-11-28'
        }
    
        # Initialize a hashtable to hold the parameters
        $repoInfoUrl = "https://api.github.com/repos/$OwnerRepository"
        $params = @{
            Uri         = $repoInfoUrl
            Headers     = $headers
            ErrorAction = 'SilentlyContinue'
        }

        # Conditionally add the SkipHttpErrorCheck parameter based on your condition
        # Replace $YourCondition with the actual condition you want to check
        if ($PSVersionTable.PSVersion.Major -ge 7) {
            $params['SkipHttpErrorCheck'] = $true
        }

        # Use splatting to call Invoke-RestMethod
        $repoInfo = Invoke-RestMethod @params

        # Rest of your code
        $isPrivateRepo = switch ($repoInfo.message) {
            'Not Found*' {
                $true 
            }
            default {
                $false 
            }
        }

    
        if ($isPrivateRepo) {

            # Install any needed modules and import them
            if (-not (Get-Module -Name SecretManagement) -or (-not (Get-Module -Name SecretStore))) {
                Install-ExternalDependencies -PSModules 'Microsoft.PowerShell.SecretManagement', 'Microsoft.PowerShell.SecretStore'
            }

            # Initialize SecretStore configuration
            $currentConfig = Get-SecretStoreConfiguration
            if ($currentConfig.Authentication -ne 'None') {
                try {
                    Write-Host "You will now be asked to enter the password for the current store: " -ForegroundColor Yellow
                    Unlock-SecretStore -Password (Read-Host -Prompt "Enter the password for the secret store" -AsSecureString)
                }
                catch {
                    Set-SecretStoreConfiguration -Scope CurrentUser -Authentication None -Interaction None -Confirm:$false
                }
            }
            else {
                try {
                    Write-Host "Initializing the secret store..." -ForegroundColor Yellow
                    Write-Host "You will now be asked to enter a password for the secret store: " -ForegroundColor Yellow
                    Set-SecretStoreConfiguration -Scope CurrentUser -Authentication None -Interaction None -Confirm:$false
                }
                catch {
                    Write-Host "An error occurred while initializing the secret store: $_" -ForegroundColor Red
                    throw
                }
            }
    
            # Retrieve GitHub token
            $Token = Get-Secret -Name $TokenName -ErrorAction SilentlyContinue -AsPlainText
            if ($null -eq $Token) {
                $TokenValue = Read-Host -Prompt "Enter the GitHub token" -AsSecureString
                Set-StoredSecret -Secret $TokenValue -SecretName $TokenName
                $Token = $TokenValue
            }
    
            # Update headers to include Authorization
            $headers['Authorization'] = "Bearer $Token"
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
            if ($Release.Message -like '*Not Found*') {
                Write-Log -Message "Looks like the repo doesn't have a latest tag, let's try another way" -Level Warning
                $ManualRelease = Invoke-RestMethod -Uri $apiurl -Headers $headers | Sort-Object -Property created_at | Select-Object -Last 1
                $manualDownloadurl = $ManualRelease.assets.Browser_Download_url | Select-Object -First 1
                if ([string]::IsNullOrEmpty($manualDownloadurl)) {
                    Write-Log -Message "Looks like the repo doesn't have the release titled $($AssetName), try changing the asset name" -Level error
                    Write-Log -Message "exiting script.." -Level warning
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

            # Download asset
            $downloadedFile = if ($asset.Browser_Download_url) {
                if ($UseAria2) {
                    # Initialize an empty hashtable
                    $downloadFileParams = @{}

                    # Mandatory parameters
                    $downloadFileParams['URL'] = $asset.Browser_Download_url
                    $downloadFileParams['OutFile'] = (Join-Path -Path $DownloadPathDirectory -ChildPath $asset.Name)

                    # Conditionally add parameters
                    if ($UseAria2) {
                        $downloadFileParams['UseAria2'] = $true
                    }

                    if ($TokenName -and $isPrivateRepo) {
                        $downloadFileParams['SecretName'] = $TokenName
                    }

                    if ($isPrivateRepo) {
                        $downloadFileParams['IsPrivateRepo'] = $true
                    }

                    # Splat the parameters onto the function call
                    Get-DownloadFile @downloadFileParams                
                }
                else {
                    $outFile = Join-Path -Path $DownloadPathDirectory -ChildPath $asset.Name
                    Invoke-WebRequest $asset.Browser_Download_url -OutFile $outFile
                    $outFile
                }
            }
            else {
                if ($UseAria2) {
                    if ([string]::IsNullOrEmpty($manualDownloadurl)) {
                        Write-Log -Message "Looks like the repo doesn't have the release titled $($AssetName), try changing the asset name" -Level error
                        Write-Log -Message "exiting script.." -Level warning
                        exit
                    }
                    Get-DownloadFile -URL $manualDownloadurl -OutFile (Join-Path -Path $DownloadPathDirectory -ChildPath ($manualDownloadurl -split '\/')[-1]) -UseAria2 -SecretName $TokenName
                }
                else {
                    if ([string]::IsNullOrEmpty($manualDownloadurl)) {
                        Write-Log -Message "Looks like the repo doesn't have the release titled $($AssetName), try changing the asset name" -Level error
                        Write-Log -Message "exiting script.." -Level warning
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
                    Write-Log -Message 'The downloaded file is not a zip file, skipping extraction' -Level Warning
                    return $downloadedFile
                }
                Expand-Archive -Path $downloadedFile -DestinationPath $DownloadPathDirectory -Force
                $ExtractedFiles = Join-Path -Path $DownloadPathDirectory -ChildPath ($asset.Name -replace '.zip', '')
                Write-Log -Message "Extracted $downloadedFile to $ExtractedFiles"
                return $ExtractedFiles
            }
            else {
                Write-Log -Message "Downloaded $downloadedFile to $DownloadPathDirectory"
                return $downloadedFile
            }
        }
        catch {
            Write-Host "An error occurred: $_" -ForegroundColor Red
            throw
        }
    }
}

