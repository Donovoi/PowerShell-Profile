# get all files in the current directory except this file and import it as a script
$ActualScriptName = Get-PSCallStack | Select-Object -First 1 -ExpandProperty ScriptName
$ScriptParentPath = Split-Path -Path $(Resolve-Path -Path $($ActualScriptName.foreach{ $_ }) ) -Parent
Get-ChildItem -Path $ScriptParentPath -Filter "*.ps1" -Exclude $(Get-PSCallStack).ScriptName | ForEach-Object {
    . $_.FullName
}