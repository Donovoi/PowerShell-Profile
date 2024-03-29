<#
.SYNOPSIS
This function will download and install any missing VC++ Distributables
#>

function Update-VcRedist {
  [CmdletBinding()]
  param(

  )
  Write-Logg -Message "Script is running as $($MyInvocation.MyCommand.Name)" -level info
  Invoke-RestMethod 'https://api.github.com/repos/abbodi1406/vcredist/releases/latest' | ForEach-Object assets | Where-Object name -Like "*VisualCppRedist_AIO_x86_x64*.exe" | ForEach-Object {
    Invoke-WebRequest $_.browser_download_url -OutFile $_.name
    # Run the installer
    Start-Process -FilePath $_.name -ArgumentList "/y" -Wait -NoNewWindow
  }




}

