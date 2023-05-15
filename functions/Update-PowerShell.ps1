# This cmdlet will check the latest version of powershell and compare it with the currently installed version. If a newer version is available it will be downloaded and installed silently.

function Update-PowerShell {
  [CmdletBinding()]
  param(

  )
  # # First check the latest version of powershell
  # $LatestVersion = Invoke-WebRequest -Uri 'https://api.github.com/repos/PowerShell/PowerShell/releases/latest' -UseBasicParsing | ConvertFrom-Json | Select-Object -ExpandProperty tag_name
  # # Check the currently installed version
  # $CurrentVersion = $PSVersionTable.psversion
  # # Compare the versions
  # if ($LatestVersion -gt $CurrentVersion) {
  #   # If the latest version is newer than the current version, download the latest version
  #   $DownloadURL = Invoke-WebRequest -Uri 'https://api.github.com/repos/PowerShell/PowerShell/releases/latest' -UseBasicParsing | ConvertFrom-Json | Select-Object -ExpandProperty assets | Select-Object -ExpandProperty browser_download_url -First 1
  #   $DownloadPath = "$env:TEMP\PowerShell-$LatestVersion-win-x64.msi"
  #   Invoke-WebRequest -Uri $DownloadURL -OutFile $DownloadPath
  #   # Install the latest version silently
  #   Start-Process -FilePath msiexec.exe -ArgumentList "/i $DownloadPath /quiet /norestart" -Wait
  #   # Remove the installer
  #   Remove-Item $DownloadPath
  # }
  # Write-Output 'PowerShell is up to date'

  winget install microsoft.powershell.preview --force
}

