function Get-LatestGitHubRelease {
  [OutputType([string])]
  [CmdletBinding()]
  param (
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
  $latestRelease = Invoke-RestMethod "https://api.github.com/repos/$OwnerRepository/releases/latest"

  # Find the asset with the specified name
  $asset = $latestRelease.assets | Where-Object { $_.name -like $AssetName }

  # Download the asset
  $DownloadPath = Join-Path -Path $DownloadPathDirectory -ChildPath $asset.name

  Invoke-WebRequest $asset.browser_download_url -OutFile $downloadPath
  # Extract the asset if the switch is set
  if ($ExtractZip) {
    Expand-Archive -Path $DownloadPath -DestinationPath $DownloadPathDirectory -Force
    Write-Host "Extracted $DownloadPath to $DownloadPathDirectory"
  }
  else {
    Write-Host "Downloaded $DownloadPath to $DownloadPathDirectory"
  }
  # Return the path to the downloaded asset
  return $DownloadPath
}
