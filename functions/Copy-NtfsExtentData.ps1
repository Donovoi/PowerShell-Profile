function Copy-NtfsExtentData {
    <#
    .SYNOPSIS
    Copies validated, uncompressed NTFS extents from a seekable volume stream.
    .DESCRIPTION
    Writes exactly FileLength bytes. Sparse extents are zero-filled by extending a
    freshly truncated output stream. Invalid disk offsets and short reads fail.
    The caller owns and disposes both streams. This helper does not create snapshots.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][IO.Stream]$Volume,
        [Parameter(Mandatory)][IO.Stream]$Output,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Extents,
        [Parameter(Mandatory)][ValidateRange(0,[long]::MaxValue)][long]$FileLength,
        [Parameter(Mandatory)][ValidateRange(1,2097152)][int]$ClusterSize,
        [Parameter(Mandatory)][ValidateRange(1,[long]::MaxValue)][long]$VolumeLength,
        [ValidateRange(4096,41943040)][int]$BufferSize=65536
    )
    if(-not $Volume.CanRead -or -not $Volume.CanSeek -or -not $Output.CanWrite -or -not $Output.CanSeek){throw 'Seekable input and output streams are required.'}
    [long]$nextVcn=0
    foreach($extent in $Extents){
        if($extent.StartingVcn -ne $nextVcn -or $extent.NextVcn -le $nextVcn -or $extent.Lcn -lt -1){throw 'Invalid, overlapping or discontinuous extents.'}
        if([decimal]$extent.NextVcn*$ClusterSize -gt [long]::MaxValue){throw 'Extent length exceeds Int64.'}
        if($extent.Lcn -ge 0 -and ([decimal]$extent.Lcn+($extent.NextVcn-$extent.StartingVcn))*$ClusterSize -gt $VolumeLength){throw 'Extent is outside the volume.'}
        $nextVcn=$extent.NextVcn
    }
    if([decimal]$nextVcn*$ClusterSize -lt $FileLength){throw 'Extents do not cover the logical file length.'}
    $buffer=[byte[]]::new($BufferSize)
    $Output.SetLength(0)
    $Output.Position=0
    foreach($extent in $Extents){
        [long]$fileOffset=[decimal]$extent.StartingVcn*$ClusterSize
        if($fileOffset -ge $FileLength){break}
        [long]$remaining=[Math]::Min([decimal]($extent.NextVcn-$extent.StartingVcn)*$ClusterSize,$FileLength-$fileOffset)
        $Output.Position=$fileOffset
        if($extent.Lcn -eq -1){$Output.Position=$fileOffset+$remaining;continue}
        $Volume.Position=[long]([decimal]$extent.Lcn*$ClusterSize)
        while($remaining -gt 0){
            $read=$Volume.Read($buffer,0,[int][Math]::Min($buffer.Length,$remaining))
            if($read -le 0){throw 'Unexpected EOF while reading a volume extent.'}
            $Output.Write($buffer,0,$read)
            $remaining-=$read
        }
    }
    $Output.SetLength($FileLength)
    $Output.Flush()
}
