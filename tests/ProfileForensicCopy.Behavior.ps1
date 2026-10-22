#requires -Version 7.0
[CmdletBinding()]
param([Parameter(Mandatory)][string]$TestRoot)
$ErrorActionPreference='Stop'
if(Test-Path -LiteralPath $TestRoot){throw 'Use a new fixture directory.'}
$null=[IO.Directory]::CreateDirectory("$TestRoot/source/nested")
. "$PSScriptRoot/../functions/Initialize-CmdletDependencies.ps1"
. "$PSScriptRoot/../functions/Copy-ForensicArtifact.ps1"
function Assert($Condition,$Message){if(-not $Condition){throw $Message}}
[IO.File]::WriteAllText("$TestRoot/source/registry.LOG",'log bytes')
[IO.File]::WriteAllText("$TestRoot/source/nested/file[1].txt",'Unicode café bytes')
[IO.File]::WriteAllBytes("$TestRoot/source/empty.bin",[byte[]]::new(0))
$full=Copy-FileSystemArtifact -SourcePath "$TestRoot/source" -DestinationPath "$TestRoot/full"
Assert ($full.Success -and $full.FilesCollected -eq 3 -and $full.FilesFailed -eq 0 -and -not $full.PartialSuccess) 'Full directory copy totals incorrect'
foreach($file in $full.Files){Assert ($file.Verified -and $file.SHA256 -eq (Get-FileHash -LiteralPath $file.Source).Hash -and $file.SHA256 -eq (Get-FileHash -LiteralPath $file.Destination).Hash) 'Missing or incorrect per-file hash'}
Assert ([IO.File]::ReadAllText("$TestRoot/full/source/registry.LOG") -eq 'log bytes') 'LOG file omitted'
$glob=Copy-WildcardPattern -SourcePath "$TestRoot/source/**/*.txt" -DestinationPath "$TestRoot/glob"
Assert ($glob.Success -and [IO.File]::Exists("$TestRoot/glob/nested/file[1].txt")) 'Recursive glob did not preserve relative path'
$literal=Copy-DirectPath -SourcePath "$TestRoot/source/nested/file[1].txt" -DestinationPath "$TestRoot/literal"
Assert ($literal.Success -and $literal.FilesCollected -eq 1) 'Literal brackets were treated as wildcards'
Assert (-not (Copy-FileSystemArtifact -SourcePath "$TestRoot/source" -DestinationPath "$TestRoot/source/recursive-output").Success) 'Output inside source was accepted'
Write-Host 'PASS: directory/glob/literal collection, LOG inclusion, Unicode/empty bytes, hashes and destination containment'

$locked=[IO.File]::Open("$TestRoot/source/registry.LOG",'Open','ReadWrite','None')
try {
    $partial=Copy-FileSystemArtifact -SourcePath "$TestRoot/source" -DestinationPath "$TestRoot/partial"
    Assert (-not $partial.Success -and $partial.PartialSuccess -and $partial.FilesCollected -eq 2 -and $partial.FilesFailed -eq 1 -and $partial.Errors.Count -eq 1) 'Partial copy overstated success'
    [IO.File]::WriteAllText("$TestRoot/old-output",'keep old')
    Assert (-not (Copy-StandardFile -SourceFile "$TestRoot/source/registry.LOG" -DestinationFile "$TestRoot/old-output")) 'Locked stream unexpectedly succeeded'
    Assert ([IO.File]::ReadAllText("$TestRoot/old-output") -eq 'keep old') 'Failed standard copy destroyed old output'
} finally {$locked.Dispose()}
function Fake-RawAcquisition {
    [CmdletBinding(SupportsShouldProcess)] param($Path,$Destination)
    [IO.File]::WriteAllText($Destination,'snapshot bytes')
    [pscustomobject]@{Success=$true;Length=14;SHA256=(Get-FileHash -LiteralPath $Destination).Hash;Method='SnapshotFixture'}
}
$tools=@([pscustomobject]@{Name='Invoke-RawCopy';Path='Fake-RawAcquisition'})
$record=Copy-LockedFile -SourceFile "$TestRoot/source/registry.LOG" -DestinationFile "$TestRoot/raw-result" -ForensicTools $tools -PassThru
Assert ($record.Success -and $record.Verified -and $record.Method -eq 'SnapshotFixture') 'Verified raw acquisition contract rejected'
function Fake-RawAcquisition { [CmdletBinding(SupportsShouldProcess)] param($Path,$Destination) [pscustomobject]@{Success=$true;Length=14;SHA256=('a'*64);Method='BadFixture'} }
$record=Copy-LockedFile -SourceFile "$TestRoot/source/registry.LOG" -DestinationFile "$TestRoot/raw-result" -ForensicTools $tools -PassThru
Assert (-not $record.Success -and [IO.File]::ReadAllText("$TestRoot/raw-result") -eq 'snapshot bytes') 'Stale output was accepted as new acquisition'
Assert (-not (Copy-LockedFile -SourceFile "$TestRoot/source/registry.LOG" -DestinationFile "$TestRoot/raw-result" -ForensicTools @([pscustomobject]@{Name='RawCopy';Path='not-executed'}))) 'Unverified legacy tool was accepted'
. "$PSScriptRoot/../functions/Copy-FileSystemUtilities.ps1"
$again=Copy-FileSystemArtifact -SourcePath "$TestRoot/source/registry.LOG" -DestinationPath "$TestRoot/again"
Assert ($again.Success -and $again.FilesCollected -eq 1) 'Compatibility imports changed collection policy'
Write-Host 'PASS: partial failure counts, locked-file failure preservation, verified acquisition contract, stale-output rejection and import-order consistency'
