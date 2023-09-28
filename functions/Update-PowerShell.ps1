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

  # Check PowerShell version
  $psVersion = $PSVersionTable.PSVersion.Major

  # Conditional logic for ChildPath based on PS version
  $childPath = if ($psVersion -eq 5.1) {
    'WindowsPowerShell\Microsoft.PowerShell_profile.ps1'
  }
  else {
    'PowerShell\Microsoft.PowerShell_profile.ps1'
  }

  $myDocuments = [Environment]::GetFolderPath('MyDocuments')
  $myProfile = Join-Path -Path $myDocuments -ChildPath $childPath

  if (Test-Path -Path $myProfile) {
    . $myProfile
  }
  else {
    Write-Log -NoConsoleOutput -Message "No PowerShell profile found at $myProfile"
  }

  # Print the name of the running script
  Write-Log -Message "Script is running as $($MyInvocation.MyCommand.Name)"
 
  

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

    if ((-not (Test-Path $PowershellStablePath)) -or (-not (Test-Path $PowershellPreviewPath))) {
      Write-Log -Message "No PowerShell exe found, downloading Powershell $_" -Level INFO 
    }
    else {      
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
    }
  

    # Compare the versions
    if ($script:UpdatePreview -or $script:UpdateStable -or (-not (Test-Path $PowershellStablePath)) -or (-not (Test-Path $PowershellPreviewPath))) {
      # Download the latest and also the greatest only
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