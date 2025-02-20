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

  # We need to resolve $xwaysusb so we can tell if the root is $xwaysus\root or $xwaysusb\*\root
  $XWAYSUSBtriagefolder = ''

  if (-not (Resolve-Path -Path $XWAYSUSB\Triage -ErrorAction SilentlyContinue)) {
    $XWAYSUSBtriagefolder = Resolve-Path -Path $XWAYSUSB\*\Triage
  } else {
    $XWAYSUSBtriagefolder = Join-Path -Path $XWAYSUSB -ChildPath Triage
  }


  Remove-Item $(Join-Path -Path "$XWAYSUSBtriagefolder" -ChildPath '\KAPE\Modules\bin\ZimmermanTools\') -Recurse -Force -ErrorAction silentlycontinue
  Remove-Item $(Join-Path -Path "$XWAYSUSBtriagefolder" -ChildPath '\KAPE\Modules\bin\Get-ZimmermanTools.ps1') -ea silentlycontinue

  $kapeinstalllocation = "$XWAYSUSB\Triage\KAPE\"
  if (-not (Resolve-Path $kapeinstalllocation -ErrorAction SilentlyContinue)) {
    $kapeinstalllocation = "$XWAYSUSB\*\Triage\KAPE\"
  }
  Push-Location -Path $kapeinstalllocation
  # Get latest version of KAPE-ANCILLARYUpdater.ps1
  $params = @{
    OwnerRepository       = 'AndrewRathbun/KAPE-EZToolsAncillaryUpdater'
    AssetName             = 'KAPE-EZToolsAncillaryUpdater.ps1'
    DownloadPathDirectory = "$XWAYSUSBtriagefolder\kape"
    UseAria2              = $true
    NoRPCMode             = $true

  }

  $KapeAncillaryUpdater = Get-LatestGitHubRelease @params
  Start-Process -FilePath 'pwsh.exe' -ArgumentList '-NoProfile -NoExit -File', "$(Resolve-Path -Path $KapeAncillaryUpdater[1])", '-silent' -Wait -NoNewWindow

  # After all is done copy the KAPE folder to my fast usb
  $fastusb = (Get-CimInstance -ClassName Win32_Volume -Filter "Label LIKE 't9'").DriveLetter

  $params = @{
    Path        = "$XWAYSUSBtriagefolder\kape\"
    Destination = "$fastusb\triage\kape\"

    Recurse     = $true
    Force       = $true
    ErrorAction = 'Continue'
    Verbose     = $true
  }
  Copy-Item @params
  Write-Logg -Message "Successfully copied KAPE folder to $fastusb\triage\kape\" -level info
  Pop-Location
}