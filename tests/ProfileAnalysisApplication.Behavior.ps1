#requires -Version 7.2
[CmdletBinding()]
param([Parameter(Mandatory)][string]$TestRoot)
$ErrorActionPreference='Stop'
$TestRoot=$ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($TestRoot)
if(Test-Path -LiteralPath $TestRoot){throw 'Use a new TestRoot.'}
$null=[IO.Directory]::CreateDirectory($TestRoot)
$repo=Split-Path $PSScriptRoot -Parent
. (Join-Path $repo 'scripts/ExecutableAnalysis/Get-AnalysisApplicationContext.ps1')
function Assert-True([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message}}
function Assert-Exception([scriptblock]$Action,[string]$Pattern){$message=$null;try{& $Action}catch{$message=$_.Exception.Message};Assert-True ($message -match $Pattern) ('Expected refusal: '+$Pattern+'; actual: '+$message)}
function New-FixtureFile { [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions','',Justification='Creates disposable fixture files in the required new TestRoot.')][CmdletBinding()][OutputType([string])]param([string]$Path,[byte[]]$Bytes) $null=[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path));[IO.File]::WriteAllBytes($Path,$Bytes);return $Path}
function New-FixtureRun { [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions','',Justification='Creates disposable fixture folders in the required new TestRoot.')][CmdletBinding()][OutputType([string])]param([string]$Name) $path=Join-Path $TestRoot ('runs/'+$Name);$null=[IO.Directory]::CreateDirectory($path);return $path}
function Assert-PreservedFile($Result){
    foreach($file in $Result.PreservedFiles){
        Assert-True ((Get-FileHash -LiteralPath $file.SourcePath -Algorithm SHA256).Hash -eq $file.SHA256) 'Source hash differs from recorded identity.'
        Assert-True ((Get-FileHash -LiteralPath $file.Path -Algorithm SHA256).Hash -eq $file.SHA256) 'Retained hash differs from source.'
        Assert-True ((Get-Item -LiteralPath $file.Path).Length -eq $file.Bytes) 'Retained length changed.'
    }
}
$standalone=New-FixtureFile (Join-Path $TestRoot 'standalone/program.exe') ([byte[]]@(77,90,1,2))
$standaloneRun=New-FixtureRun 'standalone'
$result=Get-AnalysisApplicationContext $standalone $standaloneRun 1MB
Assert-True ($result.Status -eq 'Skipped' -and -not $result.Detected -and -not $result.PreservedFiles.Count) 'Standalone input acquired unrelated context.'
$report=Join-Path $standaloneRun 'basic/application-context.json';$reportHash=(Get-FileHash -LiteralPath $report).Hash
Assert-Exception {Get-AnalysisApplicationContext $standalone $standaloneRun 1MB} 'overwrite'
Assert-True ((Get-FileHash -LiteralPath $report).Hash -eq $reportHash) 'A repeated helper call changed its report.'
Write-Output 'PASS: standalone input is explicitly skipped and an existing context report is never overwritten.'

$package=Join-Path $TestRoot 'package [literal] & name'
$app=Join-Path $package 'app'
$source=New-FixtureFile (Join-Path $app 'launcher [1] & literal.exe') ([byte[]]@(77,90,3,4))
$entry=New-FixtureFile (Join-Path $app 'ChatGPT.exe') ([byte[]]@(77,90,5,6))
$manifestText='<Package xmlns="http://schemas.microsoft.com/appx/manifest/foundation/windows10"><Applications><Application Id="App" Executable="app/ChatGPT.exe" EntryPoint="Windows.FullTrustApplication"/></Applications></Package>'
$null=New-FixtureFile (Join-Path $package 'AppxManifest.xml') ([Text.Encoding]::UTF8.GetBytes($manifestText))
$null=New-FixtureFile (Join-Path $app 'owl-shell-runtime.json') ([Text.Encoding]::UTF8.GetBytes('{"schemaVersion":1,"platform":"win32"}'))
$asar=New-FixtureFile (Join-Path $app 'resources/app.asar') ([Text.Encoding]::UTF8.GetBytes('Opaque candidate; this helper does not parse ASAR.'))
$null=New-FixtureFile ($asar+'.unpacked/nested [x] & y/native.node') ([byte[]](0..31))
$sourceHash=(Get-FileHash -LiteralPath $source).Hash
$run=New-FixtureRun 'package [literal] & result'
$result=Get-AnalysisApplicationContext $source $run 1MB
Assert-True ($result.Status -eq 'Completed' -and $result.Detected) ('Package context did not complete: '+($result.Limitations -join '; '))
Assert-True ($result.ApplicationRoot -eq $app -and $result.PackageRoot -eq $package) 'Application/package roots changed.'
Assert-True ($result.EntryPoints.Count -eq 1 -and $result.EntryPoints[0].SourcePath -eq $entry -and $result.EntryPoints[0].Exists -and -not $result.EntryPoints[0].Preserved) 'Manifest entry point was not identified separately from the launcher.'
Assert-True ($result.PreservedFiles.Count -eq 4) 'Allowed package metadata/ASAR/sidecar coverage changed.'
$retainedAsar=@($result.PreservedFiles|Where-Object Kind -EQ 'AsarCandidate')[0]
Assert-True (Test-Path -LiteralPath ($retainedAsar.Path+'.unpacked/nested [x] & y/native.node')) 'ASAR/unpacked sibling layout was lost.'
Assert-True ((Get-FileHash -LiteralPath $source).Hash -eq $sourceHash) 'Source launcher changed.'
Assert-PreservedFile $result
Write-Output 'PASS: literal package paths, declared application entry point, bounded metadata, opaque ASAR and unpacked layout retain exact bytes and hashes.'

$direct=New-FixtureFile (Join-Path $TestRoot 'direct [asar] & path/example.asar') ([byte[]](1..64))
$null=New-FixtureFile ($direct+'.unpacked/native [x] & file.node') ([byte[]](5..20))
$directRun=New-FixtureRun 'direct reuse'
$inputCopy=New-FixtureFile (Join-Path $directRun 'input/example.asar') ([IO.File]::ReadAllBytes($direct))
$result=Get-AnalysisApplicationContext $direct $directRun 16 -PreservedInputPath $inputCopy
Assert-True ($result.Status -eq 'Completed' -and $result.CopiedBytes -eq 16 -and $result.PreservedFiles.Count -eq 2) 'Reused ASAR spent the companion budget or omitted its sidecar.'
Assert-True (@($result.PreservedFiles|Where-Object ReusedInput).Count -eq 1) 'Existing main input was not reused.'
Assert-True (Test-Path -LiteralPath ($inputCopy+'.unpacked/native [x] & file.node')) 'Direct ASAR sidecar was not placed beside its retained input.'
Assert-PreservedFile $result
$badRun=New-FixtureRun 'wrong preserved identity'
$badCopy=New-FixtureFile (Join-Path $badRun 'input/example.asar') ([byte[]]@(1,2,3))
$badHash=(Get-FileHash -LiteralPath $badCopy).Hash
$bad=Get-AnalysisApplicationContext $direct $badRun 1MB -PreservedInputPath $badCopy
Assert-True ($bad.Status -eq 'Partial' -and ($bad.Limitations -join ' ') -match 'SHA256') 'Wrong reused input identity was accepted.'
Assert-True ((Get-FileHash -LiteralPath $badCopy).Hash -eq $badHash) 'Mismatched input copy was overwritten.'
$sidecarCollisionRun=New-FixtureRun 'reused sidecar collision'
$collisionInput=New-FixtureFile (Join-Path $sidecarCollisionRun 'input/example.asar') ([IO.File]::ReadAllBytes($direct))
$collisionSidecar=New-FixtureFile ($collisionInput+'.unpacked/sentinel') ([byte[]]@(55))
$sidecarCollision=Get-AnalysisApplicationContext $direct $sidecarCollisionRun 1MB -PreservedInputPath $collisionInput
Assert-True ($sidecarCollision.Status -eq 'Partial' -and ($sidecarCollision.Limitations -join ' ') -match 'refusing overwrite') 'An existing reused-input sidecar directory was accepted.'
Assert-True ([IO.File]::ReadAllBytes($collisionSidecar)[0] -eq 55) 'An existing reused-input sidecar was overwritten.'
$outsideRun=New-FixtureRun 'outside preserved path'
$outside=Get-AnalysisApplicationContext $direct $outsideRun 0 -PreservedInputPath $direct
Assert-True ($outside.Status -eq 'Partial' -and ($outside.Limitations -join ' ') -match 'escapes RunDirectory') 'Outside retained input was accepted.'
$packed=New-FixtureFile (Join-Path $TestRoot 'packed-only/app.asar') ([byte[]]@(1,2,3))
$packedResult=Get-AnalysisApplicationContext $packed (New-FixtureRun 'packed only') 20
Assert-True ($packedResult.Status -eq 'Completed' -and ($packedResult.Inventory|Where-Object Status -EQ 'Absent')) 'Absent optional unpacked directory falsely failed a packed candidate.'
Write-Output 'PASS: direct ASAR reuses verified input without charging its bytes, preserves adjacent sidecars, rejects mismatched/outside copies and records optional absent sidecars.'

$budgetRun=New-FixtureRun 'zero budget'
$budget=Get-AnalysisApplicationContext $source $budgetRun 0
Assert-True ($budget.Status -eq 'Partial' -and $budget.CopiedBytes -eq 0 -and $budget.PreservedFiles.Count -eq 0) 'Zero companion budget copied content or hid omissions.'
Assert-True ($budget.EntryPoints.Count -eq 1) 'Bounded metadata could not identify an entry point without copying companions.'
$largeSource=New-FixtureFile (Join-Path $TestRoot 'oversized-meta/app.exe') ([byte[]]@(77,90))
$null=New-FixtureFile (Join-Path ([IO.Path]::GetDirectoryName($largeSource)) 'package.json') ([byte[]]::new(1MB+1))
$large=Get-AnalysisApplicationContext $largeSource (New-FixtureRun 'metadata bound') 2MB
Assert-True ($large.Status -eq 'Partial' -and $large.CopiedBytes -eq 0 -and ($large.Limitations -join ' ') -match '1 MiB') 'Oversized metadata was copied/read without its bound.'
$countSource=New-FixtureFile (Join-Path $TestRoot 'count-bound/app.asar') ([byte[]]@(1))
$countRoot=$countSource+'.unpacked';$null=[IO.Directory]::CreateDirectory($countRoot)
for($index=0;$index -lt 5002;$index++){[IO.File]::WriteAllBytes((Join-Path $countRoot ($index.ToString('D5')+'.node')),([byte[]]@(1)))}
$countResult=Get-AnalysisApplicationContext $countSource (New-FixtureRun 'entry bound') 0
Assert-True ($countResult.Status -eq 'Partial' -and $countResult.Inventory.Count -eq 5000 -and ($countResult.Limitations -join ' ') -match '5,000') 'Unpacked inventory exceeded or concealed its entry bound.'
$depthSource=New-FixtureFile (Join-Path $TestRoot 'depth-bound/app.asar') ([byte[]]@(1))
$deep=$depthSource+'.unpacked';for($index=0;$index -lt 18;$index++){$deep=Join-Path $deep 'nested'}
$null=New-FixtureFile (Join-Path $deep 'beyond.node') ([byte[]]@(7))
$depthResult=Get-AnalysisApplicationContext $depthSource (New-FixtureRun 'depth bound') 1MB
Assert-True ($depthResult.Status -eq 'Partial' -and ($depthResult.Limitations -join ' ') -match 'depth limit' -and @($depthResult.PreservedFiles|Where-Object SourcePath -Like '*beyond.node').Count -eq 0) 'Deep sidecar directory escaped its traversal limit.'
Write-Output 'PASS: zero/total copy budgets, metadata size, 5,000-entry inventory and directory-depth limits remain explicit.'

foreach($case in @('dtd','traversal')){
    $xmlSource=New-FixtureFile (Join-Path $TestRoot ($case+'/app.exe')) ([byte[]]@(77,90))
    $xml=if($case -eq 'dtd'){'<!DOCTYPE Package [<!ENTITY external SYSTEM "file:///must-not-read">]><Package><Applications><Application Executable="&external;"/></Applications></Package>'}else{'<Package><Applications><Application Executable="../outside.exe"/></Applications></Package>'}
    $null=New-FixtureFile (Join-Path ([IO.Path]::GetDirectoryName($xmlSource)) 'AppxManifest.xml') ([Text.Encoding]::UTF8.GetBytes($xml))
    $xmlResult=Get-AnalysisApplicationContext $xmlSource (New-FixtureRun $case) 1MB
    Assert-True ($xmlResult.Status -eq 'Partial') ($case+' XML was accepted.')
    Assert-True (@($xmlResult.EntryPoints|Where-Object Exists).Count -eq 0) ($case+' XML resolved an unsafe executable.')
}
$collisionRun=New-FixtureRun 'output collision'
$sentinel=New-FixtureFile (Join-Path $collisionRun 'application/input/resources/app.asar') ([byte[]]@(99))
Assert-Exception {Get-AnalysisApplicationContext $source $collisionRun 1MB} 'overwrite'
Assert-True ([IO.File]::ReadAllBytes($sentinel)[0] -eq 99) 'Existing companion output was overwritten.'
Write-Output 'PASS: prohibited DTDs, traversal declarations and existing output paths are refused.'

$linkSource=New-FixtureFile (Join-Path $TestRoot 'links/app.asar') ([byte[]]@(1,2))
$linkRoot=$linkSource+'.unpacked';$null=[IO.Directory]::CreateDirectory($linkRoot)
$external=New-FixtureFile (Join-Path $TestRoot 'external fixture/native.node') ([byte[]]@(8,9))
$link=Join-Path $linkRoot 'linked'
$linkAvailable=$false
try{$null=New-Item -ItemType $(if($IsWindows){'Junction'}else{'SymbolicLink'}) -Path $link -Target ([IO.Path]::GetDirectoryName($external));$linkAvailable=$true}catch{Write-Output ('SKIP: link creation is unavailable: '+$_.Exception.Message)}
if($linkAvailable){
    $linked=Get-AnalysisApplicationContext $linkSource (New-FixtureRun 'linked sidecar') 1MB
    Assert-True ($linked.Status -eq 'Partial' -and ($linked.Limitations -join ' ') -match 'Reparse') 'Linked sidecar was not explicitly refused.'
    Assert-True (@($linked.PreservedFiles|Where-Object SourcePath -Like '*native.node').Count -eq 0) 'Linked external content was copied.'
    $linkedSource=Join-Path $link 'native.node'
    $linkedParent=Get-AnalysisApplicationContext $linkedSource (New-FixtureRun 'linked parent') 1MB
    Assert-True ($linkedParent.Status -eq 'Partial' -and -not $linkedParent.PreservedFiles.Count -and ($linkedParent.Limitations -join ' ') -match 'Reparse') 'A linked source ancestor was traversed.'
    $linkedResourcesSource=New-FixtureFile (Join-Path $TestRoot 'linked-resources/app.exe') ([byte[]]@(77,90))
    $externalAsar=New-FixtureFile (Join-Path $TestRoot 'external resources/app.asar') ([byte[]]@(33))
    $null=New-Item -ItemType $(if($IsWindows){'Junction'}else{'SymbolicLink'}) -Path (Join-Path ([IO.Path]::GetDirectoryName($linkedResourcesSource)) 'resources') -Target ([IO.Path]::GetDirectoryName($externalAsar))
    $linkedResources=Get-AnalysisApplicationContext $linkedResourcesSource (New-FixtureRun 'linked candidate parent') 1MB
    Assert-True ($linkedResources.Status -eq 'Partial' -and -not $linkedResources.PreservedFiles.Count -and ($linkedResources.Limitations -join ' ') -match 'Reparse') 'A linked resources directory was traversed to preserve its ASAR.'
    Assert-True (@($linkedResources.Inventory|Where-Object {$_.Kind -eq 'AsarUnpackedDirectory' -and $_.Status -eq 'Absent'}).Count -eq 0) 'A refused sidecar parent was incorrectly labeled absent.'
    Write-Output 'PASS: sidecar directory links and linked source ancestors cannot escape the selected source boundary.'
}
