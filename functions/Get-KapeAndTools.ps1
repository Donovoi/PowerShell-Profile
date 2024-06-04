# Function to download the latest Zimmerman Tools and put them in path with chocolatey bins.
# Also updates kape & bins
function Get-KapeAndTools {
  [CmdletBinding()]
  param(

  )
  # Import the required cmdlets
  $neededcmdlets = @('Install-Dependencies', 'Get-FileDownload', 'Invoke-AriaDownload', 'Get-LongName', 'Write-Logg', 'Get-Properties', 'Get-LatestGitHubRelease')
  $neededcmdlets | ForEach-Object {
    if (-not (Get-Command -Name $_ -ErrorAction SilentlyContinue)) {
      if (-not (Get-Command -Name 'Install-Cmdlet' -ErrorAction SilentlyContinue)) {
        $method = Invoke-RestMethod -Uri 'https://raw.githubusercontent.com/Donovoi/PowerShell-Profile/main/functions/Install-Cmdlet.ps1'
        $finalstring = [scriptblock]::Create($method.ToString() + "`nExport-ModuleMember -Function * -Alias *")
        New-Module -Name 'InstallCmdlet' -ScriptBlock $finalstring | Import-Module
      }
      Write-Verbose -Message "Importing cmdlet: $_"
      $Cmdletstoinvoke = Install-Cmdlet -donovoicmdlets $_
      $Cmdletstoinvoke | Import-Module -Force
    }
  }
  Write-Logg -Message "Script is running as $($MyInvocation.MyCommand.Name)" -level info
  $XWAYSUSB = (Get-CimInstance -ClassName Win32_Volume -Filter "Label LIKE 'X-Ways%'").DriveLetter
  $ENV:ChocolateyInstall = $(Join-Path -Path "$XWAYSUSB" -ChildPath '\chocolatey apps\chocolatey\bin')


  Remove-Item $(Join-Path -Path "$XWAYSUSB" -ChildPath '\Triage\KAPE\Modules\bin\ZimmermanTools\') -Recurse -Force -ErrorAction silentlycontinue
  Remove-Item $(Join-Path -Path "$XWAYSUSB" -ChildPath '\Triage\KAPE\Modules\bin\Get-ZimmermanTools.ps1') -ea silentlycontinue

  Set-Location -Path "$XWAYSUSB\Triage\KAPE\"
  # Get latest version of KAPE-ANCILLARYUpdater.ps1
  $params = @{
    OwnerRepository       = 'AndrewRathbun/KAPE-EZToolsAncillaryUpdater'
    AssetName             = 'KAPE-EZToolsAncillaryUpdater.ps1'
    DownloadPathDirectory = "$XWAYSUSB\triage\kape"
    UseAria2              = $true
    NoRPCMode             = $true

  }

  $KapeAncillaryUpdater = Get-LatestGitHubRelease @params
  Start-Process -FilePath 'pwsh.exe' -ArgumentList '-NoProfile -NoExit -File', "$($KapeAncillaryUpdater)", '-silent' -Wait -NoNewWindow

  Get-FileDownload -URL 'https://f001.backblazeb2.com/file/EricZimmermanTools/net6/All_6.zip' -DestinationDirectory "$XWAYSUSB" -UseAria2 -NoRPCMode
  Expand-Archive -Path $("$XWAYSUSB" + 'All_6.zip') -DestinationPath $("$XWAYSUSB" + '\ZimmermanTools') -Force
  # We now have a a folder with many zip files in it. We need to extract each one to the same folder "$ENV:TEMP\extracted" .
  Get-ChildItem -Path $("$XWAYSUSB" + '\ZimmermanTools') -Filter *.zip -File | ForEach-Object -Process {
    Expand-Archive -Path $_.FullName -DestinationPath $("$XWAYSUSB" + '\ZimmermanTools\extracted') -Force
  }
  # Now we have a folder with all the zimmerman tools in it. We need to copy them to the $ENV:ChocolateyInstall folder, but just the binaries and their dependencies.
  Get-ChildItem -Path $("$XWAYSUSB" + '\ZimmermanTools\extracted') -Recurse | ForEach-Object -Process {
    Copy-Item -Path $_.FullName -Destination $ENV:ChocolateyInstall -Force
  }
}

