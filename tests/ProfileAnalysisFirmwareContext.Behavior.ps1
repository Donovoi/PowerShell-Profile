#requires -Version 7.2
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$TestRoot,
    [string]$DellSamplePath
)
$ErrorActionPreference='Stop'
$TestRoot=$ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($TestRoot)
if(Test-Path -LiteralPath $TestRoot){throw 'Use a new TestRoot.'}
$null=[IO.Directory]::CreateDirectory($TestRoot)
$repo=Split-Path $PSScriptRoot -Parent
. (Join-Path $repo 'scripts/ExecutableAnalysis/Get-AnalysisFirmwareContext.ps1')
function Assert-True([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message}}
function New-FixtureFile {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions','',Justification='Creates disposable fixture files in the required new TestRoot.')]
    [CmdletBinding()][OutputType([string])]
    param([string]$Name,[byte[]]$Bytes)
    $path=Join-Path $TestRoot $Name
    [IO.File]::WriteAllBytes($path,$Bytes)
    return $path
}
function Set-FixtureXor([byte[]]$Bytes,[int]$Offset){$value=0;for($i=0;$i -lt 15;$i++){$value=$value -bxor $Bytes[$Offset+$i]};$Bytes[$Offset+15]=[byte]$value}

# Independent fixed bytes: Dell header/footer framing around the known zlib
# encoding of an empty stream. This intentionally proves wrapper recognition,
# not the existence of a decompressed PFS/firmware payload.
$wrapper=[Convert]::FromHexString('08000000AAEEAA761BECBB20F1E65100789C03000000000108000000EEAAEE8F491BE8AE14379000')
Set-FixtureXor $wrapper 0
Set-FixtureXor $wrapper 24
$plain=New-FixtureFile 'Dell-BIOS-filename-only.exe' ([Text.Encoding]::UTF8.GetBytes('MZ ordinary executable fixture; no wrapper'))
$result=Get-AnalysisFirmwareContext -SourcePath $plain
Assert-True ($result.Status -eq 'Skipped' -and -not $result.Detected -and -not $result.RequiresStaticOnly -and $result.Limits.ScanComplete) 'Filename alone was treated as firmware.'
$validPath=New-FixtureFile 'literal [1] & firmware.bin' $wrapper
$beforeHash=(Get-FileHash -LiteralPath $validPath).Hash
$beforeWrite=(Get-Item -LiteralPath $validPath).LastWriteTimeUtc
$beforeNames=@(Get-ChildItem -LiteralPath $TestRoot -File | Select-Object -ExpandProperty Name)
$result=Get-AnalysisFirmwareContext -SourcePath $validPath
Assert-True ($result.Status -eq 'Completed' -and $result.Detected -and $result.Kind -eq 'DellPfsZlibWrapper' -and $result.RequiresStaticOnly) 'Valid Dell wrapper was not recognized.'
Assert-True ($result.PayloadRegions.Count -eq 1 -and $result.PayloadRegions[0].HeaderOffset -eq 0 -and $result.PayloadRegions[0].SignatureOffset -eq 5 -and $result.PayloadRegions[0].Offset -eq 16 -and $result.PayloadRegions[0].FooterOffset -eq 24 -and $result.PayloadRegions[0].Length -eq 8) 'Wrapper provenance offsets or compressed length are wrong.'
Assert-True (-not $result.PayloadRegions[0].PayloadValidated -and $result.Scope -eq 'CompressedWrapperOnly' -and ($result.Limitations -join ' ') -match 'menu semantics were not validated') 'Wrapper detection overclaimed payload analysis.'
Assert-True ((Get-FileHash -LiteralPath $validPath).Hash -eq $beforeHash -and (Get-Item -LiteralPath $validPath).LastWriteTimeUtc -eq $beforeWrite) 'Read-only recognition modified its input.'
Assert-True (@(Compare-Object $beforeNames @(Get-ChildItem -LiteralPath $TestRoot -File | Select-Object -ExpandProperty Name)).Count -eq 0) 'Recognition wrote files beside the input.'
Write-Output 'PASS: byte-based Dell wrapper recognition, offsets, explicit payload limitations and read-only behavior.'

$cases=[ordered]@{}
$cases['bare-signature']=$wrapper[5..14]
$cases['truncated-header']=$wrapper[0..14]
$cases['truncated-payload']=$wrapper[0..20]
$cases['truncated-footer']=$wrapper[0..37]
$bytes=$wrapper.Clone();$bytes[15]=$bytes[15] -bxor 1;$cases['bad-header-checksum']=$bytes
$bytes=$wrapper.Clone();$bytes[39]=$bytes[39] -bxor 1;$cases['bad-footer-checksum']=$bytes
$bytes=$wrapper.Clone();$bytes[28]=0;Set-FixtureXor $bytes 24;$cases['fake-footer']=$bytes
$bytes=$wrapper.Clone();$bytes[24]=9;Set-FixtureXor $bytes 24;$cases['length-mismatch']=$bytes
$bytes=$wrapper.Clone();$bytes[16]=0;$cases['fake-zlib-prefix']=$bytes
$bytes=$wrapper.Clone();$bytes[4]=1;Set-FixtureXor $bytes 0;$cases['unknown-section-type']=$bytes
$bytes=$wrapper.Clone();$bytes[0]=0;Set-FixtureXor $bytes 0;$cases['zero-length']=$bytes
$bytes=$wrapper.Clone();[Array]::Copy([byte[]]@(255,255,255,255),0,$bytes,0,4);Set-FixtureXor $bytes 0;$cases['uint32-max-length']=$bytes
foreach($case in $cases.GetEnumerator()){
    $path=New-FixtureFile ($case.Key+'.bin') $case.Value
    $result=Get-AnalysisFirmwareContext -SourcePath $path
    Assert-True ($result.Status -eq 'Partial' -and -not $result.Detected -and $result.Kind -eq 'Unknown' -and $result.RequiresStaticOnly -and $result.CandidateCount -eq 1 -and $result.Candidates[0].Validation -eq 'Rejected') ('Malformed signature was accepted or hidden: '+$case.Key)
}
Write-Output 'PASS: signatures without framing, truncation, wrong checksums, fake footer/zlib prefix, unknown type and unsafe lengths remain Partial/Unknown.'

$offset=1MB-10
$bytes=[byte[]]::new($offset+$wrapper.Length)
[Array]::Copy($wrapper,0,$bytes,$offset,$wrapper.Length)
$crossing=New-FixtureFile 'chunk-boundary.bin' $bytes
$result=Get-AnalysisFirmwareContext -SourcePath $crossing
Assert-True ($result.Detected -and $result.CandidateCount -eq 1 -and $result.PayloadRegions[0].HeaderOffset -eq $offset -and $result.Limits.ScanComplete) 'A signature crossing a chunk boundary was missed or duplicated.'
$result=Get-AnalysisFirmwareContext -SourcePath $crossing -MaxInputBytes 1MB
Assert-True ($result.Status -eq 'Partial' -and -not $result.Detected -and -not $result.Limits.ScanComplete -and $result.RequiresStaticOnly -and $result.Limits.ScannedBytes -eq 1MB -and $result.Limits.ReadBytes -le 1MB) 'Scan budget was exceeded or incomplete coverage was hidden.'
$result=Get-AnalysisFirmwareContext -SourcePath $validPath -MaxInputBytes 20
Assert-True ($result.Status -eq 'Partial' -and -not $result.Detected -and $result.Candidates[0].Reason -match 'scan limit' -and $result.Limits.ReadBytes -eq 38) 'A footer beyond the scan budget was read or accepted.'
$result=Get-AnalysisFirmwareContext -SourcePath $validPath -MaxInputBytes 0
Assert-True ($result.Status -eq 'Partial' -and -not $result.Detected -and $result.Limits.ReadBytes -eq 0 -and $result.RequiresStaticOnly) 'Zero scan budget read content or implied complete inspection.'
$bytes=[byte[]]::new($wrapper.Length*129)
for($i=0;$i -lt 129;$i++){[Array]::Copy($wrapper,0,$bytes,$i*$wrapper.Length,$wrapper.Length)}
$many=New-FixtureFile 'candidate-limit.bin' $bytes
$result=Get-AnalysisFirmwareContext -SourcePath $many
Assert-True ($result.Status -eq 'Partial' -and $result.Detected -and $result.CandidateCount -eq 128 -and $result.Limits.CandidateLimitReached -and -not $result.Limits.ScanComplete -and $result.PayloadRegions.Count -eq 128) 'Candidate cap was exceeded or concealed.'
$bytes=$wrapper.Clone();$bytes[4]=0xBB;Set-FixtureXor $bytes 0
$utilities=New-FixtureFile 'utilities.bin' $bytes
$result=Get-AnalysisFirmwareContext -SourcePath $utilities
Assert-True ($result.Detected -and $result.PayloadRegions[0].Section -eq 'Utilities' -and $result.PayloadRegions[0].SectionType -eq '0xBB') 'Utility section was mislabelled as firmware.'
$missing=Get-AnalysisFirmwareContext -SourcePath (Join-Path $TestRoot 'missing-input.bin')
Assert-True ($missing.Status -eq 'Partial' -and -not $missing.Detected -and -not $missing.Limits.ScanComplete -and $missing.RequiresStaticOnly) 'Unreadable input implied successful inspection.'
$rangeError=$null;try{Get-AnalysisFirmwareContext -SourcePath $plain -MaxInputBytes (1GB+1)|Out-Null}catch{$rangeError=$_.Exception.Message}
Assert-True ([bool]$rangeError) 'MaxInputBytes accepted more than one GiB.'
Write-Output 'PASS: streaming boundary handling, scan budgets, candidate cap, utility distinction and unreadable-input fail-closed result.'

if($DellSamplePath){
    $sample=$ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($DellSamplePath)
    $expectedHash='2C864E0EF920B33E2A9C6311597BAED07B1FBB15E70A661053615CF06A40CD32'
    Assert-True ((Get-FileHash -LiteralPath $sample -Algorithm SHA256).Hash -eq $expectedHash) 'Optional Dell sample is not the pinned XPS 9640 1.26.0 download.'
    $watch=[Diagnostics.Stopwatch]::StartNew()
    $result=Get-AnalysisFirmwareContext -SourcePath $sample
    $watch.Stop()
    Assert-True ($result.Status -eq 'Partial' -and $result.Detected -and $result.Limits.ScanComplete -and $result.CandidateCount -eq 3 -and $result.PayloadRegions.Count -eq 2) 'Pinned Dell sample did not preserve both wrapper evidence and its extra invalid signature candidate.'
    $firmware=@($result.PayloadRegions|Where-Object Section -EQ 'Firmware')
    $utilities=@($result.PayloadRegions|Where-Object Section -EQ 'Utilities')
    Assert-True ($firmware.Count -eq 1 -and $firmware[0].HeaderOffset -eq 3704832 -and $firmware[0].Offset -eq 3704848 -and $firmware[0].Length -eq 49710651 -and $firmware[0].FooterOffset -eq 53415499) 'Pinned Dell firmware wrapper offsets or length changed.'
    Assert-True ($utilities.Count -eq 1 -and $utilities[0].HeaderOffset -eq 3197952 -and $utilities[0].Length -eq 506167) 'Pinned Dell utility wrapper offsets or length changed.'
    Assert-True ($result.Candidates[0].SignatureOffset -eq 3128897 -and $result.Candidates[0].Validation -eq 'Rejected') 'Pinned Dell extra signature candidate was silently accepted or omitted.'
    Assert-True ((Get-FileHash -LiteralPath $sample -Algorithm SHA256).Hash -eq $expectedHash) 'Pinned Dell sample changed during read-only inspection.'
    [pscustomobject]@{Result='PASS: pinned Dell sample read-only wrapper recognition';ElapsedSeconds=[Math]::Round($watch.Elapsed.TotalSeconds,3);InputBytes=$result.Limits.InputBytes;PayloadRegions=$result.PayloadRegions} | ConvertTo-Json -Depth 5
}
