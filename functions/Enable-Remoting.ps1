#Short script to enable psremoting
function Enable-Remoting {
  [CmdletBinding()]
  param(
    [Parameter(mandatory = $true)]
    [String[]]$Computer
  )

  #Ask the user for their AD credentials
  $PSCreds = Get-Credential -Message 'Enter your AD credentials'

  # ASk the user for the path to the psexec.exe we wil bring up a file browser dialoag for them
  Add-Type -AssemblyName System.Windows.Forms
  $FileBrowser = New-Object System.Windows.Forms.OpenFileDialog -Property @{ InitialDirectory = [Environment]::GetFolderPath('Desktop') }
  $FileBrowser.Title = 'Select the psexec exe'
  $null = $FileBrowser.ShowDialog()
  $psexec = $FileBrowser.FileName

  #Loop through each computer
  foreach ($Comp in $Computer) {
    Write-Host "Enabling Remoting on $Comp" -ForegroundColor Cyan
    Write-Host 'Enabling WINRM Quickconfig' -ForegroundColor Green
    Start-Process -FilePath $psexec -ArgumentList "-accepteula \\$Comp -u $($PSCreds.UserName) -p $($PSCreds.GetNetworkCredential().Password) -h -d winrm.cmd quickconfig -q"
    Write-Host 'Waiting for 60 Seconds.......' -ForegroundColor Yellow
    Start-Sleep -Seconds 60 -Verbose
    Start-Process -FilePath $psexec -ArgumentList "\\$Comp -u $($PSCreds.UserName) -p $($PSCreds.GetNetworkCredential().Password) -h -d powershell.exe enable-psremoting -force"
    Write-Host 'Enabling PSRemoting' -ForegroundColor Green
    Start-Process -FilePath $psexec -ArgumentList "\\$Comp -u $($PSCreds.UserName) -p $($PSCreds.GetNetworkCredential().Password) -h -d powershell.exe set-executionpolicy Bypass -force"
    Write-Host 'Enabling Execution Policy' -ForegroundColor Green
    Test-WSMan -ComputerName $Comp
  }
}
