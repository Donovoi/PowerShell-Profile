function Get-LatestGitHubRelease {
  [OutputType([string])]
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $true)]
    [string]
    $OwnerRepository,
    [Parameter(Mandatory = $true)]
    [string]
    $AssetName,
    [Parameter(Mandatory = $false)]
    [string]
    $DownloadPathDirectory = $PWD,
    [Parameter(Mandatory = $false)]
    [switch]
    $ExtractZip

  )

  # Get the latest release from the GitHub API
  $apiurl = "https://api.github.com/repos/$OwnerRepository/releases"
  $latestRelease = Invoke-RestMethod $($apiurl + '/latest') -ErrorAction SilentlyContinue 

  $headers = @{
    'Accept'               = 'application/vnd.github+json'
    'X-GitHub-Api-Version' = '2022-11-28'
  }

  if (-not ($latestRelease)) {
    Write-Log -Message "Looks like the repo doesn't have a latest tag, let's try another way" -Level Warning
    # Get the asset with the specified name

    $ManuallatestRelease = Invoke-RestMethod -Uri $apiurl -Headers $headers | Sort-Object -Property created_at | Select-Object -Last 1

    $manualDownloadurl = $ManuallatestRelease.assets.Browser_Download_url | Select-Object -First 1

  }

  $releasetolookfor = $latestRelease.assets ? $latestRelease.assets : $($manualDownloadurl -split '\/')[-1]

  # Find the asset with the specified name
  $asset = $releasetolookfor | Where-Object { $_ -like "*$AssetName*" } | Select-Object -First 1

  # Download the asset
  $DownloadPath = Join-Path -Path $DownloadPathDirectory -ChildPath $($asset.Name ? $asset.Name : $asset)
  Invoke-WebRequest $($asset.browser_download_url ? $asset.browser_download_url : $manualDownloadurl ) -OutFile $downloadPath

  if ($ExtractZip) {
    #  check if the file is a zip file
    if ($DownloadPath -notlike '*.zip') {
      Write-Log -Message 'The downloaded file is not a zip file, skipping extraction' -Level Warning
      return $DownloadPath
    }
    Expand-Archive -Path $DownloadPath -DestinationPath $DownloadPathDirectory -Force
    Write-Log -Message "Extracted $DownloadPath to $DownloadPathDirectory"
  }
  else {
    Write-Log -Message "Downloaded $DownloadPath to $DownloadPathDirectory"
  }
  return $DownloadPath
}