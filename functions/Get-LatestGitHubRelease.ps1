function Get-LatestGitHubRelease {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [string]
        $OwnerRepository,
        [Parameter(Mandatory = $true)]
        [string]
        $AssetName,
        [Parameter(Mandatory = $false)]
        [string]
        $DownloadPathDirectory = $PSSCRIPTROOT,
        [Parameter(Mandatory = $false)]
        [switch]
        $ExtractZip,
        [Parameter(Mandatory = $false)]
        [switch]
        $UseAria2
    )

    # Get the latest release from the GitHub API
    $headers = @{
        'Accept'               = 'application/vnd.github+json'
        'X-GitHub-Api-Version' = '2022-11-28'
    }
    $apiurl = "https://api.github.com/repos/$OwnerRepository/releases"
    $latestRelease = Invoke-RestMethod $($apiurl + '/latest') -Headers $headers

    if (Where-Object { $latestRelease.Message -like '*Not Found*' } -ErrorAction SilentlyContinue) {
        Write-Log -Message "Looks like the repo doesn't have a latest tag, let's try another way" -Level Warning
        # Get the asset with the specified name
        $ManuallatestRelease = Invoke-RestMethod -Uri $apiurl -Headers $headers | Sort-Object -Property created_at | Select-Object -Last 1
        $manualDownloadurl = $ManuallatestRelease.assets.Browser_Download_url | Select-Object -First 1
    }

    # Find the asset with the specified name
    $asset = $latestRelease.assets | Where-Object { $_ -like "*$AssetName*" } | Select-Object -First 1

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
        Write-Log -Message "Downloaded $downloadedFile to $DownloadPathDirectory" -Level INFO
    }
    return $downloadedFile
}