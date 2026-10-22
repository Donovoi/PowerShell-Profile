function Invoke-RawCopy {
    <#
    .SYNOPSIS
    Acquires a file through a VSS snapshot and verifies its logical-data SHA256.
    .DESCRIPTION
    Requires elevated PowerShell on a local NTFS drive. Nonresident, uncompressed
    data is read from validated raw extents. Resident, compressed and encrypted
    files use the logical snapshot stream instead and report that method.
    DisableVss explicitly opts into a live-volume copy with weaker consistency.
    Publishes only after exact-length and source/destination hash agreement.
    Does not acquire alternate streams, ACLs, slack space or full forensic images.
    Raw-device/VSS integration still requires qualification on disposable NTFS media.
    #>
    [CmdletBinding(SupportsShouldProcess,ConfirmImpact='High')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory,Position=0)][string]$Path,
        [Parameter(Mandatory,Position=1)][string]$Destination,
        [switch]$Overwrite,
        [switch]$DisableVss,
        [ValidateRange(4,40960)][int]$BufferSizeKB=64
    )
    $ErrorActionPreference='Stop'
    $source=(Get-Item -LiteralPath $Path -Force -ErrorAction Stop).FullName
    if(-not [IO.File]::Exists($source)){throw 'Source must be a file.'}
    $destinationPath=$ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Destination)
    if($source -eq $destinationPath){throw 'Source and destination must differ.'}
    if([IO.File]::Exists($destinationPath) -and -not $Overwrite){throw 'Destination exists; use -Overwrite.'}
    if($source -notmatch '^[A-Za-z]:\\'){throw 'Raw copy requires a local drive-letter path.'}
    for($part=$source;$part;$part=[IO.Path]::GetDirectoryName($part)){
        if([IO.File]::GetAttributes($part) -band [IO.FileAttributes]::ReparsePoint){throw 'Source path must not traverse reparse points or mounted folders.'}
    }
    if(-not $PSCmdlet.ShouldProcess($source,"Acquire verified file data to $destinationPath; VSS=$(-not $DisableVss)")){return}
    if(-not (Get-Command Initialize-CmdletDependencies -ErrorAction SilentlyContinue)){. (Join-Path $PSScriptRoot 'Initialize-CmdletDependencies.ps1')}
    Initialize-CmdletDependencies -RequiredCmdlets @('Test-IsAdministrator','Initialize-RawCopyNative','ConvertFrom-NtfsRetrievalPointer','Copy-NtfsExtentData') -PreferLocal -ErrorAction Stop
    if(-not (Test-IsAdministrator)){throw 'Open an elevated PowerShell session to acquire raw NTFS data.'}
    Initialize-RawCopyNative
    $volumeRoot=[IO.Path]::GetPathRoot($source)
    $drive=$volumeRoot.Substring(0,2)
    $volumeInfo=Get-CimInstance -ClassName Win32_Volume -Filter "DriveLetter='$drive'" -ErrorAction Stop
    if($volumeInfo.FileSystem -ne 'NTFS' -or -not $volumeInfo.BlockSize -or -not $volumeInfo.Capacity){throw 'A local NTFS volume with known geometry is required.'}
    $shadow=$null; $shadowId=$null; $record=$null; $sourceStream=$null; $volumeStream=$null; $volumeHandle=$null; $outputStream=$null
    $temporary=$destinationPath+'.'+[guid]::NewGuid().ToString('N')+'.partial'
    $sourcePath=$source; $volumePath='\\.\'+$drive
    $started=[datetime]::UtcNow
    try {
        if(-not $DisableVss){
            $created=Invoke-CimMethod -ClassName Win32_ShadowCopy -MethodName Create -Arguments @{Volume=$volumeRoot;Context='ClientAccessible'} -ErrorAction Stop
            if($created.ReturnValue -ne 0){throw "VSS creation failed with code $($created.ReturnValue)."}
            $shadowId=$created.ShadowID
            $shadow=Get-CimInstance -ClassName Win32_ShadowCopy -Filter "ID='$($created.ShadowID)'" -ErrorAction Stop
            if(-not $shadow){throw 'Created VSS snapshot could not be located.'}
            $volumePath=$shadow.DeviceObject.TrimEnd('\')
            $sourcePath=$volumePath+'\'+$source.Substring($volumeRoot.Length)
        } else { Write-Warning 'Live-volume acquisition can observe concurrent changes; VSS is disabled.' }
        $sourceAttributes=[IO.File]::GetAttributes($sourcePath)
        $sourceStream=[IO.File]::Open($sourcePath,'Open','Read',([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
        [long]$length=$sourceStream.Length
        $extents=[Collections.Generic.List[object]]::new()
        $logical=($sourceAttributes -band ([IO.FileAttributes]::Compressed -bor [IO.FileAttributes]::Encrypted)) -ne 0
        if(-not $logical -and $length -gt 0){
            [long]$vcn=0
            do {
                $retrieval=[ProfileRawCopy.Native]::Retrieve($sourceStream.SafeFileHandle,$vcn)
                if($retrieval.Resident){$logical=$true;break}
                $partExtents=@(ConvertFrom-NtfsRetrievalPointer -Buffer $retrieval.Buffer -ExpectedStartingVcn $vcn)
                if(-not $partExtents.Count){throw 'Retrieval pointers made no progress for a nonempty file.'}
                foreach($extent in $partExtents){$extents.Add($extent)}
                $vcn=$partExtents[-1].NextVcn
            } while($retrieval.More)
        }
        $parent=[IO.Path]::GetDirectoryName($destinationPath)
        $null=[IO.Directory]::CreateDirectory($parent)
        $outputStream=[IO.File]::Open($temporary,'CreateNew','ReadWrite','None')
        $method='RawExtents'
        if($logical -or $length -eq 0){
            $method='LogicalFileData'
            $sourceStream.CopyTo($outputStream,$BufferSizeKB*1024)
        } else {
            $volumeHandle=[ProfileRawCopy.Native]::OpenVolume($volumePath)
            $volumeStream=[IO.FileStream]::new($volumeHandle,[IO.FileAccess]::Read)
            Copy-NtfsExtentData -Volume $volumeStream -Output $outputStream -Extents $extents.ToArray() -FileLength $length -ClusterSize $volumeInfo.BlockSize -VolumeLength $volumeInfo.Capacity -BufferSize ($BufferSizeKB*1024)
        }
        if($outputStream.Length -ne $length -or $sourceStream.Length -ne $length){throw 'File length changed or acquisition was incomplete.'}
        $sourceStream.Position=0; $outputStream.Position=0
        $hasher=[Security.Cryptography.SHA256]::Create()
        try {
            $sourceHash=[BitConverter]::ToString($hasher.ComputeHash($sourceStream)).Replace('-','')
            $destinationHash=[BitConverter]::ToString($hasher.ComputeHash($outputStream)).Replace('-','')
        } finally {$hasher.Dispose()}
        if($sourceHash -ne $destinationHash){throw 'Raw and logical file hashes differ; output was not published.'}
        $outputStream.Dispose(); $outputStream=$null
        [IO.File]::Move($temporary,$destinationPath,[bool]$Overwrite)
        $record=[pscustomobject]@{Success=$true;Source=$source;Destination=$destinationPath;Length=$length;SHA256=$destinationHash;Method=$method;Consistency=$(if($DisableVss){'Live'}else{'VSS'});SnapshotId=$shadowId;StartedUtc=$started;CompletedUtc=[datetime]::UtcNow}
    }
    finally {
        if($outputStream){$outputStream.Dispose()}
        if($volumeStream){$volumeStream.Dispose()}
        if($volumeHandle){$volumeHandle.Dispose()}
        if($sourceStream){$sourceStream.Dispose()}
        if([IO.File]::Exists($temporary)){[IO.File]::Delete($temporary)}
        if($shadowId){
            if(-not $shadow){$shadow=Get-CimInstance -ClassName Win32_ShadowCopy -Filter "ID='$shadowId'" -ErrorAction Stop}
            if($shadow){$shadow|Remove-CimInstance -ErrorAction Stop}else{Write-Warning "Snapshot cleanup could not locate $shadowId; check VSS state."}
        }
    }
    $record
}
