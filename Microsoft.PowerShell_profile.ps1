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

    # Split the PATH into an array of individual paths and create a HashSet for uniqueness
    $pathSet = [System.Collections.Generic.HashSet[string]]::new($currentPath -split ';')

    # Remove the entry if it exists
    if ($PSCmdlet.ShouldProcess($pathToRemove, 'Remove path entry')) {
      $pathSet.Remove($pathToRemove) | Out-Null
    }

    # Join the HashSet back into a single string with ';' as the separator
    $newPath = ($pathSet -join ';')

    # Set the updated PATH environment variable
    if ($PSCmdlet.ShouldProcess('Set PATH environment variable', 'Set updated PATH environment variable')) {
      [System.Environment]::SetEnvironmentVariable('Path', $newPath, $scope)
    }
  }

  # Example usage for removing Chocolatey from both user and machine PATH
  Remove-PathEntry -pathToRemove 'C:\ProgramData\chocolatey\bin' -scope 'Machine'
  Remove-PathEntry -pathToRemove 'C:\ProgramData\chocolatey\bin' -scope 'User'

  # Function to add paths and persist changes
  function Add-Paths {
    param (
      [string]$chocolateyPath,
      [string]$nirsoftPath
    )

    # Update current session PATH
    $env:Path += ";$chocolateyPath;$chocolateyPath\bin;$nirsoftPath"

    # Get current PATH variables
    $currentSystemPath = [System.Environment]::GetEnvironmentVariable('Path', 'Machine')
    $currentUserPath = [System.Environment]::GetEnvironmentVariable('Path', 'User')

    # Create HashSets for uniqueness
    $systemPathSet = [System.Collections.Generic.HashSet[string]]::new($currentSystemPath -split ';')
    $userPathSet = [System.Collections.Generic.HashSet[string]]::new($currentUserPath -split ';')

    # Add new paths
    $systemPathSet.Add("$chocolateyPath") | Out-Null
    $systemPathSet.Add("$chocolateyPath\bin") | Out-Null
    $systemPathSet.Add("$nirsoftPath") | Out-Null

    $userPathSet.Add("$chocolateyPath") | Out-Null
    $userPathSet.Add("$chocolateyPath\bin") | Out-Null
    $userPathSet.Add("$nirsoftPath") | Out-Null

    # Join the HashSets back into single strings with ';' as the separator
    $newSystemPath = ($systemPathSet -join ';')
    $newUserPath = ($userPathSet -join ';')

    # Update registry for system PATH
    [System.Environment]::SetEnvironmentVariable('Path', $newSystemPath, [System.EnvironmentVariableTarget]::Machine)

    # Update registry for user PATH
    [System.Environment]::SetEnvironmentVariable('Path', $newUserPath, [System.EnvironmentVariableTarget]::User)

    # Notify the system of the environment variable change
    $HWND_BROADCAST = [IntPtr]0xffff
    $WM_SETTINGCHANGE = 0x1a
    $result = [UIntPtr]::Zero

    Add-Type -Namespace Win32 -Name NativeMethods -MemberDefinition @'
        [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Auto)]
        public static extern IntPtr SendMessageTimeout(
            IntPtr hWnd, uint Msg, UIntPtr wParam, string lParam,
            uint fuFlags, uint uTimeout, out UIntPtr lpdwResult);
'@

  $null =  [Win32.NativeMethods]::SendMessageTimeout($HWND_BROADCAST, $WM_SETTINGCHANGE, [UIntPtr]::Zero, 'Environment', 2, 5000, [ref]$result) | Out-Null
  }

  # Define paths
  $chocolateyPath = (Resolve-Path (Join-Path -Path $XWAYSUSB -ChildPath '*\chocolatey apps\chocolatey\bin')).Path
  $nirsoftPath = (Resolve-Path (Join-Path -Path $XWAYSUSB -ChildPath '*\NirSoft\NirSoft\x64')).Path

  # Add paths and persist changes
  Add-Paths -chocolateyPath $chocolateyPath -nirsoftPath $nirsoftPath


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




