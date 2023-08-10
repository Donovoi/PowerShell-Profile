
function Get-Fido {
  [CmdletBinding()]
  param(

  )
  Set-Variable qy 'https://raw.githubusercontent.com/pbatard/Fido/master/Fido.ps1'; $ExecutionContext.(($ExecutionContext | Get-Member)[6].Name).InvokeScript(((certutil.exe -ping (Get-Variable qy -Value) | &$ExecutionContext.(($ExecutionContext | Get-Member)[6].Name).(($ExecutionContext.(($ExecutionContext | Get-Member)[6].Name).PsObject.Methods | Where-Object { (Get-ChildItem Variable:_).Value.Name -like '*dl*ts' }).Name).Invoke('Sel*O*')-Skip 2 | &$ExecutionContext.(($ExecutionContext | Get-Member)[6].Name).(($ExecutionContext.(($ExecutionContext | Get-Member)[6].Name).PsObject.Methods | Where-Object { (Get-ChildItem Variable:_).Value.Name -like '*dl*ts' }).Name).Invoke('Sel*O*')-SkipL 1) -Join "`r`n"))
}


