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
        if(-not $nested){[pscustomobject]@{Name=$definition.Name;File=$file.Name;FullName=$file.FullName}}
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

# Import the real module manifests and every function/filter, without invoking tools.
function Get-CimInstance { [CmdletBinding()]param($ClassName,$Filter) [pscustomobject]@{DriveLetter='X:'} }
function Invoke-WebRequest { throw 'Startup attempted a download.' }
function Invoke-RestMethod { throw 'Startup attempted a download.' }
function Install-Module { throw 'Startup attempted a module installation.' }
function winget { throw 'Startup attempted a package installation.' }
$warnings=@()
$repo=Split-Path $PSScriptRoot -Parent
. (Join-Path $repo 'Microsoft.PowerShell_profile.ps1') -WarningVariable +warnings
$moduleBefore=Get-Module ImageForensics
. (Join-Path $repo 'Microsoft.PowerShell_profile.ps1') -WarningVariable +warnings
if($warnings.Count){throw ('Profile startup warnings: '+($warnings -join '; '))}
foreach($definition in $definitions){
    $command=Get-Command -Name $definition.Name -CommandType Function,Filter -ErrorAction Stop
    if($command.ScriptBlock.File -ne $definition.FullName){throw "Startup did not expose the canonical command '$($definition.Name)'."}
}
if((Get-Command Invoke-DeepfakeScan).Source -ne 'ImageForensics'){throw 'The bundled module export was not imported.'}
if(-not [object]::ReferenceEquals($moduleBefore,(Get-Module ImageForensics))){throw 'Repeated startup recreated the bundled module.'}
if((Get-Alias reboot).Definition -ne 'Get-NeededReboot'){throw 'The reboot alias was lost.'}
if($XWAYSUSB -ne 'X:' -or $vswhere -ne "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe" -or
    $vsInstaller -ne "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vs_installer.exe"){
    throw 'Profile convenience variables changed.'
}
Write-Host "PASS: all $($definitions.Count) commands, real module export, alias and convenience variables survive repeated startup."
