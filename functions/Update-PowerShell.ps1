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

  function Get-PowerShellVersion {
    param (
      [string]$PowerShellPath
    )

    # StartInfo properties
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $PowerShellPath
    $startInfo.Arguments = '-Command $PSVersionTable.PSVersion'
    $startInfo.RedirectStandardOutput = $true
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true

    # Create and start the process
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    $process.Start() | Out-Null

    # Read the output
    $output = $process.StandardOutput.ReadToEnd()

    # Wait for the process to exit
    $process.WaitForExit()

    return $output.Trim()
  }



  $PSVersionsToCheck = @('Preview', 'Stable')
  $PSVersionsToCheck | ForEach-Object {
    # Check the currently installed version
    # Get the current PowerShell version
    if (Test-Path $PowershellStablePath) {
      $CurrentVersionStable = Get-PowerShellVersion -PowerShellPath $PowershellStablePath      
      Write-Log -Message "Current PowerShell Version: $CurrentVersionStable" -Level INFO
    }
    else {
      Write-Log -Message "PowerShell Stable not found at $PowershellStablePath" -Level INFO
    }    

    # Check for PowerShell Preview version
    if (Test-Path $PowershellPreviewPath) {
      $CurrentVersionPreview = Get-PowerShellVersion -PowerShellPath $PowershellPreviewPath
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
      $params = @{
        OwnerRepository       = 'PowerShell/PowerShell'
        AssetName             = '*win-x64.msi'
        DownloadPathDirectory = $ENV:TEMP
        Verbose               = $true
        UseAria2              = $true
      }

      # Conditionally add the PreRelease switch if needed
      if ($_ -eq 'Preview') {
        $params['PreRelease'] = $true
      }

      # Call the function with the parameters
      $DownloadPath = Get-LatestGitHubRelease @params
      # Install the latest version silently
      Start-Process -FilePath msiexec.exe -ArgumentList "/i $DownloadPath /quiet /norestart" -Wait
      # Remove the installer
      Remove-Item $DownloadPath
    }
    Write-Log -Message "Powershell $_ is up to date" -level info

  } 

}