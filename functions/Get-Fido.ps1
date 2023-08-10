function Get-Fido {
  [CmdletBinding()]
  param()
  
  $scriptUrl = 'https://raw.githubusercontent.com/pbatard/Fido/master/Fido.ps1'
  
  try {
    # Use Invoke-WebRequest to download the script and execute it directly
    Invoke-Command -ScriptBlock ([Scriptblock]::Create((Invoke-WebRequest -Uri $scriptUrl -UseBasicParsing | Select-Object -ExpandProperty Content)))
  }
  catch {
    Write-Error "Failed to download or execute the Fido script: $($_.Exception.Message)"
  }
}
