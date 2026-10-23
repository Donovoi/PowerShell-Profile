#requires -Version 7.0
[CmdletBinding()]
param([Parameter(Mandatory)][string]$TestRoot)
$ErrorActionPreference='Stop'
if(Test-Path -LiteralPath $TestRoot){throw 'Use a new fixture directory.'}
$null=[IO.Directory]::CreateDirectory($TestRoot)
$functions=Join-Path (Split-Path $PSScriptRoot -Parent) functions
$definitions=foreach($file in Get-ChildItem -LiteralPath $functions -Filter '*.ps1' -Recurse -File){
    $parseErrors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$null,[ref]$parseErrors)
    if($parseErrors.Count){throw ($parseErrors -join '; ')}
    foreach($definition in $ast.FindAll({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst]},$true)){
        $nested=$false
        for($parent=$definition.Parent;$parent;$parent=$parent.Parent){
            if($parent -is [Management.Automation.Language.FunctionDefinitionAst] -or $parent -is [Management.Automation.Language.ScriptBlockExpressionAst]){$nested=$true;break}
        }
        if(-not $nested){[pscustomobject]@{Name=$definition.Name;File=$file.Name}}
    }
}
$duplicates=@($definitions|Group-Object Name|Where-Object Count -GT 1)
if($duplicates.Count){throw ('Duplicate public commands: '+(($duplicates|ForEach-Object {$_.Name+': '+($_.Group.File -join ', ')}) -join '; '))}
$definitions|Sort-Object Name|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $TestRoot public-commands.json)
foreach($facade in 'PSReflect','Copy-ForensicArtifact','Copy-FileSystemUtilities','cmatrix'){
    . (Join-Path $functions ($facade+'.ps1'))
}
foreach($name in 'New-InMemoryModule','func','Add-Win32Type','psenum','field','struct','Start-CMatrix','Copy-StandardFile','Copy-LockedFile','Copy-DirectoryRecursive','Copy-FileSystemArtifact','Copy-RegistryArtifact'){
    if(-not(Get-Command $name -ErrorAction SilentlyContinue)){throw "Compatibility command missing: $name"}
}
if((Get-Command Copy-StandardFile).ScriptBlock.File -notlike '*\Copy-StandardFile.ps1'){throw 'Forensic implementation is not canonical.'}
if((Get-Command New-InMemoryModule).ScriptBlock.File -notlike '*\New-InMemoryModule.ps1'){throw 'PSReflect implementation is not canonical.'}
Write-Host "PASS: $($definitions.Count) unique public definitions; compatibility import surfaces resolve to canonical files."
