<#
.SYNOPSIS
This function will download and install any missing VC++ Distributables
#>

function Update-VcRedist {
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
  Get-LatestGitHubRelease -OwnerRepository 'abbodi1406/vcredist' -AssetName 'VisualCppRedist_AIO_x86_x64' -DownloadPathDirectory $ENV:TEMP -UseAria2 -NoRPCMode
  $installerPath = $(Get-ChildItem -Path "$ENV:TEMP\VisualCppRedist_AIO_x86_x64*" | Sort-Object -Property CreationTime -Descending | Select-Object -First 1).FullName
  # Run the installer
  Start-Process -FilePath $installerPath -ArgumentList '/y' -Wait
}