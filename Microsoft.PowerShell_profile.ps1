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

# Check if PowerShell 7 is installed
if (-not (Get-Command -Name pwsh -ErrorAction SilentlyContinue)) {
  Write-Host 'PowerShell 7 is not installed. Installing now...' -ForegroundColor Yellow
  # Download and install PowerShell 7 (you might want to check the URL for the latest version)
  winget install powershell

  Write-Host 'PowerShell 7 installed successfully!' -ForegroundColor Green
}

# Check and create profile folders for PowerShell 7
if (-not (Test-Path -Path $powerShell7ProfilePath)) {
  Write-Host 'PowerShell 7 profile folders do not exist. Creating now...' -ForegroundColor Yellow
  New-Item -Path $PROFILE
  Write-Host 'PowerShell 7 profile folders created successfully!' -ForegroundColor Green
}

if ($PSVersionTable.PSVersion.Major -eq 7) {
  $FunctionsFolder = Get-ChildItem -Path "$powerShell7ProfilePath/functions/*.ps*" -Recurse
  $FunctionsFolder.ForEach{ .$_.FullName }
}


# Variables for the commandline
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$vsInstaller = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vs_installer.exe"

# install dependencies for write-log
if (-not (Get-Module -ListAvailable pansies -ErrorAction SilentlyContinue)) {
  Install-Dependencies -PSModule 'pansies' -NoNugetPackages
}

# update package providers

if (-not(Get-Module -ListAvailable AnyPackage -ErrorAction SilentlyContinue)) {
  # PowerShellGet version 2
  Install-Module AnyPackage -AllowClobber -Force -SkipPublisherCheck
}
if (-not(Get-PSResource -Name AnyPackage -ErrorAction SilentlyContinue)) {
  # PowerShellGet version 3
  Install-PSResource AnyPackage
}
Set-Alias -Name reboot -Value Get-NeededReboot -Option AllScope -Description 'Get-NeededReboot'

# install and import modules needed for oh my posh
# I've hardcoded these into the Install-Dependencies function :(
Install-Dependencies -InstallDefaultPSModules -InstallDefaultNugetPackages

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

if ($PSVersionTable.PSVersion -ge [Version]'7.2') {
  Set-PSReadLineOption -PredictionSource HistoryAndPlugin
  Set-PSReadLineOption -PredictionViewStyle ListView
  Set-PSReadLineOption -EditMode Windows
}


# Crazy oh my posh random theme function
function Invoke-OhMyPoshRandomTheme {
  # Get a list of all available Oh My Posh themes
  # check if folder exists
  if (Test-Path "$ENV:USERPROFILE\AppData\Local\Programs\oh-my-posh\themes") {
    $themes = Get-ChildItem "$ENV:USERPROFILE\AppData\Local\Programs\oh-my-posh\themes" -Filter '*.omp.json'
  }
  else {

    $themes = Get-PoshThemes

  }
  # Select a random theme
  $theme = Get-Random -InputObject $themes

  # Initialize Oh My Posh with the random theme
  oh-my-posh init pwsh --config $theme.FullName | Invoke-Expression
}

Invoke-OhMyPoshRandomTheme

# This is an example of a macro that you might use to execute a command.
# This will add the command to history.
Set-PSReadLineKeyHandler -Key Ctrl+Shift+b `
  -BriefDescription BuildCurrentDirectory `
  -LongDescription 'Build the current directory' `
  -ScriptBlock {
  [Microsoft.PowerShell.PSConsoleReadLine]::RevertLine()
  [Microsoft.PowerShell.PSConsoleReadLine]::Insert('dotnet build')
  [Microsoft.PowerShell.PSConsoleReadLine]::AcceptLine()
}

Set-PSReadLineKeyHandler -Key Ctrl+Shift+t `
  -BriefDescription BuildCurrentDirectory `
  -LongDescription 'Build the current directory' `
  -ScriptBlock {
  [Microsoft.PowerShell.PSConsoleReadLine]::RevertLine()
  [Microsoft.PowerShell.PSConsoleReadLine]::Insert('dotnet test')
  [Microsoft.PowerShell.PSConsoleReadLine]::AcceptLine()
}

# Import the Chocolatey Profile that contains the necessary code to enable
# tab-completions to function for `choco`.
# Be aware that if you are missing these lines from your profile, tab completion
# for `choco` will not function.
# See https://ch0.co/tab-completion for details.
$ChocolateyProfile = "$env:ChocolateyInstall\helpers\chocolateyProfile.psm1"
if (Test-Path ($ChocolateyProfile)) {
  Import-Module "$ChocolateyProfile"
}




