# Function to download the latest Zimmerman Tools and put them in path with chocolatey bins.
# Also updates kape & bins
function Get-KapeAndTools {
  [CmdletBinding()]
  param(

  )
  Write-Host -Object "Script is running as $($MyInvocation.MyCommand.Name)" -Verbose
  $Global:XWAYSUSB = (Get-CimInstance -ClassName Win32_Volume -Filter "Label LIKE 'X-Ways%'").DriveLetter


  Remove-Item $(Join-Path -Path "$XWAYSUSB" -ChildPath '\Triage\KAPE\Modules\bin\ZimmermanTools\') -Recurse -Force -ea silentlycontinue
  Remove-Item $(Join-Path -Path "$XWAYSUSB" -ChildPath '\Triage\KAPE\Modules\bin\Get-ZimmermanTools.ps1') -ea silentlycontinue

  Set-Location -Path "$XWAYSUSB\Triage\KAPE\"
  # Get latest version of KAPE-ANCILLARYUpdater.ps1
  $KapeAncillaryUpdater = Get-LatestGitHubRelease -OwnerRepository 'AndrewRathbun/KAPE-EZToolsAncillaryUpdater' -AssetName 'KAPE-EZToolsAncillaryUpdater.ps1'
  & $KapeAncillaryUpdater -Verbose -Quiet 
  $ProgressPreference = 'SilentlyContinue'
  $Global:ENV:ChocolateyInstall = $(Join-Path -Path "$XWAYSUSB" -ChildPath '\chocolatey apps\chocolatey\bin')
  Invoke-WebRequest -Uri 'https://f001.backblazeb2.com/file/EricZimmermanTools/net6/All_6.zip' -OutFile $(Resolve-Path -Path $("$XWAYSUSB" + '\ZimmermanTools.zip')) -Verbose
  Expand-Archive -Path $("$XWAYSUSB" + '\ZimmermanTools.zip') -DestinationPath $("$XWAYSUSB" + '\ZimmermanTools') -Force
  # We now have a a folder with many zip files in it. We need to extract each one to the same folder "$ENV:TEMP\extracted" .
  Get-ChildItem -Path $("$XWAYSUSB" + '\ZimmermanTools') -Filter *.zip -File | ForEach-Object -Process {
    Expand-Archive -Path $_.FullName -DestinationPath $("$XWAYSUSB" + '\ZimmermanTools\extracted') -Force
  }
  # Now we have a folder with all the zimmerman tools in it. We need to copy them to the $ENV:ChocolateyInstall folder, but just the binaries and their dependencies.
  Get-ChildItem -Path $("$XWAYSUSB" + '\ZimmermanTools\extracted') -Recurse | ForEach-Object -Process {
    Copy-Item -Path $_.FullName -Destination $Global:ENV:ChocolateyInstall -Force
  }
}

