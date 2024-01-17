function Update-PSProfile {
  [CmdletBinding()]
  param(

  )
  Start-AsAdmin
  Write-Logg -Message "Script is running as $($MyInvocation.MyCommand.Name)" -Level INFO
  # Download my powershell profile install script and run it
  Invoke-Expression (Invoke-WebRequest 'https://gist.githubusercontent.com/Donovoi/5fd319a97c37f987a5bcb8362fe8b7c5/raw')

}

