#requires -Version 7.0
# Startup configures installed tools. Installers run only when explicitly invoked.
using namespace System.Management.Automation
using namespace System.Management.Automation.Language

$documentsPowerShellProfilePath = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'PowerShell'
$powerShell7ProfilePath = @($PSScriptRoot, $documentsPowerShellProfilePath) |
  Where-Object { $_ -and (Test-Path -LiteralPath (Join-Path $_ 'functions') -PathType Container) } |
  Select-Object -First 1

if ($powerShell7ProfilePath) {
  # Aggregate compatibility files remain usable directly; startup loads canonical files once.
  $excludedFunctionFiles = @('Invoke-Whispercpp-SDL2-BACKUP.ps1', 'cmatrix.ps1', 'PSReflect.ps1', 'Copy-FileSystemUtilities.ps1')
  foreach ($functionFile in (Get-ChildItem -LiteralPath (Join-Path $powerShell7ProfilePath 'functions') -Filter '*.ps1' -File -Recurse | Sort-Object FullName)) {
    if ($functionFile.Name -in $excludedFunctionFiles) { continue }
    try { . $functionFile.FullName }
    catch { Write-Warning "Could not load '$($functionFile.FullName)': $($_.Exception.Message)" }
  }
  $moduleDirectory = Join-Path $powerShell7ProfilePath 'Modules'
  if (Test-Path -LiteralPath $moduleDirectory -PathType Container) {
    foreach ($moduleFile in (Get-ChildItem -LiteralPath $moduleDirectory -Filter '*.psd1' -File -Recurse | Sort-Object FullName)) {
      try { Import-Module -Name $moduleFile.FullName -ErrorAction Stop }
      catch { Write-Warning "Could not import '$($moduleFile.FullName)': $($_.Exception.Message)" }
    }
  }
}
else { Write-Warning 'Profile functions directory was not found.' }

try { $XWAYSUSB = (Get-CimInstance -ClassName Win32_Volume -Filter "Label LIKE 'X-Ways%'" -ErrorAction Stop).DriveLetter }
catch { Write-Verbose "X-Ways volume discovery failed: $($_.Exception.Message)" }
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$vsInstaller = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vs_installer.exe"
Set-Alias -Name reboot -Value Get-NeededReboot -Option AllScope -Description 'Get-NeededReboot'

if ($Host.Name -eq 'ConsoleHost' -and -not [Console]::IsInputRedirected -and
    (Get-Command Initialize-ProfileAppearance -ErrorAction Ignore)) {
  Initialize-ProfileAppearance
}
