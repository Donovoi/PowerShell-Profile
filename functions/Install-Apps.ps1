function Install-Apps {

  [CmdletBinding()]
  param(
    [Parameter()]
    [TypeName]
    $AppFile = "../Non PowerShell Tools/Winget Install Resources/winstall-9831.ps1"
  )

  begin {
    # make sure winget is installed
    if (Get-Command winget -ErrorAction SilentlyContinue) {
      Write-Output "Winget is installed"
    }
    else {
      Write-Output "Winget is not installed"
      Write-Output "Installing winget"
      # install winget
      $ProgressPreference = 'Silent'
      Invoke-WebRequest -Uri https://github.com/microsoft/winget-cli/releases/download/v1.3.2691/Microsoft.DesktopAppInstaller_8wekyb3d8bbwe.msixbundle -OutFile .\Microsoft.DesktopAppInstaller_8wekyb3d8bbwe.msixbundle
      Invoke-WebRequest -Uri https://aka.ms/Microsoft.VCLibs.x64.14.00.Desktop.appx -OutFile Microsoft.VCLibs.x64.14.00.Desktop.appx
      Add-AppxPackage Microsoft.VCLibs.x64.14.00.Desktop.appx
      Add-AppxPackage Microsoft.DesktopAppInstaller_8wekyb3d8bbwe.msixbundle
      Write-Output "Winget is now installed"
      Write-Output "Here is some ascii art created by copilot?"
      $AsciiArt = @"
            ██████╗  █████╗ ████████╗███████╗██╗  ██╗███████╗
            ██╔══██╗██╔══██╗╚══██╔══╝██╔════╝██║  ██║██╔════╝
            ██████╔╝███████║   ██║   █████╗  ███████║█████╗
            ██╔══██╗██╔══██║   ██║   ██╔══╝  ██╔══██║██╔══╝
            ██║  ██║██║  ██║   ██║   ███████╗██║  ██║███████╗
            ╚═╝  ╚═╝╚═╝  ╚═╝   ╚═╝   ╚══════╝╚═╝  ╚═╝╚══════╝
"@
      Write-Output $AsciiArt

    }
  }

  process {
    Write-Output "Installing Apps"
    # Remember to install nirsoftlauncher
    # Remember to install flarevm
  }

  end {

  }
}

