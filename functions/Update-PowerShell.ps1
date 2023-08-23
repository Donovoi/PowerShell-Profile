# This cmdlet will check the latest version of powershell and compare it with the currently installed version. If a newer version is available it will be downloaded and installed silently.

function Update-PowerShell {
  [CmdletBinding()]
  param (
    [Parameter()]
    [string]
    $PowershellStablePath = 'C:\Program Files\PowerShell\7\pwsh.exe',
    [Parameter()]
    [string]
    $PowershellPreviewPath = 'C:\Program Files\PowerShell\7-preview\pwsh.exe'
  )
  

  Write-Log -Message "Script is running as $($MyInvocation.MyCommand.Name)" -level info
  $PSVersionsToCheck = @('Preview', 'Stable')
  $PSVersionsToCheck | ForEach-Object {
    # Check the currently installed version
    # Get the current PowerShell version
    if (Test-Path $PowershellStablePath) {
      $CurrentVersionStable = & $PowershellStablePath -Command { $PSVersionTable.PSVersion }
      Write-Log -Message "Current PowerShell Version: $CurrentVersionStable" -Level INFO
    }
    else {
      Write-Log -Message "PowerShell Stable not found at $PowershellStablePath" -Level INFO
    }    

    # Check for PowerShell Preview version
    if (Test-Path $PowershellPreviewPath) {
      $CurrentVersionPreview = & $PowershellPreviewPath -Command { $PSVersionTable.PSVersion }
      Write-Log -Message "PowerShell Preview Version: $previewVersion" -Level INFO
    }
    else {
      Write-Log -Message "PowerShell Preview not found at $CurrentVersionPreview" -Level INFO
    }

    $UpdatePreview = $false
    $UpdateStable = $false
    # First check the latest version of powershell
    if ($_ -eq 'Preview') {
      $LatestVersionPreview = Get-LatestGitHubRelease -OwnerRepository 'PowerShell/PowerShell' -VersionOnly -PreRelease
      # compare the versions
      if ($LatestVersionPreview -gt $CurrentVersionPreview) {
        
        $script:UpdatePreview = $true
        return
      }

    }
    elseif ($_ -eq 'Stable') {
      $LatestVersionStable = Get-LatestGitHubRelease -OwnerRepository 'PowerShell/PowerShell' -VersionOnly 
      if ($LatestVersionStable -gt $CurrentVersionStable) {
        $script:UpdateStable = $true
      }
    } 


    # Compare the versions
    if ($script:UpdatePreview -or $script:UpdateStable) {
      # If the latest version is newer than the current version, download the latest version
      $DownloadPath = Get-LatestGitHubRelease -OwnerRepository 'PowerShell/PowerShell' $(if ($_ -eq 'Preview') {
          -PreRelease
        } ) -AssetName '*win-x64.msi' -DownloadPathDirectory $ENV:TEMP -Verbose -UseAria2  
      # Install the latest version silently
      Start-Process -FilePath msiexec.exe -ArgumentList "/i $DownloadPath /quiet /norestart" -Wait
      # Remove the installer
      Remove-Item $DownloadPath
    }
    Write-Log -Message "Powershell $_ is up to date" -level info

  } 


}