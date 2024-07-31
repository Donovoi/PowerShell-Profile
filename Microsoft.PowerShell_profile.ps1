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

$neededcmdlets = @('Install-Dependencies', 'Get-FileDownload', 'Invoke-AriaDownload', 'Get-LongName', 'Write-Logg', 'Get-Properties')
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


# Define the profile path
$powerShell7ProfilePath = [System.Environment]::GetFolderPath('MyDocuments') + '\PowerShell'

$FunctionsFolder = Get-ChildItem -Path "$powerShell7ProfilePath/functions/*.ps*" -Recurse
$FunctionsFolder.ForEach{ .$_.FullName }

if (-not (Test-Path -Path 'C:\temp\menger.hlsl')) {
  New-Item -Path 'C:\temp\' -ItemType Directory -Force
  Copy-Item -Path "$powerShell7ProfilePath\non powershell tools\menger.hlsl" -Destination 'C:\temp\menger.hlsl' -Force
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



# install and import modules needed for oh my posh
# I've hardcoded these into the Install-Dependencies function :(
if (-not (Get-Module -ListAvailable Pansies -ErrorAction SilentlyContinue)) {
  Install-Dependencies -InstallDefaultPSModules -NoNugetPackage
}


# Variables for the commandline
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$vsInstaller = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vs_installer.exe"



Set-Alias -Name reboot -Value Get-NeededReboot -Option AllScope -Description 'Get-NeededReboot'

if (Test-Path -Path $XWAYSUSB -ErrorAction SilentlyContinue) {

  # We need to remove chocolatey from the path if it exists

  # Function to remove path entry
  function Remove-PathEntry {
    [CmdletBinding(SupportsShouldProcess)]
    param(
      [Parameter(Mandatory = $true)]
      [string]$pathToRemove,
      [Parameter(Mandatory = $true)]
      [string]$scope
    )
    # Get the current PATH environment variable based on the scope (Machine/User)
    $currentPath = [System.Environment]::GetEnvironmentVariable('Path', $scope)

    # Split the PATH into an array of individual paths
    $pathArray = $currentPath -split ';'

    # Remove the entry if it exists
    if ($PSCmdlet.ShouldProcess($pathToRemove, 'Remove path entry')) {
      $pathArray = $pathArray | Where-Object { $_ -notlike $pathToRemove }
    }

    # Join the array back into a single string with ';' as the separator
    $newPath = ($pathArray -join ';')

    # Set the updated PATH environment variable
    if ($PSCmdlet.ShouldProcess('Set PATH environment variable', 'Set updated PATH environment variable')) {
      [System.Environment]::SetEnvironmentVariable('Path', $newPath, $scope)
    }
  }

  # Remove the Chocolatey path entry from both System and User PATH
  Remove-PathEntry -pathToRemove '*chocolatey*' -scope 'Machine'
  Remove-PathEntry -pathToRemove '*chocolatey*' -scope 'User'
}
else {
  $env:ChocolateyInstall = 'C:\ProgramData\chocolatey\bin'
  if (-not (Test-Path -Path $env:ChocolateyInstall) -or (-not (Get-Command -Name choco -ErrorAction SilentlyContinue))) {
    Write-Logg -Message 'Chocolatey is not installed. Installing now...' -level Warning
    Remove-Item -Path 'C:\ProgramData\chocolatey' -Recurse -Force -ErrorAction SilentlyContinue
    Set-ExecutionPolicy Bypass -Scope Process -Force; [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072; Invoke-Expression ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))
  }
  $env:Path += "$env:ChocolateyInstall;$env:ChocolateyInstall\bin;$env:USERPROFILE\.cargo\bin;"

}

# Add the new path to the environment
$env:ChocolateyInstall = $(Resolve-Path $(Join-Path -Path $XWAYSUSB -ChildPath '*\chocolatey apps\chocolatey\bin')).Path
$nirsoftPath = $(Resolve-Path $(Join-Path -Path $XWAYSUSB -ChildPath '*\NirSoft\NirSoft\x64')).Path
Write-Logg -Message "Adding $env:ChocolateyInstall and $nirsoftPath to the path" -Level Info
Write-Logg -Message "Current path: $env:Path" -Level Info
$env:Path += "$env:ChocolateyInstall;$env:ChocolateyInstall\bin;$nirsoftPath;"
Write-Logg -Message "Current path: $env:Path" -Level Info


if ($host.Name -eq 'ConsoleHost') {
  Import-Module PSReadLine
}

if (-not (Get-Command oh-my-posh -ErrorAction silentlycontinue) -and (-not (Get-Command Get-PoshThemes -ErrorAction silentlycontinue))) {
  winget install JanDeDobbeleer.OhMyPosh
}

#if $Env:ChocolateyInstall is on the c drive do the following
if (Test-Path -Path "$env:ChocolateyInstall\..\helpers\chocolateyProfile.psm1") {
  Import-Module "$env:ChocolateyInstall\..\helpers\chocolateyProfile.psm1"
}
else {
  Import-Module "$env:ChocolateyInstall\helpers\chocolateyProfile.psm1"
}


Update-SessionEnvironment

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




