#requires -Version 7.2
[CmdletBinding()]
param([Parameter(Mandatory)][string]$TestRoot)
$ErrorActionPreference='Stop'
$TestRoot=$ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($TestRoot)
if(Test-Path -LiteralPath $TestRoot){throw 'Use a new TestRoot.'}
$null=[IO.Directory]::CreateDirectory($TestRoot)
$repo=Split-Path $PSScriptRoot -Parent
. (Join-Path $repo 'scripts/ExecutableAnalysis/New-AnalysisWindowsPayload.ps1')
. (Join-Path $repo 'scripts/ExecutableAnalysis/New-AnalysisWindowsPackageInput.ps1')
function Assert-True([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message}}
function Assert-Exception([scriptblock]$Action,[string]$Pattern){$message=$null;try{& $Action}catch{$message=$_.Exception.Message};Assert-True ($message -match $Pattern) ('Expected refusal: '+$Pattern+'; actual: '+$message)}
function New-FixtureZip([string]$Name,[object[]]$Entries){
    $path=Join-Path $TestRoot ($Name+'.msix')
    $stream=[IO.File]::Open($path,'CreateNew','Write','None');$zip=[IO.Compression.ZipArchive]::new($stream,[IO.Compression.ZipArchiveMode]::Create,$true)
    try{foreach($item in $Entries){$entry=$zip.CreateEntry($item.Name,[IO.Compression.CompressionLevel]::NoCompression);if($item.PSObject.Properties['ExternalAttributes']){$entry.ExternalAttributes=$item.ExternalAttributes};$writer=$entry.Open();try{$writer.Write($item.Bytes,0,$item.Bytes.Length)}finally{$writer.Dispose()}}}finally{$zip.Dispose();$stream.Dispose()}
    return $path
}
$source=Join-Path $TestRoot 'source';$null=[IO.Directory]::CreateDirectory((Join-Path $source 'resources/@scope'))
[IO.File]::WriteAllBytes((Join-Path $source 'app.exe'),[byte[]]@(77,90,0,1,2,3))
[IO.File]::WriteAllBytes((Join-Path $source 'resources/@scope/data.bin'),[byte[]]@(4,5,6))
$manifest='<Package xmlns="http://schemas.microsoft.com/appx/manifest/foundation/windows10"><Identity Name="Fixture.Sample" Publisher="CN=Fixture" Version="1.0.0.0" ProcessorArchitecture="x64"/><Applications><Application Id="App" Executable="app.exe" EntryPoint="Windows.FullTrustApplication"/></Applications></Package>'
[IO.File]::WriteAllText((Join-Path $source 'AppxManifest.xml'),$manifest)
$payload=New-AnalysisWindowsPayload -InputPath (Join-Path $source 'app.exe') -ApplicationRoot $source -OutputDirectory (Join-Path $TestRoot 'payload')
$license=Join-Path $TestRoot 'license.xml'
$licenseText='<License xmlns="urn:schemas-microsoft-com:windows:store:licensing:ls" ContentID="fixture"><Binding><PFM>Fixture.Sample_fake</PFM></Binding></License>'
[IO.File]::WriteAllText($license,$licenseText)
$entries=@($payload.Files|ForEach-Object{[pscustomobject]@{Name=$_.Path.Replace('@','%40');Bytes=[IO.File]::ReadAllBytes((Join-Path $source $_.Path))}})+@([pscustomobject]@{Name='[Content_Types].xml';Bytes=[Text.Encoding]::UTF8.GetBytes('<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"/>')})
$archive=New-FixtureZip 'matching' $entries
$preview=Join-Path $TestRoot 'whatif'
$null=New-AnalysisWindowsPackageInput -PackageArchivePath $archive -PackageLicensePath $license -Payload $payload -OutputDirectory $preview -WhatIf
Assert-True (-not(Test-Path -LiteralPath $preview)) 'WhatIf wrote output.'
$output=Join-Path $TestRoot 'preserved'
$result=New-AnalysisWindowsPackageInput -PackageArchivePath $archive -PackageLicensePath $license -Payload $payload -OutputDirectory $output
Assert-True ($result.Status -eq 'Completed' -and $result.FilesVerified -eq $payload.Files.Count) 'Matching package was not verified.'
Assert-True ($result.Validation.EveryPayloadFileMatched -and -not $result.Validation.SignatureValidated -and -not $result.Validation.LicenseAcceptedByWindows) 'Signature or license acceptance was falsely claimed.'
Assert-True ($result.ContainerOnlyFiles.Count -eq 1 -and $result.ContainerOnlyFiles[0] -ceq '[Content_Types].xml') 'Container-only metadata scope differs.'
Assert-True ($result.ArchiveSHA256 -eq (Get-FileHash -LiteralPath $archive).Hash -and $result.LicenseSHA256 -eq (Get-FileHash -LiteralPath $license).Hash) 'Original hashes differ.'
Assert-True ($result.ArchiveSHA256 -eq (Get-FileHash -LiteralPath $result.ArchivePath).Hash -and $result.LicenseSHA256 -eq (Get-FileHash -LiteralPath $result.LicensePath).Hash) 'Preserved hashes differ.'
Assert-True ((Test-AnalysisWindowsPackageInputSource $result).SourceUnchanged) 'Reusable revalidation failed.'
Assert-True ((Get-Content -LiteralPath $result.ManifestPath -Raw|ConvertFrom-Json).Status -eq 'Completed') 'Complete report not retained.'
Assert-Exception {New-AnalysisWindowsPackageInput $archive $license $payload $output} 'overwrite'
Assert-Exception {New-AnalysisWindowsPackageInput $archive $license $payload (Join-Path $source 'overlap')} 'overlap'
Assert-Exception {New-AnalysisWindowsPackageInput $archive $license $payload (Join-Path $TestRoot 'tiny') -MaxPackageBytes 1} 'byte limit'
Write-Output 'PASS: full matching payload, encoded @ paths, byte preservation, explicit signature limitation, WhatIf and collision/overlap bounds.'

foreach($case in 'Changed','Missing','Extra','Duplicate','CaseCollision','Traversal','EncodedTraversal','EncodedSlash','EncodedBackslash','MalformedEscape','MalformedUtf8','MissingMetadata','MetadataOversize','FileOversize'){
    $modified=@($entries|ForEach-Object{[pscustomobject]@{Name=$_.Name;Bytes=[byte[]]$_.Bytes.Clone()}})
    $target=@($modified|Where-Object Name -ceq 'app.exe')[0]
    switch($case){
        Changed {$target.Bytes[2]=99}
        Missing {$modified=@($modified|Where-Object Name -cne 'app.exe')}
        Extra {$modified+=@([pscustomobject]@{Name='unexpected.bin';Bytes=[byte[]]@(8)})}
        Duplicate {$modified+=@([pscustomobject]@{Name='app.exe';Bytes=$target.Bytes})}
        CaseCollision {$modified+=@([pscustomobject]@{Name='APP.EXE';Bytes=$target.Bytes})}
        Traversal {$target.Name='../app.exe'}
        EncodedTraversal {$target.Name='%2e%2e/app.exe'}
        EncodedSlash {$target.Name='folder%2fapp.exe'}
        EncodedBackslash {$target.Name='folder%5capp.exe'}
        MalformedEscape {$target.Name='app%4.exe'}
        MalformedUtf8 {$target.Name='%C0%AFapp.exe'}
        MissingMetadata {$modified=@($modified|Where-Object Name -cne '[Content_Types].xml')}
        MetadataOversize {@($modified|Where-Object Name -ceq '[Content_Types].xml')[0].Bytes=[byte[]]::new(1MB+1)}
        FileOversize {$target.Bytes=[byte[]]::new(100)}
    }
    $badArchive=New-FixtureZip $case $modified
    Assert-Exception {New-AnalysisWindowsPackageInput $badArchive $license $payload (Join-Path $TestRoot ('output-'+$case))} 'hash differs|missing payload|Unexpected package|Duplicate|reserved|encoded|convert|byte limit|length differs|Unable to translate'
}
Write-Output 'PASS: changed/missing/extra files, duplicate/case collisions, traversal and encoded separators, malformed encodings and per-entry metadata/size limits.'

$badLicense=Join-Path $TestRoot 'bad-license.xml'
[IO.File]::WriteAllText($badLicense,'<!DOCTYPE License [<!ENTITY external SYSTEM "file:///unrelated">]>'+ $licenseText)
Assert-Exception {New-AnalysisWindowsPackageInput $archive $badLicense $payload (Join-Path $TestRoot 'dtd-license')} 'DTD'
[IO.File]::WriteAllText($badLicense,'<License/>')
Assert-Exception {New-AnalysisWindowsPackageInput $archive $badLicense $payload (Join-Path $TestRoot 'wrong-license')} 'unsupported XML'
[IO.File]::WriteAllBytes($badLicense,[byte[]]::new(1MB+1))
Assert-Exception {New-AnalysisWindowsPackageInput $archive $badLicense $payload (Join-Path $TestRoot 'huge-license')} '1 MiB'
$originalLicense=[IO.File]::ReadAllBytes($license)
try{[IO.File]::WriteAllText($license,$licenseText.Replace('fixture','changed'));Assert-Exception {Test-AnalysisWindowsPackageInputSource $result} 'changed'}finally{[IO.File]::WriteAllBytes($license,$originalLicense)}
$originalPreserved=[IO.File]::ReadAllBytes($result.LicensePath)
try{[IO.File]::WriteAllText($result.LicensePath,'changed');Assert-Exception {Test-AnalysisWindowsPackageInputSource $result} 'changed'}finally{[IO.File]::WriteAllBytes($result.LicensePath,$originalPreserved)}
$originalTarget=[IO.File]::ReadAllBytes((Join-Path $source 'app.exe'))
try{[IO.File]::WriteAllBytes((Join-Path $source 'app.exe'),[byte[]]@(0));Assert-Exception {New-AnalysisWindowsPackageInput $archive $license $payload (Join-Path $TestRoot 'changed-source')} 'Source changed'}finally{[IO.File]::WriteAllBytes((Join-Path $source 'app.exe'),$originalTarget)}
$lock=[IO.File]::Open($archive,'Open','ReadWrite','None')
try{Assert-Exception {New-AnalysisWindowsPackageInput $archive $license $payload (Join-Path $TestRoot 'locked-source')} 'being used|process cannot access|permission'}finally{$lock.Dispose()}
Write-Output 'PASS: license DTD/schema/size refusal, original and preserved input mutation, payload source mutation, locked source.'

# A real ZIP whose central directory lies about expanded size must fail during bounded streaming.
$dishonest=New-FixtureZip 'dishonest' (@($entries|ForEach-Object{if($_.Name -ceq 'app.exe'){[pscustomobject]@{Name=$_.Name;Bytes=[byte[]]@(77,90,0,1,2,3,4)}}else{$_}}))
$raw=[IO.File]::ReadAllBytes($dishonest)
for($i=0;$i -lt $raw.Length-46;$i++){
    if([BitConverter]::ToUInt32($raw,$i) -eq 0x02014b50){$nameLength=[BitConverter]::ToUInt16($raw,$i+28);$name=[Text.Encoding]::UTF8.GetString($raw,$i+46,$nameLength);if($name -ceq 'app.exe'){[Array]::Copy([BitConverter]::GetBytes([uint32]6),0,$raw,$i+24,4);break}}
}
[IO.File]::WriteAllBytes($dishonest,$raw)
Assert-Exception {New-AnalysisWindowsPackageInput $dishonest $license $payload (Join-Path $TestRoot 'dishonest-output')} 'byte limit|expanded length'

# Oversized directory count is rejected before ZipArchive loads entries.
$countBomb=New-FixtureZip 'count-bomb' $entries;$raw=[IO.File]::ReadAllBytes($countBomb);$end=$raw.Length-22
[Array]::Copy([BitConverter]::GetBytes([uint16]50001),0,$raw,$end+8,2);[Array]::Copy([BitConverter]::GetBytes([uint16]50001),0,$raw,$end+10,2);[IO.File]::WriteAllBytes($countBomb,$raw)
Assert-Exception {New-AnalysisWindowsPackageInput $countBomb $license $payload (Join-Path $TestRoot 'count-bomb-output')} 'directory exceeds'
Assert-True (-not(Test-Path -LiteralPath (Join-Path $TestRoot 'count-bomb-output'))) 'Directory limit failure created output.'

# Reparse paths are refused without modifying their destinations; use a directory junction.
$junction=Join-Path $TestRoot 'source-junction'
$null=New-Item -ItemType Junction -Path $junction -Target $source -ErrorAction Stop
Assert-Exception {New-AnalysisWindowsPackageInput (Join-Path $junction 'app.exe') $license $payload (Join-Path $TestRoot 'reparse-output')} 'Reparse'
Write-Output 'PASS: dishonest actual expansion, central-directory count bound and reparse-source refusal.'

Assert-True ((ConvertFrom-AnalysisWindowsPackagePartName 'literal%2541.txt') -ceq 'literal%41.txt') 'Part names were decoded more than once.'
Assert-Exception {ConvertFrom-AnalysisWindowsPackagePartName 'resources//'} 'reserved'
$directoryArchive=New-FixtureZip 'directory' ($entries+@([pscustomobject]@{Name='resources/';Bytes=[byte[]]@()}))
$directoryResult=New-AnalysisWindowsPackageInput $directoryArchive $license $payload (Join-Path $TestRoot 'directory-output')
Assert-True ($directoryResult.Validation.DirectoryEntriesVerified -eq 1) 'A matching empty directory was not verified.'
$linkEntries=@($entries|ForEach-Object{[pscustomobject]@{Name=$_.Name;Bytes=$_.Bytes;ExternalAttributes=if($_.Name -ceq 'app.exe'){-1610612736}else{0}}})
$linkArchive=New-FixtureZip 'symlink-entry' $linkEntries
Assert-Exception {New-AnalysisWindowsPackageInput $linkArchive $license $payload (Join-Path $TestRoot 'symlink-entry-output')} 'symbolic-link'

$underCount=New-FixtureZip 'under-count' $entries;$raw=[IO.File]::ReadAllBytes($underCount);$end=$raw.Length-22
[Array]::Copy([BitConverter]::GetBytes([uint16]1),0,$raw,$end+8,2);[Array]::Copy([BitConverter]::GetBytes([uint16]1),0,$raw,$end+10,2);[IO.File]::WriteAllBytes($underCount,$raw)
Assert-Exception {New-AnalysisWindowsPackageInput $underCount $license $payload (Join-Path $TestRoot 'under-count-output')} 'counts disagree'
Assert-True (-not(Test-Path -LiteralPath (Join-Path $TestRoot 'under-count-output'))) 'Dishonest central count created output.'

# The real Codex container uses ZIP64 even though it is smaller than 4 GiB.
$zip64=New-FixtureZip 'zip64' $entries;$raw=[IO.File]::ReadAllBytes($zip64);$end=$raw.Length-22
$oldEnd=[byte[]]$raw[$end..($raw.Length-1)];$zip64Record=[byte[]]::new(56);$locator=[byte[]]::new(20)
[Array]::Copy([BitConverter]::GetBytes([uint32]0x06064b50),0,$zip64Record,0,4)
[Array]::Copy([BitConverter]::GetBytes([uint64]44),0,$zip64Record,4,8)
[Array]::Copy([BitConverter]::GetBytes([uint16]45),0,$zip64Record,12,2);[Array]::Copy([BitConverter]::GetBytes([uint16]45),0,$zip64Record,14,2)
[Array]::Copy([BitConverter]::GetBytes([uint64]$entries.Count),0,$zip64Record,24,8);[Array]::Copy([BitConverter]::GetBytes([uint64]$entries.Count),0,$zip64Record,32,8)
[Array]::Copy([BitConverter]::GetBytes([uint64][BitConverter]::ToUInt32($oldEnd,12)),0,$zip64Record,40,8)
[Array]::Copy([BitConverter]::GetBytes([uint64][BitConverter]::ToUInt32($oldEnd,16)),0,$zip64Record,48,8)
[Array]::Copy([BitConverter]::GetBytes([uint32]0x07064b50),0,$locator,0,4);[Array]::Copy([BitConverter]::GetBytes([uint64]$end),0,$locator,8,8);[Array]::Copy([BitConverter]::GetBytes([uint32]1),0,$locator,16,4)
[Array]::Copy([BitConverter]::GetBytes([uint16]::MaxValue),0,$oldEnd,8,2);[Array]::Copy([BitConverter]::GetBytes([uint16]::MaxValue),0,$oldEnd,10,2)
[Array]::Copy([BitConverter]::GetBytes([uint32]::MaxValue),0,$oldEnd,12,4);[Array]::Copy([BitConverter]::GetBytes([uint32]::MaxValue),0,$oldEnd,16,4)
$zip64Bytes=[byte[]]::new($raw.Length+76);[Array]::Copy($raw,0,$zip64Bytes,0,$end);[Array]::Copy($zip64Record,0,$zip64Bytes,$end,56);[Array]::Copy($locator,0,$zip64Bytes,$end+56,20);[Array]::Copy($oldEnd,0,$zip64Bytes,$end+76,22)
[IO.File]::WriteAllBytes($zip64,$zip64Bytes)
$zip64Result=New-AnalysisWindowsPackageInput $zip64 $license $payload (Join-Path $TestRoot 'zip64-output')
Assert-True ($zip64Result.Status -eq 'Completed' -and $zip64Result.FilesVerified -eq $payload.Files.Count) 'Valid ZIP64 archive failed.'
Write-Output 'PASS: single decoding, known directory entries, symbolic-link metadata refusal, dishonest central counts and ZIP64 compatibility.'

& {
    $hashImplementation=${function:Get-AnalysisWindowsPackageStreamHash};$lockProof=@{Attempted=$false;ArchiveDenied=$false;LicenseDenied=$false}
    function Get-AnalysisWindowsPackageStreamHash {
        param([IO.Stream]$Stream,[long]$MaximumBytes)
        if(-not $lockProof.Attempted){
            $lockProof.Attempted=$true
            try{[IO.File]::WriteAllBytes($archive,[byte[]]@(9))}catch [IO.IOException]{$lockProof.ArchiveDenied=$true}
            try{[IO.File]::WriteAllBytes($license,[byte[]]@(9))}catch [IO.IOException]{$lockProof.LicenseDenied=$true}
        }
        & $hashImplementation -Stream $Stream -MaximumBytes $MaximumBytes
    }
    $lockedResult=New-AnalysisWindowsPackageInput $archive $license $payload (Join-Path $TestRoot 'write-lock-proof')
    Assert-True ($lockedResult.Status -eq 'Completed' -and $lockProof.ArchiveDenied -and $lockProof.LicenseDenied) 'Both original sources were not held against writes during preservation.'
}
Write-Output 'PASS: concurrent write attempts to both source inputs are denied throughout preservation.'
$report=[pscustomobject]@{Status='Passed';FixtureRoot=$TestRoot;TargetExecution=$false;Deployment=$false;SignatureValidation=$false}
$report|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $TestRoot 'result.json') -Encoding utf8
$report|ConvertTo-Json -Compress
