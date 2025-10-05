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

# # install the module called profiler if it is not installed
# if (-not (Get-Module -Name profiler -ListAvailable -ErrorAction SilentlyContinue)) {
#   Install-Module -Name profiler
# }

# $trace = Trace-Script -ScriptBlock { & 'C:\Users\micha\PowerShell-Profile\Microsoft.PowerShell_profile.ps1' } -ExportPath icons

$XWAYSUSB = (Get-CimInstance -ClassName Win32_Volume -Filter "Label LIKE 'X-Ways%'").DriveLetter


# Define the profile path
$powerShell7ProfilePath = [System.Environment]::GetFolderPath('MyDocuments') + '\PowerShell'

# Import all of my functions
$FunctionsFolder = Get-ChildItem -Path "$powerShell7ProfilePath/functions/*.ps*" -Recurse
$FunctionsFolder.ForEach{ .$_.FullName }

# create this file so we can have more contrast in the terminal
if (-not (Test-Path -Path 'C:\temp\Retro.hlsl')) {
  New-Item -Path 'C:\temp\' -ItemType Directory -Force
  Copy-Item -Path "$powerShell7ProfilePath\non powershell tools\Retro.hlsl" -Destination 'C:\temp\Retro.hlsl' -Force
}

# Check if PowerShell 7 is installed
if (-not (Get-Command -Name pwsh -ErrorAction SilentlyContinue)) {
  Write-Logg -Message 'PowerShell 7 is not installed. Installing now...' -Level Warning
  # Download and install PowerShell 7 (you might want to check the URL for the latest version)
  winget install powershell
  Write-Logg -Message 'PowerShell 7 installed successfully!' -Level Info
}

# Check and create profile folders for PowerShell 7
if (-not (Test-Path -Path $powerShell7ProfilePath)) {
  Write-Logg -Message 'PowerShell 7 profile folders do not exist. Creating now...' -Level Warning
  New-Item -Path $PROFILE
  Write-Logg -Message 'PowerShell 7 profile folders created successfully!' -Level Info
}

# Variables for the commandline
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$vsInstaller = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vs_installer.exe"


Set-Alias -Name reboot -Value Get-NeededReboot -Option AllScope -Description 'Get-NeededReboot'

# install oh-my-posh
if (-not (Get-Command oh-my-posh -ErrorAction silentlycontinue)) {
  Uninstall-Module oh-my-posh -AllVersions -ErrorAction SilentlyContinue
  if (-not ([string]::IsNullOrEmpty($env:POSH_PATH))) {
    Remove-Item $env:POSH_PATH -Force -Recurse -ErrorAction SilentlyContinue
  }
  winget install JanDeDobbeleer.OhMyPosh --force
}
# if path does not contain oh-my-posh, add it
if ($env:Path -notcontains '\oh-my-posh\bin') {
  $env:Path += ";$env:LOCALAPPDATA\Programs\oh-my-posh\bin"
}

# Invoke an awesome sample of PSReadline bindings
Invoke-SamplePSReadLineProfile

# Stop PSReadline from auto-completing certain characters
Set-PSReadLineKeyHandler -Key '"' -Function SelfInsert
Set-PSReadLineKeyHandler -Key "'" -Function SelfInsert
Set-PSReadLineKeyHandler -Key '(' -Function SelfInsert
Set-PSReadLineKeyHandler -Key ')' -Function SelfInsert
Set-PSReadLineKeyHandler -Key '{' -Function SelfInsert
Set-PSReadLineKeyHandler -Key '}' -Function SelfInsert
Set-PSReadLineKeyHandler -Key '[' -Function SelfInsert
Set-PSReadLineKeyHandler -Key ']' -Function SelfInsert

# Enable tab completion for tab
Set-PSReadLineKeyHandler -Key Tab -Function Complete

# allow for the use of the arrow keys to navigate through the current line
Set-PSReadLineOption -EditMode Windows


# Crazy oh my posh random theme function
Invoke-OhMyPoshRandomTheme

# $trace.Top50SelfDuration