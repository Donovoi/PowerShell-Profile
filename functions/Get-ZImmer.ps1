# Function to download the latest Zimmerman Tools and put them in path with chocolatey bins.
# Also updates kape & bins
function Get-Zimmer {
  [CmdletBinding()]
  param(

  )

  $Global:XWAYSUSB = (Get-CimInstance -ClassName Win32_Volume -Filter "Label LIKE 'X-Ways%'").DriveLetter


  Remove-Item $("$XWAYSUSB" + "\Triage\KAPE\Modules\bin\ZimmermanTools\") -Recurse -Force -ea silentlycontinue
  Remove-Item $("$XWAYSUSB" + "\Triage\KAPE\Modules\bin\Get-ZimmermanTools.ps1") -ea silentlycontinue

  & "$XWAYSUSB\Triage\KAPE\KAPE-EZToolsAncillaryUpdater.ps1" -netVersion 6
  $ProgressPreference = 'SilentlyContinue'
  $Global:ENV:ChocolateyInstall = $("$XWAYSUSB" + "\chocolatey apps\chocolatey\bin")
  Invoke-WebRequest -Uri 'https://f001.backblazeb2.com/file/EricZimmermanTools/net6/All_6.zip' -OutFile $(Resolve-Path -Path $("$XWAYSUSB" + "\ZimmermanTools.zip")) -Verbose
  Expand-Archive -Path $("$XWAYSUSB" + "\ZimmermanTools.zip") -DestinationPath $("$XWAYSUSB" + "\ZimmermanTools") -Force
  # We now have a a folder with many zip files in it. We need to extract each one to the same folder "$ENV:TEMP\extracted" .
  Get-ChildItem -Path $("$XWAYSUSB" + "\ZimmermanTools") -Filter *.zip -File | ForEach-Object -Process {
    Expand-Archive -Path $_.FullName -DestinationPath $("$XWAYSUSB" + "\ZimmermanTools\extracted") -Force
  }
  # Now we have a folder with all the zimmerman tools in it. We need to copy them to the $ENV:ChocolateyInstall folder, but just the binaries and their dependencies.
  Get-ChildItem -Path $("$XWAYSUSB" + "\ZimmermanTools\extracted") -Recurse | ForEach-Object -Process {
    Copy-Item -Path $_.FullName -Destination $Global:ENV:ChocolateyInstall -Force
  }
}
