function Get-LatestGitHubRelease {
    [CmdletBinding(DefaultParameterSetName = 'Download')]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [string]
        $OwnerRepository,
        [Parameter(Mandatory = $false, ParameterSetName = 'Download')]
        [string]
        $AssetName,
        [Parameter(Mandatory = $false, ParameterSetName = 'Download')]
        [string]
        $DownloadPathDirectory = $PWD,
        [Parameter(Mandatory = $false, ParameterSetName = 'Download')]
        [switch]
        $ExtractZip,
        [Parameter(Mandatory = $false, ParameterSetName = 'Download')]
        [switch]
        $UseAria2,
        [Parameter(Mandatory = $false)]
        [switch]
        $PreRelease,
        [Parameter(Mandatory = $false, ParameterSetName = 'VersionOnly')]
        [switch]
        $VersionOnly
    )

    # Get the latest release from the GitHub API
    $headers = @{
        'Accept'               = 'application/vnd.github+json'
        'X-GitHub-Api-Version' = '2022-11-28'
    }
    $apiurl = "https://api.github.com/repos/$OwnerRepository/releases"
    if ($PreRelease) {
        $releases = Invoke-RestMethod -Uri $apiurl -Headers $headers
        $Release = $releases | Sort-Object -Property created_at | Select-Object -Last 1
    }
    else {
        $Release = Invoke-RestMethod $($apiurl + '/latest') -Headers $headers
    }

    if ($Release.Message -like '*Not Found*') {
        Write-Log -Message "Looks like the repo doesn't have a latest tag, let's try another way" -Level Warning
        # Get the asset with the specified name
        $ManualRelease = Invoke-RestMethod -Uri $apiurl -Headers $headers | Sort-Object -Property created_at | Select-Object -Last 1
        $manualDownloadurl = $ManualRelease.assets.Browser_Download_url | Select-Object -First 1
    }


    
    # stop here if we are just getting the version number
    if ($PSBoundParameters.ContainsKey('VersionOnly')) {
        $Version = $Release.name.Split(' ')[0]
        return $Version
    }
    else {
        # Find the asset with the specified name
        $asset = $Release.assets | Where-Object { $_ -like "*$AssetName*" } | Select-Object -First 1
    }


    # Download the asset
    if (-not (Test-Path $DownloadPathDirectory)) {
        New-Item -Path $DownloadPathDirectory -ItemType Directory -Force
    }

    if ($asset.Browser_Download_url) {
        if ($UseAria2) {
            $downloadedFile = Get-DownloadFile -URL $asset.Browser_Download_url -OutFile (Join-Path -Path $DownloadPathDirectory -ChildPath $asset.Name) -UseAria2
        }
        else {
            $downloadedFile = (Join-Path -Path $DownloadPathDirectory -ChildPath $asset.Name)
            Invoke-WebRequest $asset.Browser_Download_url -OutFile $downloadedFile
        }
    }
    else {
        if ($UseAria2) {
            $downloadedFile = Get-DownloadFile -URL $manualDownloadurl -OutFile (Join-Path -Path $DownloadPathDirectory -ChildPath $($manualDownloadurl -split '\/')[-1]) -UseAria2
        }
        else {
            $downloadedFile = (Join-Path -Path $DownloadPathDirectory -ChildPath $($manualDownloadurl -split '\/')[-1])
            Invoke-WebRequest $manualDownloadurl -OutFile $downloadedFile
        }
    }

    if ($ExtractZip) {
        # check if the file is a zip file
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
    }
    return $downloadedFile
}