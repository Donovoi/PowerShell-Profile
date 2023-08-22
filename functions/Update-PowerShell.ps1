# This cmdlet will check the latest version of powershell and compare it with the currently installed version. If a newer version is available it will be downloaded and installed silently.

function Update-PowerShell {
  [CmdletBinding()]
  param(

  )
  . (Join-Path -Path "$PSSCRIPTROOT" -ChildPath 'Get-LatestGitHubRelease.ps1')
    Write-Log -Message "Script is running as $($MyInvocation.MyCommand.Name)" -level info
  # First check the latest version of powershell
  $LatestVersion = Invoke-WebRequest -Uri 'https://api.github.com/repos/PowerShell/PowerShell/releases/latest' -UseBasicParsing | ConvertFrom-Json | Select-Object -ExpandProperty tag_name
  # Check the currently installed version
  $CurrentVersion = $PSVersionTable.psversion
  # Compare the versions
  if ($LatestVersion -gt $CurrentVersion) {
    # If the latest version is newer than the current version, download the latest version
    $DownloadPath = Get-LatestGitHubRelease -OwnerRepository 'PowerShell/PowerShell' -AssetName '*win-x64.msi' -DownloadPathDirectory $ENV:TEMP -Verbose    
    # Install the latest version silently
    Start-Process -FilePath msiexec.exe -ArgumentList "/i $DownloadPath /quiet /norestart" -Wait
    # Remove the installer
    Remove-Item $DownloadPath
  }
  Write-Output 'PowerShell is up to date'

  #Update preview via winget
  winget install microsoft.powershell.preview --force
  
}
