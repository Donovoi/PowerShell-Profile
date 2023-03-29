
function Get-Fido {
  [CmdletBinding()]
  param(

  )
  $scriptFido = Invoke-WebRequest -Uri 'https://raw.githubusercontent.com/pbatard/Fido/master/Fido.ps1' -UseBasicParsing -OutFile $ENV:TEMP\Fido.ps1
  .$scriptFido
}

