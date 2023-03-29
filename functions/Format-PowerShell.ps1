function Format-Powershell {
  [CmdletBinding()]
  param(
  )

  # Check if Powershell-Beautifier is installed
  if (-not (Get-InstalledModule -Name Powershell-Beautifier -ErrorAction SilentlyContinue)) {
    # Install NuGet if required
    if (-not (Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue)) {
      Install-PackageProvider -Name NuGet -Scope CurrentUser -Force
    }

    # Install Powershell-Beautifier module
    Install-Module -Name Powershell-Beautifier -Scope CurrentUser -Force
  }

  # Import Powershell-Beautifier module
  Import-Module -Name Powershell-Beautifier

  # Format all PowerShell files recursively
  $fileExtensions = @('*.ps1','*.psm1','*.psd1')
  $powerShellFiles = Get-ChildItem -Path (Get-Item -Path "..\").FullName -Include $fileExtensions -Recurse

  $powerShellFiles | ForEach-Object -Parallel {
    Edit-DTWBeautifyScript -SourcePath $_.FullName -DestinationPath $_.FullName
  }
}
