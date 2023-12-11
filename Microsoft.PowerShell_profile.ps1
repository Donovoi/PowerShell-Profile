<#
.SYNOPSIS
  MY POWERSHELL PROFILE!!!!
.NOTES
  INSTALL THIS PROFILE BY RUNNING THE FOLLOWING COMMAND:
IEX (iwr https://gist.githubusercontent.com/Donovoi/5fd319a97c37f987a5bcb8362fe8b7c5/raw)

#>
using namespace System.Management.Automation
using namespace System.Management.Automation.Language
$ErrorActionPreference = 'continue'
$XWAYSUSB = (Get-CimInstance -ClassName Win32_Volume -Filter "Label LIKE 'X-Ways%'").DriveLetter

# Define the profile path
$powerShell7ProfilePath = [System.Environment]::GetFolderPath('MyDocuments') + '\PowerShell'

$FunctionsFolder = Get-ChildItem -Path "$powerShell7ProfilePath/functions/*.ps*" -Recurse
$FunctionsFolder.ForEach{ .$_.FullName }

# Check if 'write-logg' is available
if (-not (Get-Command 'write-logg' -ErrorAction SilentlyContinue)) {
  # Define 'write-logg' as a fallback function
  function write-logg {
    param(
      [string]$message,
      [string]$level
    )
    # Map 'write-logg' level to 'Write-Host' color
    switch ($level) {
      'error' {
        $color = 'Red'
      }
      'warning' {
        $color = 'Yellow'
      }
      'info' {
        $color = 'Green'
      }
      default {
        $color = 'White'
      }
    }
    # Call Write-Host with the mapped color and message
    Write-Host $message -ForegroundColor $color
  }
}

# Check if PowerShell 7 is installed
if (-not (Get-Command -Name pwsh -ErrorAction SilentlyContinue)) {
  Write-Logg -Message 'PowerShell 7 is not installed. Installing now...' -Level Warning
  # Download and install PowerShell 7 (you might want to check the URL for the latest version)
  winget install powershell

  Write-Host 'PowerShell 7 installed successfully!' -ForegroundColor Green
}

# Check and create profile folders for PowerShell 7
if (-not (Test-Path -Path $powerShell7ProfilePath)) {
  Write-Logg -Message 'PowerShell 7 profile folders do not exist. Creating now...' -Level Warning
  New-Item -Path $PROFILE
  Write-Logg -Message 'PowerShell 7 profile folders created successfully!' -ForegroundColor Green
}



# install and import modules needed for oh my posh
# I've hardcoded these into the Install-Dependencies function :(
if (-not (Get-Module -ListAvailable Pansies -ErrorAction SilentlyContinue)) {
  Install-Dependencies -InstallDefaultPSModules -InstallDefaultNugetPackages
}


# Variables for the commandline
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$vsInstaller = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vs_installer.exe"



Set-Alias -Name reboot -Value Get-NeededReboot -Option AllScope -Description 'Get-NeededReboot'

$env:ChocolateyInstall = Join-Path -Path $XWAYSUSB -ChildPath '\chocolatey apps\chocolatey\bin\'
$env:Path += ";$env:ChocolateyInstall;$XWAYSUSB\chocolatey apps\chocolatey\bin\bin;$XWAYSUSB\NirSoft\NirSoft\x64;$ENV:USERPROFILE\.cargo\bin;"
if ($host.Name -eq 'ConsoleHost') {
  Import-Module PSReadLine
}

if (-not (Get-Command choco -ErrorAction SilentlyContinue)) {
  Remove-Item -Path 'C:\ProgramData\chocolatey' -Recurse -Force -ErrorAction SilentlyContinue
  Set-ExecutionPolicy Bypass -Scope Process -Force; [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072; Invoke-Expression ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))
}

if (-not (Get-Command oh-my-posh -ErrorAction silentlycontinue) -and (-not (Get-Command Get-PoshThemes -ErrorAction silentlycontinue))) {
  winget install JanDeDobbeleer.OhMyPosh
}

# Invoke an awesome sample of PSReadline bindings
Invoke-SamplePSReadLineProfile

# Crazy oh my posh random theme function
Invoke-OhMyPoshRandomTheme


# Import the Chocolatey Profile that contains the necessary code to enable
# tab-completions to function for `choco`.
# Be aware that if you are missing these lines from your profile, tab completion
# for `choco` will not function.
# See https://ch0.co/tab-completion for details.
$ChocolateyProfile = "$env:ChocolateyInstall\helpers\chocolateyProfile.psm1"
if (Test-Path ($ChocolateyProfile)) {
  Import-Module "$ChocolateyProfile"
}




