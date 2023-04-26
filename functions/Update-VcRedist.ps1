<#
.SYNOPSIS
This function will download and install any missing VC++ Distributables
.EXAMPLE
Update-VcRedist -DownloadDirectory "C:\temp";
#>

function Update-VcRedist {
  [CmdletBinding()]
  param(
    [string][Parameter(Mandatory = $false)] $DownloadDirectory = "$ENV:USERPROFILE\Downloads"
  )

  # Download the installer
  Invoke-WebRequest -Uri "https://github.com/abbodi1406/vcredist/releases/latest/download/VisualCppRedist_AIO_x86_x64_71.zip" -OutFile "$DownloadDirectory\VisualCppRedist_AIO_x86_x64_69.zip"

  # Extract the installer
  Expand-Archive -Path "$DownloadDirectory\VisualCppRedist_AIO_x86_x64_69.zip" -DestinationPath "$DownloadDirectory\VisualCppRedist_AIO_x86_x64_69" -Force

  # Run the installer
  Start-Process -FilePath "$DownloadDirectory\VisualCppRedist_AIO_x86_x64_69\VisualCppRedist_AIO_x86_x64.exe" -ArgumentList "/y" -Wait -NoNewWindow

}

