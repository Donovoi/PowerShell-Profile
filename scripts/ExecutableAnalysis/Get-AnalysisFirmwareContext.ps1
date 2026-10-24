function Get-AnalysisFirmwareContext {
    <#
    .SYNOPSIS
    Recognizes bounded Dell compressed PFS wrapper structures without execution.
    .DESCRIPTION
    Read-only internal helper. It scans at most MaxInputBytes (one GiB maximum)
    using one MiB chunks, and validates at most 128 signature candidates. Lengths,
    exact footer placement, the zlib prefix and both XOR checksums are checked.
    Recognition covers the wrapper only: compressed data is not decompressed,
    authenticated or interpreted, and raw PFS/UEFI/capsules are not recognized.
    Offsets are zero-based file offsets; regions describe compressed bytes.
    RequiresStaticOnly also covers invalid candidates and incomplete inspection.
    A complete scan with no recognized wrapper is not proof of no firmware.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$SourcePath,
        [ValidateRange(0,1073741824)][long]$MaxInputBytes=1GB
    )
    $ErrorActionPreference='Stop'
    $source=$ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($SourcePath)
    $limitations=[Collections.Generic.List[string]]::new()
    $candidates=[Collections.Generic.List[object]]::new()
    $regions=[Collections.Generic.List[object]]::new()
    $encoding=[Text.Encoding]::Latin1
    $headerMagic=[byte[]]@(0xEE,0xAA,0x76,0x1B,0xEC,0xBB,0x20,0xF1,0xE6,0x51)
    $footerMagic=[byte[]]@(0xEE,0xAA,0xEE,0x8F,0x49,0x1B,0xE8,0xAE,0x14,0x37,0x90)
    $needle=$encoding.GetString($headerMagic)
    $chunkBytes=1MB
    $maxCandidates=128
    $state=@{InputBytes=0L;ScanLimitBytes=0L;ScannedBytes=0L;ReadBytes=0L;Partial=$false;CandidateLimit=$false;Opened=$false}
    $stream=$null

    function Read-FirmwareByteRange {
        param([long]$Offset,[int]$Count)
        # Subtraction checks avoid overflow and prohibit validation reads beyond
        # the caller's byte budget, even when an advertised length points there.
        if($Offset -lt 0 -or $Offset -gt $state.ScanLimitBytes -or $Count -gt ($state.ScanLimitBytes-$Offset)){
            throw 'Validation read would exceed the inspected input range.'
        }
        $bytes=[byte[]]::new($Count)
        $stream.Position=$Offset
        $done=0
        while($done -lt $Count){
            $read=$stream.Read($bytes,$done,$Count-$done)
            if($read -eq 0){throw 'Input became truncated during inspection.'}
            $state.ReadBytes+=$read
            $done+=$read
        }
        return ,$bytes
    }
    function Test-FirmwareXor {
        param([byte[]]$Bytes)
        $value=0
        for($index=0;$index -lt 15;$index++){$value=$value -bxor $Bytes[$index]}
        return $value -eq $Bytes[15]
    }
    function Get-FirmwareCandidate {
        param([long]$SignatureOffset)
        $entry=[pscustomobject][ordered]@{
            SignatureOffset=$SignatureOffset
            HeaderOffset=$SignatureOffset-5L
            Validation='Rejected'
            Reason=$null
            SectionType=$null
            CompressedOffset=$null
            CompressedBytes=$null
            FooterOffset=$null
        }
        if($entry.HeaderOffset -lt 0){$entry.Reason='Signature has no complete preceding header.';return $entry}
        if(($state.ScanLimitBytes-$entry.HeaderOffset) -lt 18){$entry.Reason='Header or zlib prefix is truncated or outside the scan limit.';return $entry}
        $header=Read-FirmwareByteRange $entry.HeaderOffset 18
        if(-not (Test-FirmwareXor $header)){$entry.Reason='Header XOR checksum is invalid.';return $entry}
        $entry.SectionType='0x{0:X2}' -f $header[4]
        if($header[4] -notin @(0xAA,0xBB)){$entry.Reason='Section type is not a recognized Dell firmware or utility type.';return $entry}
        # Dell's documented signature uses this specific zlib CMF/FLG pair.
        if($header[16] -ne 0x78 -or $header[17] -ne 0x9C){$entry.Reason='Dell zlib prefix is invalid.';return $entry}
        $length=[long][BitConverter]::ToUInt32($header,0)
        $entry.CompressedOffset=$entry.HeaderOffset+16L
        $entry.CompressedBytes=$length
        if($length -lt 8){$entry.Reason='Compressed length is too short for a zlib stream.';return $entry}
        # uint32 length is widened to Int64 before arithmetic; compare against
        # remaining bytes before calculating the footer address.
        if($length -gt ($state.InputBytes-$entry.CompressedOffset-16L)){
            $entry.Reason='Compressed length and footer exceed the input length.';return $entry
        }
        if($length -gt ($state.ScanLimitBytes-$entry.CompressedOffset-16L)){
            $entry.Reason='Compressed length and footer exceed the scan limit.';return $entry
        }
        $entry.FooterOffset=$entry.CompressedOffset+$length
        $footer=Read-FirmwareByteRange $entry.FooterOffset 16
        for($index=0;$index -lt $footerMagic.Length;$index++){
            if($footer[4+$index] -ne $footerMagic[$index]){$entry.Reason='Footer signature is absent at the declared offset.';return $entry}
        }
        if(-not (Test-FirmwareXor $footer)){$entry.Reason='Footer XOR checksum is invalid.';return $entry}
        if([long][BitConverter]::ToUInt32($footer,0) -ne $length){$entry.Reason='Header and footer compressed lengths differ.';return $entry}
        $entry.Validation='StructureValidated'
        $entry.Reason='Header, known section type, zlib prefix, exact footer offset, lengths and XOR checksums agree; compressed contents were not validated.'
        return $entry
    }

    try{
        # Refuse links in the source path, including ancestor directories.
        $cursor=[IO.Path]::GetFullPath($source)
        $ancestors=[Collections.Generic.Stack[string]]::new()
        while($cursor){
            $ancestors.Push($cursor)
            $parent=[IO.Path]::GetDirectoryName($cursor)
            if($parent -eq $cursor){break};$cursor=$parent
        }
        while($ancestors.Count){
            $item=Get-Item -LiteralPath $ancestors.Pop() -Force -ErrorAction Stop
            if($item.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Reparse-point input paths are not inspected.'}
        }
        $stream=[IO.FileStream]::new($source,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
        $state.Opened=$true
        $state.InputBytes=$stream.Length
        $state.ScanLimitBytes=[Math]::Min($state.InputBytes,$MaxInputBytes)
        $buffer=[byte[]]::new($chunkBytes+$headerMagic.Length-1)
        $carry=0
        $position=0L
        while($position -lt $state.ScanLimitBytes){
            $requested=[int][Math]::Min($chunkBytes,$state.ScanLimitBytes-$position)
            $stream.Position=$position
            $read=0
            while($read -lt $requested){
                $count=$stream.Read($buffer,$carry+$read,$requested-$read)
                if($count -eq 0){throw 'Input became truncated during inspection.'}
                $state.ReadBytes+=$count
                $read+=$count
            }
            $text=$encoding.GetString($buffer,0,$carry+$read)
            $baseOffset=$position-$carry
            $searchAt=0
            while($searchAt -lt $text.Length){
                $match=$text.IndexOf($needle,$searchAt,[StringComparison]::Ordinal)
                if($match -lt 0){break}
                $offset=$baseOffset+$match
                $candidate=Get-FirmwareCandidate $offset
                $candidates.Add($candidate)
                if($candidate.Validation -eq 'StructureValidated'){
                    $regions.Add([pscustomobject][ordered]@{
                        Kind='DellPfsZlibWrapper'
                        Scope='CompressedWrapperOnly'
                        SectionType=$candidate.SectionType
                        Section=if($candidate.SectionType -eq '0xAA'){'Firmware'}else{'Utilities'}
                        Offset=$candidate.CompressedOffset
                        Length=$candidate.CompressedBytes
                        HeaderOffset=$candidate.HeaderOffset
                        SignatureOffset=$candidate.SignatureOffset
                        FooterOffset=$candidate.FooterOffset
                        ContainerLength=$candidate.CompressedBytes+32L
                        Confidence='StructureValidated'
                        PayloadValidated=$false
                    })
                }else{$state.Partial=$true}
                $searchAt=$match+$headerMagic.Length
                if($candidates.Count -ge $maxCandidates){
                    $state.ScannedBytes=$offset+$headerMagic.Length
                    $state.CandidateLimit=$true
                    $state.Partial=$true
                    $limitations.Add('Candidate inspection stopped at the 128-candidate limit; later bytes were not searched.')
                    break
                }
            }
            if($state.CandidateLimit){break}
            $position+=$read
            $state.ScannedBytes=$position
            $carry=[Math]::Min($headerMagic.Length-1,$carry+$read)
            [Array]::Copy($buffer,($text.Length-$carry),$buffer,0,$carry)
        }
        if($stream.Length -ne $state.InputBytes){throw 'Input length changed during inspection.'}
        if($state.ScanLimitBytes -lt $state.InputBytes){
            $state.Partial=$true
            $limitations.Add('Input exceeds MaxInputBytes; bytes outside the scan limit were not inspected.')
        }
    }catch{
        $state.Partial=$true
        $limitations.Add('Firmware context inspection failed: '+$_.Exception.Message)
    }finally{
        if($stream){$stream.Dispose()}
    }
    $scanComplete=$state.Opened -and -not $state.CandidateLimit -and $state.ScannedBytes -eq $state.InputBytes
    $detected=$regions.Count -gt 0
    $limitations.Add('Recognition is limited to Dell compressed PFS wrapper structure; zlib contents, signatures, firmware identity, raw PFS, UEFI volumes, capsules and menu semantics were not validated.')
    if($candidates.Count -gt $regions.Count){$limitations.Add('Rejected signature candidates are recorded as unknown, not verified firmware.')}
    if(-not $detected){$limitations.Add('No validated supported wrapper was found in the inspected range; this does not establish absence of firmware.')}
    [pscustomobject][ordered]@{
        SourcePath=$source
        Status=if($state.Partial){'Partial'}elseif($detected){'Completed'}else{'Skipped'}
        Detected=$detected
        Kind=if($detected){'DellPfsZlibWrapper'}else{'Unknown'}
        Confidence=if($detected){'StructureValidated'}elseif($candidates.Count){'UnvalidatedSignature'}else{'None'}
        Scope='CompressedWrapperOnly'
        RequiresStaticOnly=($candidates.Count -gt 0 -or -not $scanComplete -or $state.Partial)
        CandidateCount=$candidates.Count
        Candidates=$candidates.ToArray()
        PayloadRegions=$regions.ToArray()
        Limits=[pscustomobject][ordered]@{
            MaxInputBytes=$MaxInputBytes
            InputBytes=$state.InputBytes
            ScanLimitBytes=$state.ScanLimitBytes
            ScannedBytes=$state.ScannedBytes
            ReadBytes=$state.ReadBytes
            ScanComplete=$scanComplete
            MaxCandidates=$maxCandidates
            CandidateLimitReached=$state.CandidateLimit
            ChunkBytes=$chunkBytes
        }
        Limitations=$limitations.ToArray()
    }
}
