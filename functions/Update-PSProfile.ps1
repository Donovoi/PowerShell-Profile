function Update-PSProfile {
  [CmdletBinding()]
  param(

  )
  Start-Process -FilePath pwsh -ArgumentList "-NoProfile -NoExit -Command `"IEX (iwr https://gist.githubusercontent.com/Donovoi/5fd319a97c37f987a5bcb8362fe8b7c5/raw)`"" -Wait

}

