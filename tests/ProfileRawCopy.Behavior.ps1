#requires -Version 7.0
[CmdletBinding()]
param([Parameter(Mandatory)][string]$TestRoot)
$ErrorActionPreference='Stop'
if(Test-Path -LiteralPath $TestRoot){throw 'Use a new fixture directory.'}
$null=[IO.Directory]::CreateDirectory($TestRoot)
foreach($name in 'ConvertFrom-NtfsRetrievalPointer','Copy-NtfsExtentData','Initialize-RawCopyNative','Invoke-RawCopy','Initialize-CmdletDependencies','Test-IsAdministrator'){. "$PSScriptRoot/../functions/$name.ps1"}
function Assert($Condition,$Message){if(-not $Condition){throw $Message}}
function Assert-Fails([scriptblock]$Body){$failed=$false;try{& $Body|Out-Null}catch{$failed=$true};Assert $failed 'Expected failure'}
function New-ExtentBuffer([long]$Start,[long[]]$Pairs){
    $buffer=[byte[]]::new(16+8*$Pairs.Count)
    [BitConverter]::GetBytes([uint32]($Pairs.Count/2)).CopyTo($buffer,0)
    [BitConverter]::GetBytes($Start).CopyTo($buffer,8)
    for($index=0;$index -lt $Pairs.Count;$index++){[BitConverter]::GetBytes($Pairs[$index]).CopyTo($buffer,16+8*$index)}
    ,$buffer
}
$buffer=New-ExtentBuffer 0 @(1,123,3,-1,4,456)
$extents=@(ConvertFrom-NtfsRetrievalPointer $buffer)
Assert ($extents.Count -eq 3 -and $extents[0].Lcn -eq 123 -and $extents[1].Lcn -eq -1 -and $extents[1].ClusterCount -eq 2 -and $extents[2].StartingVcn -eq 3) 'Aligned signed extent decoding incorrect'
$continuation=@(ConvertFrom-NtfsRetrievalPointer (New-ExtentBuffer 4 @(6,500)) -ExpectedStartingVcn 4)
Assert ($continuation[0].ClusterCount -eq 2) 'Continuation decoding failed'
Assert-Fails {ConvertFrom-NtfsRetrievalPointer ([byte[]]::new(15))}
Assert-Fails {ConvertFrom-NtfsRetrievalPointer $buffer[0..31]}
Assert-Fails {ConvertFrom-NtfsRetrievalPointer (New-ExtentBuffer 0 @(0,2))}
Assert-Fails {ConvertFrom-NtfsRetrievalPointer (New-ExtentBuffer 0 @(1,-2))}
Assert-Fails {ConvertFrom-NtfsRetrievalPointer (New-ExtentBuffer 3 @(4,1))}
Write-Host 'PASS: aligned ABI offsets, signed sparse sentinel, continuation and malformed buffers'

$bytes=[byte[]](0..127)
$volume=[IO.MemoryStream]::new($bytes)
$output=[IO.MemoryStream]::new()
$runs=@(ConvertFrom-NtfsRetrievalPointer (New-ExtentBuffer 0 @(1,2,3,-1,4,7)))
Copy-NtfsExtentData -Volume $volume -Output $output -Extents $runs -FileLength 29 -ClusterSize 8 -VolumeLength 128
$expected=[byte[]](@(16..23)+@(0)*16+@(56..60))
Assert ([Convert]::ToBase64String($output.ToArray()) -eq [Convert]::ToBase64String($expected)) 'Sparse/multi-extent/tail copy differs from expected bytes'
Assert-Fails {Copy-NtfsExtentData -Volume $volume -Output $output -Extents @([pscustomobject]@{StartingVcn=0;NextVcn=2;Lcn=15}) -FileLength 16 -ClusterSize 8 -VolumeLength 128}
Assert-Fails {Copy-NtfsExtentData -Volume $volume -Output $output -Extents $runs -FileLength 40 -ClusterSize 8 -VolumeLength 128}
$short=[IO.MemoryStream]::new([byte[]]::new(2))
Assert-Fails {Copy-NtfsExtentData -Volume $short -Output $output -Extents @([pscustomobject]@{StartingVcn=0;NextVcn=1;Lcn=0}) -FileLength 8 -ClusterSize 8 -VolumeLength 128}
$short.Dispose();$volume.Dispose();$output.Dispose()
Add-Type -TypeDefinition @'
using System;
using System.IO;
public sealed class LengthOnlyFixtureStream : Stream {
 public long LogicalLength; public override bool CanRead=>true; public override bool CanWrite=>true; public override bool CanSeek=>true;
 public override long Length=>LogicalLength; public override long Position{get;set;}
 public override void Flush(){} public override int Read(byte[] b,int o,int c)=>throw new NotSupportedException();
 public override void Write(byte[] b,int o,int c)=>throw new NotSupportedException();
 public override long Seek(long p,SeekOrigin origin)=>Position=p;
 public override void SetLength(long n){LogicalLength=n;}
}
'@
$large=[LengthOnlyFixtureStream]::new();$input=[IO.MemoryStream]::new()
$size=[long]3GB+7
$sparse=@([pscustomobject]@{StartingVcn=0;NextVcn=[long][Math]::Ceiling($size/4096.0);Lcn=-1})
Copy-NtfsExtentData -Volume $input -Output $large -Extents $sparse -FileLength $size -ClusterSize 4096 -VolumeLength 4GB
Assert ($large.Length -eq $size) 'Int64 file length was truncated'
$large.Dispose();$input.Dispose()
Write-Host 'PASS: exact sparse/multi-extent bytes, final partial cluster, invalid volume offsets, EOF and >2 GiB length handling'

Initialize-RawCopyNative
$path=Join-Path $TestRoot native-extent-fixture.bin
[IO.File]::WriteAllBytes($path,[byte[]]::new(8192))
$file=[IO.File]::Open($path,'Open','Read','ReadWrite')
try {
    $native=[ProfileRawCopy.Native]::Retrieve($file.SafeFileHandle,0)
    Assert (-not $native.Resident) 'Nonresident native fixture unexpectedly resident'
    $nativeExtents=@(ConvertFrom-NtfsRetrievalPointer $native.Buffer)
    Assert ($nativeExtents.Count -gt 0 -and $nativeExtents[0].StartingVcn -eq 0) 'Native retrieval pointers could not be decoded'
} finally {$file.Dispose()}
$preview=Invoke-RawCopy -Path $path -Destination "$TestRoot/preview.bin" -WhatIf
Assert (-not [IO.File]::Exists("$TestRoot/preview.bin")) 'Raw WhatIf wrote a file'
function Test-IsAdministrator {$false}
Assert-Fails {Invoke-RawCopy -Path $path -Destination "$TestRoot/no-admin.bin" -Confirm:$false}
Assert (-not [IO.File]::Exists("$TestRoot/no-admin.bin")) 'Non-admin acquisition published output'
function Test-IsAdministrator {$true}
$script:removedSnapshots=0
$script:missingSnapshotFile=$false
function Get-CimInstance {
    [CmdletBinding()] param($ClassName,$Filter)
    if($ClassName -eq 'Win32_Volume'){return [pscustomobject]@{FileSystem='NTFS';BlockSize=4096;Capacity=1TB}}
    if($ClassName -eq 'Win32_ShadowCopy'){return [pscustomobject]@{ID='fixture-shadow';DeviceObject=$(if($script:missingSnapshotFile){'Z:\missing-fixture'}else{[IO.Path]::GetPathRoot($TestRoot).TrimEnd('\')})}}
    throw 'Unexpected CIM query'
}
function Invoke-CimMethod {[CmdletBinding()]param($ClassName,$MethodName,$Arguments) [pscustomobject]@{ReturnValue=0;ShadowID='fixture-shadow'}}
function Remove-CimInstance {[CmdletBinding()]param([Parameter(ValueFromPipeline)]$InputObject) process{Assert ($InputObject.ID -eq 'fixture-shadow') 'Wrong snapshot cleanup';$script:removedSnapshots++}}
$empty=Join-Path $TestRoot empty.bin
[IO.File]::WriteAllBytes($empty,[byte[]]::new(0))
$result=Invoke-RawCopy -Path $empty -Destination "$TestRoot/empty-copy.bin" -Confirm:$false
Assert ($result.Success -and $result.Length -eq 0 -and $result.Consistency -eq 'VSS' -and $result.SHA256 -eq (Get-FileHash -LiteralPath $empty).Hash -and $script:removedSnapshots -eq 1) 'Snapshot orchestration, hash or cleanup failed'
$script:missingSnapshotFile=$true
Assert-Fails {Invoke-RawCopy -Path $empty -Destination "$TestRoot/failed-copy.bin" -Confirm:$false}
Assert ($script:removedSnapshots -eq 2 -and -not [IO.File]::Exists("$TestRoot/failed-copy.bin")) 'Failed snapshot acquisition leaked cleanup or published output'
Write-Host 'PASS: compiled Win32 declarations and real fixture-file retrieval control; WhatIf and non-admin guards'
Write-Host 'LIMIT: no raw-volume reads or VSS snapshots were performed; elevated acquisition remains unqualified.'
