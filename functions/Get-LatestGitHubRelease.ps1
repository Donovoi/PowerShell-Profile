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

.PARAMETER Authenticate
    Specifies whether to authenticate with GitHub using the device flow. This parameter is optional.

.PARAMETER NoRPCMode
    Specifies whether to disable RPC mode for aria2. This parameter is optional.

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
        [switch] $PrivateRepo,

        [Parameter(Mandatory = $false)]
        [switch] $Authenticate,

        [Parameter(Mandatory = $false)]
        [switch] $NoRPCMode
    )
    process {
        # Import the required cmdlets
        $neededcmdlets = @('Install-Dependencies', 'Get-FileDownload', 'Write-InformationColored', 'Invoke-AriaDownload', 'Get-LongName', 'Write-Logg', 'Get-Properties')
        foreach ($cmd in $neededcmdlets) {
            if (-not (Get-Command -Name $cmd -ErrorAction SilentlyContinue)) {
                if (-not (Get-Command -Name 'Install-Cmdlet' -ErrorAction SilentlyContinue)) {
                    $method = Invoke-RestMethod -Uri 'https://raw.githubusercontent.com/Donovoi/PowerShell-Profile/main/functions/Install-Cmdlet.ps1'
                    $finalstring = [scriptblock]::Create($method.ToString() + "`nExport-ModuleMember -Function * -Alias *")
                    New-Module -Name 'InstallCmdlet' -ScriptBlock $finalstring | Import-Module
                }
                Write-Verbose "Importing cmdlet: $cmd"
                $scriptBlockOrPath = Install-Cmdlet -RepositoryCmdlets $cmd -PreferLocal -Force # Renamed variable

                # Check the type of the returned value and import accordingly
                if ($scriptBlockOrPath -is [scriptblock]) {
                    $moduleName = "Dynamic_$cmd"
                    New-Module -Name $moduleName -ScriptBlock $scriptBlockOrPath | Import-Module -Force -Global
                    Write-Verbose "Imported $cmd as dynamic module: $moduleName"
                }
                elseif ($scriptBlockOrPath -is [System.Management.Automation.PSModuleInfo]) {
                    Write-Verbose "Module for $cmd was already imported: $($scriptBlockOrPath.Name)"
                }
                elseif ($scriptBlockOrPath -is [System.IO.FileInfo]) {
                    Import-Module -Name $scriptBlockOrPath.FullName -Force -Global
                    Write-Verbose "Imported $cmd from file: $($scriptBlockOrPath.FullName)"
                }
                else {
                    Write-Warning "Could not import $cmd`: Unexpected return type from Install-Cmdlet: $($scriptBlockOrPath.GetType().FullName)"
                }
            }
        }

        # --- AUTHENTICATION SETUP ---
        if ($PSVersionTable.PSVersion.Major -eq 5) {
            [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
        }

        $script:GitHubDeviceFlowToken = $script:GitHubDeviceFlowToken # Use script scope for session-wide token
        $authorizationHeaderValue = $null

        if ($Authenticate) {
            if (-not $script:GitHubDeviceFlowToken) {
                Write-Information 'Attempting to authenticate with GitHub via device flow...'
                # IMPORTANT: Replace 'YOUR_CLIENT_ID_HERE' with your actual GitHub OAuth App Client ID for device flow.
                # You can create an OAuth App here: https://github.com/settings/applications/new
                # Using a generic public client ID for broad compatibility, but for a personal script, your own is better.
                $clientId = 'Iv1.b927f5024150d080' # Example: VS Code public client ID, replace if possible

                if ($clientId -eq 'YOUR_CLIENT_ID_HERE') {
                    # Reminder if default placeholder is still there
                    Write-Warning "Placeholder Client ID 'YOUR_CLIENT_ID_HERE' detected. GitHub device flow authentication may not work as expected until a valid Client ID is configured in the script."
                }

                $deviceCodePayload = @{ client_id = $clientId; scope = 'repo' }
                try {
                    $deviceCodeResponse = Invoke-RestMethod -Uri 'https://github.com/login/device/code' -Method POST -Body $deviceCodePayload -ContentType 'application/x-www-form-urlencoded' -ErrorAction Stop
                }
                catch {
                    Write-Error "Failed to initiate GitHub device flow. Error: $($_.Exception.Message)"
                    return
                }

                Write-Logg -Message "Please open your browser and go to: $($deviceCodeResponse.verification_uri)" -Level INFO
                Write-Logg -Message "And enter this code: $($deviceCodeResponse.user_code)" -Level INFO
                # Consider: Add-Type -AssemblyName System.Windows.Forms; try { [System.Windows.Forms.Clipboard]::SetText($deviceCodeResponse.user_code) } catch {}
                # try { Start-Process $deviceCodeResponse.verification_uri } catch { Write-Warning "Could not auto-open browser."}

                $tokenPollPayload = @{
                    client_id   = $clientId
                    device_code = $deviceCodeResponse.device_code
                    grant_type  = 'urn:ietf:params:oauth:grant-type:device_code'
                }
                $pollInterval = $deviceCodeResponse.interval
                $timeoutSeconds = $deviceCodeResponse.expires_in
                $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
                $obtainedToken = $null

                Write-Information "Waiting for you to authorize in the browser (this request will timeout in $($timeoutSeconds / 60) minutes)..."
                do {
                    Start-Sleep -Seconds $pollInterval
                    try {
                        $tokenResponse = Invoke-RestMethod -Uri 'https://github.com/login/oauth/access_token' -Method POST -Body $tokenPollPayload -ContentType 'application/x-www-form-urlencoded' -ErrorAction SilentlyContinue
                    }
                    catch {
                        Write-Warning "Network error while polling for GitHub token: $($_.Exception.Message)"
                        Start-Sleep -Seconds ($pollInterval * 2) # Basic backoff
                        continue
                    }

                    if ($tokenResponse.access_token) {
                        $obtainedToken = $tokenResponse.access_token
                        $script:GitHubDeviceFlowToken = $obtainedToken
                        Write-Information "`nSuccessfully authenticated with GitHub."
                        break
                    }
                    elseif ($tokenResponse.error) {
                        if ($tokenResponse.error -eq 'authorization_pending') {
                            Write-Host '.' -NoNewline
                        }
                        elseif ($tokenResponse.error -eq 'slow_down') {
                            $pollInterval += 5
                            Write-Information "`nSlowing down polling interval to $pollInterval seconds as requested by GitHub."
                        }
                        elseif ($tokenResponse.error -eq 'expired_token') {
                            Write-Error "`nGitHub device code expired. Please try running the command again."
                            $stopwatch.Stop(); return
                        }
                        else {
                            Write-Error "`nError during GitHub authentication: $($tokenResponse.error) - $($tokenResponse.error_description)"
                            $stopwatch.Stop(); return
                        }
                    }
                    else {
                        Write-Warning "`nUnexpected response while polling for GitHub token."
                    }

                    if ($stopwatch.Elapsed.TotalSeconds -ge $timeoutSeconds) {
                        Write-Error "`nGitHub authentication timed out. The device code expired."
                        break
                    }
                } while (-not $obtainedToken)
                $stopwatch.Stop()

                if (-not $script:GitHubDeviceFlowToken) {
                    Write-Error 'GitHub authentication via device flow was not completed. Cannot proceed with authenticated requests.'
                    return
                }
            }
            # If -Authenticate was true, and we have a token (either new or from script scope var)
            if ($script:GitHubDeviceFlowToken) {
                $authorizationHeaderValue = "Bearer $($script:GitHubDeviceFlowToken)"
            }
        }
        elseif ($Token) {
            # If -Authenticate not used, but -Token (PAT) is provided
            $authorizationHeaderValue = "token $Token"
        }

        if ($PrivateRepo -and -not $authorizationHeaderValue) {
            Write-Error "Accessing a private repository ('$OwnerRepository') requires authentication. Please use the -Authenticate switch or provide a -Token with sufficient permissions."
            return
        }

        $commonApiHeaders = @{
            'Accept'               = 'application/vnd.github+json'
            'X-GitHub-Api-Version' = '2022-11-28'
            'User-Agent'           = 'PowerShell-GetLatestGitHubRelease-Script'
        }
        if ($authorizationHeaderValue) {
            $commonApiHeaders['Authorization'] = $authorizationHeaderValue
            Write-Verbose 'Using Authorization header for GitHub API requests.'
        }
        else {
            Write-Verbose 'Making unauthenticated GitHub API requests.'
        }
        # --- END AUTHENTICATION ---

        $VersionOnly = $null
        $DownloadedFile = $null
        $ReleaseDownloadUrl = $null
        $targetRelease = $null

        try {
            # --- FETCH RELEASE METADATA ---
            $releasesApiUrlBase = "https://api.github.com/repos/$OwnerRepository/releases"
            $fetchedReleasesData = $null # To store raw API response if needed

            if ($PreRelease) {
                Write-Verbose "Fetching all releases for '$OwnerRepository' to find pre-releases."
                $allReleases = Invoke-RestMethod -Uri $releasesApiUrlBase -Headers $commonApiHeaders -Method Get -ErrorAction Stop
                $targetRelease = $allReleases | Where-Object { $_.prerelease -eq $true } | Sort-Object -Property created_at -Descending | Select-Object -First 1
            }
            else {
                try {
                    Write-Verbose "Fetching latest stable release for '$OwnerRepository' from '$releasesApiUrlBase/latest'."
                    $targetRelease = Invoke-RestMethod -Uri "$releasesApiUrlBase/latest" -Headers $commonApiHeaders -Method Get -ErrorAction Stop
                }
                catch {
                    $statusCode = $_.Exception.Response.StatusCode
                    Write-Logg -Message "Failed to get '/latest' release for '$OwnerRepository' (Status: $statusCode). Fetching all releases to find the latest stable. Error: $($_.Exception.Message)" -Level Warning
                    $allReleases = Invoke-RestMethod -Uri $releasesApiUrlBase -Headers $commonApiHeaders -Method Get -ErrorAction Stop
                    $targetRelease = $allReleases | Where-Object { $_.prerelease -eq $false } | Sort-Object -Property created_at -Descending | Select-Object -First 1
                }
            }

            if (-not $targetRelease) {
                $releaseTypeMsg = if ($PreRelease) {
                    'pre-releases' 
                }
                else {
                    'stable releases' 
                }
                Write-Error "No $releaseTypeMsg found for repository '$OwnerRepository'."
                return
            }

            $VersionOnly = $targetRelease.tag_name
            Write-Verbose "Latest release version for '$OwnerRepository' is: $VersionOnly"

            if ($NoDownload) {
                Write-Verbose "'-NoDownload' specified. Returning version '$VersionOnly'."
                return $VersionOnly
            }
            # --- END FETCH RELEASE METADATA ---

            # --- ASSET SELECTION ---
            $selectedAsset = $null
            if (-not $targetRelease.assets -or $targetRelease.assets.Count -eq 0) {
                Write-Error "No assets found in release '$VersionOnly' (tag: $($targetRelease.tag_name)) for repository '$OwnerRepository'."
                return
            }

            if ($AssetName) {
                $selectedAsset = $targetRelease.assets | Where-Object { $_.name -eq $AssetName } | Select-Object -First 1
                if (-not $selectedAsset) {
                    $selectedAsset = $targetRelease.assets | Where-Object { $_.name -like "*$AssetName*" } | Select-Object -First 1
                }
            }
            elseif ($targetRelease.assets.Count -eq 1) {
                $selectedAsset = $targetRelease.assets[0]
                Write-Logg -Message "No -AssetName specified and only one asset ('$($selectedAsset.name)') found in release '$VersionOnly'. Selecting it automatically." -Level Verbose
            }
            elseif ($targetRelease.assets.Count -gt 1) {
                $availableAssetNamesStr = $targetRelease.assets.name -join "', '"
                Write-Error "Multiple assets found in release '$VersionOnly' for '$OwnerRepository'. Please specify -AssetName. Available assets: '$availableAssetNamesStr'"
                return
            }

            if (-not $selectedAsset) {
                $assetNameToReportMsg = if ($AssetName) {
                    "'$AssetName'" 
                }
                else {
                    'any asset (and none could be auto-selected)' 
                }
                Write-Error "Asset $assetNameToReportMsg not found in release '$VersionOnly' for '$OwnerRepository'."
                if ($targetRelease.assets) {
                    Write-Warning "Available assets in release '$VersionOnly': $($targetRelease.assets.name -join ', ')"
                }
                return
            }
            
            $ReleaseDownloadUrl = $selectedAsset.browser_download_url
            Write-Verbose "Selected asset for download: '$($selectedAsset.name)' from URL: $ReleaseDownloadUrl"
            # --- END ASSET SELECTION ---

            # --- DOWNLOAD LOGIC ---
            if (-not (Test-Path $DownloadPathDirectory)) {
                Write-Verbose "Creating download directory: $DownloadPathDirectory"
                New-Item -Path $DownloadPathDirectory -ItemType Directory -Force | Out-Null
            }

            if ($ReleaseDownloadUrl) {
                if ($UseAria2 -and (-not (Test-Path -Path $Aria2cExePath -ErrorAction SilentlyContinue))) {
                    Write-Verbose "Aria2 specified but not found at '$Aria2cExePath'. Attempting to download Aria2."
                    # Recursive call - ensure it doesn't cause infinite loop or auth issues
                    # Pass -Authenticate:$false to prevent re-prompting if already in device flow for parent call
                    Get-LatestGitHubRelease -OwnerRepository 'aria2/aria2' -AssetName '*-win-64bit-*' -ExtractZip -DownloadPathDirectory $PWD -Authenticate:$false 
                    $foundAria2 = Get-ChildItem -Path $PWD -Recurse -Filter 'aria2c.exe' | Select-Object -First 1
                    if ($foundAria2) {
                        $Aria2cExePath = $foundAria2.FullName
                        Write-Verbose "Aria2 downloaded to $Aria2cExePath"
                    }
                    else {
                        Write-Warning 'Failed to download Aria2. Proceeding without it.'
                        $UseAria2 = $false
                    }
                }

                $downloadFileParams = @{
                    URL                  = $ReleaseDownloadUrl
                    DestinationDirectory = (Get-LongName -ShortName $DownloadPathDirectory)
                }
                if ($UseAria2 -and $Aria2cExePath) {
                    $downloadFileParams['UseAria2'] = $true
                    $downloadFileParams['aria2cexe'] = $Aria2cExePath
                    if ($PSBoundParameters.ContainsKey('NoRPCMode')) {
                        $downloadFileParams['NoRPCMode'] = $NoRPCMode 
                    }
                }

                # Get-FileDownload might need a token for private assets.
                # If device flow was used, $Token (PAT) might be null.
                # If Get-FileDownload is adapted for Bearer tokens, $script:GitHubDeviceFlowToken could be used.
                # For now, it relies on the original -Token (PAT) if provided.
                if ($Token) {
                    $downloadFileParams['Token'] = $Token
                }
                
                Write-Verbose "Calling Get-FileDownload with parameters: $(($downloadFileParams | Out-String).Trim() | Select-String -NotMatch 'System.Collections.Hashtable')"
                $DownloadedFile = Get-FileDownload @downloadFileParams
                Write-Logg -Message "Downloaded file: $DownloadedFile" -Level Info
            }
            else {
                Write-Error "No download URL could be determined for the selected asset '$($selectedAsset.name)'."
                return
            }
            # --- END DOWNLOAD LOGIC ---

            # --- EXTRACT LOGIC ---
            if ($ExtractZip) {
                if ($DownloadedFile -is [array]) {
                    $DownloadedFile = $DownloadedFile | Where-Object { Test-Path $_ -PathType Leaf } | Select-Object -First 1
                }
                if (-not $DownloadedFile -or -not (Test-Path $DownloadedFile)) {
                    Write-Error "Downloaded file path is invalid or file not found: '$DownloadedFile'. Cannot extract."
                    return $null
                }
                if ($DownloadedFile -notlike '*.zip') {
                    Write-Logg -Message "Downloaded file '$DownloadedFile' is not a zip file. Skipping extraction." -Level Warning
                    return $DownloadedFile
                }
                Write-Verbose "Extracting '$DownloadedFile' to '$DownloadPathDirectory'"
                Expand-Archive -Path $DownloadedFile -DestinationPath $DownloadPathDirectory -Force
                # $ExtractedFilesPath = Join-Path -Path $DownloadPathDirectory -ChildPath ([System.IO.Path]::GetFileNameWithoutExtension($DownloadedFile)) # This might not be accurate if zip extracts to root
                Write-Logg -Message "Extracted '$DownloadedFile' to '$DownloadPathDirectory'" -Level Info
                return $DownloadPathDirectory 
            }
            else {
                Write-Logg -Message "Downloaded '$DownloadedFile' to '$DownloadPathDirectory'. No extraction requested." -Level Info
                return $DownloadedFile
            }
            # --- END EXTRACT LOGIC ---
        }
        catch {
            Write-Logg -Message "An error occurred in Get-LatestGitHubRelease: $($_.Exception.Message)" -Level Error
            if ($_.Exception.Response) {
                Write-Logg -Message "Underlying HTTP Response Status: $($_.Exception.Response.StatusCode)" -Level Error
                $responseContent = ''
                try {
                    $responseContent = $_.Exception.Response.Content | Out-String 
                }
                catch {
                }
                Write-Logg -Message "Underlying HTTP Response Content: $responseContent" -Level Verbose
            }
            elseif ($_.Exception.ErrorRecord) {
                Write-Logg -Message "PowerShell Error Record: $($_.Exception.ErrorRecord | Out-String)" -Level Verbose
            }
            throw
        }
    }
}