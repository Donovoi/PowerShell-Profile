function Get-LatestGitHubRelease() {
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

  if ($ExtractZip) {
      Expand-Archive -Path $DownloadPath -DestinationPath $DownloadPathDirectory -Force
      Write-Log -Message "Extracted $DownloadPath to $DownloadPathDirectory"
  }
  else {
      Write-Log -Message "Downloaded $DownloadPath to $DownloadPathDirectory"
  }
  return $DownloadPath
}