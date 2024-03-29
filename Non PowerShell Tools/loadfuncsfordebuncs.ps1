# get all files in the current directory except this file and import it as a script
$ActualScriptName = Get-PSCallStack | Select-Object -First 1 -ExpandProperty ScriptName
$ScriptParentPath = Split-Path -Path $(Resolve-Path -Path $($ActualScriptName.foreach{ $_ }) ) -Parent
$scriptstonotimport = @("$($($ActualScriptName.foreach{$_}).split('\')[-1])", "Get-KapeAndTools.ps1", "*RustandFriends*", "*zimmerman*", "*memorycapture*" )
Get-ChildItem -Path $ScriptParentPath -Exclude $scriptstonotimport | ForEach-Object {
    . $_.FullName
}