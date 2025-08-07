# Function to download the latest Zimmerman Tools and put them in path with chocolatey bins.
# Also updates kape & bins
function Get-KapeAndTools {
  [CmdletBinding()]
  param(

  )
  # --- dynamically import helper cmdlets ----------------------------
  $neededcmdlets = @('Install-Dependencies', 'Get-FileDownload', 'Invoke-AriaDownload', 'Get-LongName', 'Write-Logg', 'Get-LatestGitHubRelease')
  if (-not (Get-Command Install-Cmdlet -EA SilentlyContinue)) {
    $script = Invoke-RestMethod -Uri 'https://raw.githubusercontent.com/Donovoi/PowerShell-Profile/main/functions/Install-Cmdlet.ps1'
    $sb = [ScriptBlock]::Create($script + "`nExport-ModuleMember -Function * -Alias *")
    New-Module -Name InstallCmdlet -ScriptBlock $sb | Import-Module
  }

  foreach ($cmd in $neededCmdlets) {
    Write-Verbose "Importing cmdlet: $cmd"
    $result = Install-Cmdlet -RepositoryCmdlets $cmd -Force -PreferLocal
    if (-not $result) {
      Write-Verbose "result for $cmd is empty, assuming it is imported"
      continue
    }
    switch ($result.GetType().Name) {
      'ScriptBlock' {
        New-Module -Name "Dynamic_$cmd" -ScriptBlock $result | Import-Module -Force -Global
      }
      'FileInfo' {
        Import-Module -Name $result -Force -Global
      }
      'String' {
        $sb = [ScriptBlock]::Create($result + "`nExport-ModuleMember -Function * -Alias *"); New-Module -Name $cmd -ScriptBlock $sb | Import-Module
      }
      default {
        if (-not [string]::IsNullOrWhiteSpace($result)) {
          Write-Warning "Unexpected return type for $cmd`: $($result.GetType())"
        }
      }
    }
  }
  Write-Logg -Message "Script is running as $($MyInvocation.MyCommand.Name)" -level info
  $XWAYSUSB = (Get-CimInstance -ClassName Win32_Volume -Filter "Label LIKE 'X-Ways%'").DriveLetter
  $ENV:ChocolateyInstall = $(Join-Path -Path "$XWAYSUSB" -ChildPath '\chocolatey apps\chocolatey\bin')

  # We need to resolve $xwaysusb so we can tell if the root is $xwaysus\root or $xwaysusb\*\root
  $XWAYSUSBtriagefolder = ''

  if (-not (Resolve-Path -Path $XWAYSUSB\Triage -ErrorAction SilentlyContinue)) {
    $XWAYSUSBtriagefolder = Resolve-Path -Path $XWAYSUSB\*\Triage
  }
  else {
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
  Start-Process -FilePath 'pwsh.exe' -ArgumentList '-NoProfile -NoExit -File', "$(Resolve-Path -Path $KapeAncillaryUpdater)", '-silent' -Wait

  # After all is done copy the KAPE folder to my fast usb
  $fastusb = (Get-CimInstance -ClassName Win32_Volume -Filter "Label LIKE 'ventoy'").DriveLetter

  $params = @{
    Path        = "$XWAYSUSBtriagefolder\kape\"
    Destination = "$fastusb\triage\"

    Recurse     = $true
    Force       = $true
    ErrorAction = 'Continue'
    Verbose     = $true
  }
  Copy-Item @params
  Write-Logg -Message "Successfully copied KAPE folder to $fastusb\triage\kape\" -level info
  Pop-Location
}