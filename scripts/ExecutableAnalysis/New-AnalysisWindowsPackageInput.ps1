function Get-AnalysisWindowsPackageStreamHash {
    [CmdletBinding()]
    param([Parameter(Mandatory)][IO.Stream]$Stream,[Parameter(Mandatory)][long]$MaximumBytes)
    $hash=[Security.Cryptography.IncrementalHash]::CreateHash([Security.Cryptography.HashAlgorithmName]::SHA256)
    $buffer=[byte[]]::new(65536);[long]$counted=0
    try{
        while(($count=$Stream.Read($buffer,0,[int][Math]::Min($buffer.Length,$MaximumBytes-$counted+1))) -gt 0){
            $counted+=$count;if($counted -gt $MaximumBytes){throw 'Package stream exceeds its byte limit.'}
            $hash.AppendData($buffer,0,$count)
        }
        return [pscustomobject]@{Bytes=$counted;SHA256=[Convert]::ToHexString($hash.GetHashAndReset())}
    }finally{$hash.Dispose()}
}

function ConvertFrom-AnalysisWindowsPackagePartName {
    [CmdletBinding()][OutputType([string])]
    param([Parameter(Mandatory)][string]$Name)
    if($Name.Length -gt 2048 -or $Name.Contains('\') -or $Name -match '%(?![0-9a-fA-F]{2})|%(?i:2f|5c)'){throw 'Invalid or ambiguous encoded package path.'}
    $builder=[Text.StringBuilder]::new();$utf8=[Text.UTF8Encoding]::new($false,$true)
    for($index=0;$index -lt $Name.Length;$index++){
        if($Name[$index] -eq '%'){
            $bytes=[Collections.Generic.List[byte]]::new()
            while($index+2 -lt $Name.Length -and $Name[$index] -eq '%'){
                $bytes.Add([Convert]::ToByte($Name.Substring($index+1,2),16));$index+=3
            }
            $index--;$null=$builder.Append($utf8.GetString($bytes.ToArray()))
        }else{$null=$builder.Append($Name[$index])}
    }
    $decoded=$builder.ToString();$relative=if($decoded.EndsWith('/')){$decoded.Substring(0,$decoded.Length-1)}else{$decoded}
    Assert-AnalysisWindowsPayloadRelativePath $relative
    return $decoded
}

function Test-AnalysisWindowsPackageZipDirectory {
    [CmdletBinding()]
    param([Parameter(Mandatory)][IO.Stream]$Stream,[Parameter(Mandatory)][int]$MaximumEntries)
    if($Stream.Length -lt 22){throw 'Package archive has no ZIP directory.'}
    $length=[int][Math]::Min(65557,$Stream.Length);$tail=[byte[]]::new($length)
    $Stream.Position=$Stream.Length-$length;$offset=0
    while($offset -lt $length){$read=$Stream.Read($tail,$offset,$length-$offset);if($read -eq 0){throw 'Incomplete ZIP directory.'};$offset+=$read}
    $end=-1
    for($index=$tail.Length-22;$index -ge 0;$index--){
        if([BitConverter]::ToUInt32($tail,$index) -eq 0x06054b50 -and $index+22+[BitConverter]::ToUInt16($tail,$index+20) -eq $tail.Length){$end=$index;break}
    }
    if($end -lt 0 -or [BitConverter]::ToUInt16($tail,$end+4) -ne 0 -or [BitConverter]::ToUInt16($tail,$end+6) -ne 0){throw 'Missing or multi-disk ZIP directory.'}
    [long]$entries=[BitConverter]::ToUInt16($tail,$end+10)
    [long]$directoryBytes=[BitConverter]::ToUInt32($tail,$end+12)
    [long]$directoryOffset=[BitConverter]::ToUInt32($tail,$end+16)
    if($entries -eq [uint16]::MaxValue -or $directoryBytes -eq [uint32]::MaxValue -or $directoryOffset -eq [uint32]::MaxValue){
        if($end -lt 20 -or [BitConverter]::ToUInt32($tail,$end-20) -ne 0x07064b50 -or [BitConverter]::ToUInt32($tail,$end-16) -ne 0 -or [BitConverter]::ToUInt32($tail,$end-4) -ne 1){throw 'Invalid ZIP64 locator.'}
        $zip64Offset=[BitConverter]::ToUInt64($tail,$end-12)
        if($zip64Offset -gt [uint64]($Stream.Length-56)){throw 'ZIP64 directory offset exceeds archive.'}
        $record=[byte[]]::new(56);$Stream.Position=[long]$zip64Offset;$offset=0
        while($offset -lt 56){$read=$Stream.Read($record,$offset,56-$offset);if($read -eq 0){throw 'Incomplete ZIP64 directory.'};$offset+=$read}
        if([BitConverter]::ToUInt32($record,0) -ne 0x06064b50 -or [BitConverter]::ToUInt64($record,4) -lt 44 -or [BitConverter]::ToUInt32($record,16) -ne 0 -or [BitConverter]::ToUInt32($record,20) -ne 0 -or [BitConverter]::ToUInt64($record,24) -ne [BitConverter]::ToUInt64($record,32)){throw 'Invalid or multi-disk ZIP64 directory.'}
        $entries=[long][BitConverter]::ToUInt64($record,32);$directoryBytes=[long][BitConverter]::ToUInt64($record,40);$directoryOffset=[long][BitConverter]::ToUInt64($record,48)
    }elseif([BitConverter]::ToUInt16($tail,$end+8) -ne $entries){throw 'ZIP entry counts disagree.'}
    if($entries -lt 1 -or $entries -gt $MaximumEntries -or $directoryBytes -lt 46 -or $directoryBytes -gt 64MB -or $directoryOffset -lt 0 -or $directoryOffset -gt $Stream.Length-$directoryBytes){throw 'Package ZIP directory exceeds entry or metadata limits.'}
    # Do not trust the advertised entry count: count bounded central records before
    # ZipArchive is allowed to materialize them in memory.
    $Stream.Position=$directoryOffset;[long]$actualEntries=0;$header=[byte[]]::new(46)
    $directoryEnd=$directoryOffset+$directoryBytes
    while($Stream.Position -lt $directoryEnd){
        if($directoryEnd-$Stream.Position -lt 46){throw 'Incomplete central-directory entry.'}
        $offset=0;while($offset -lt 46){$read=$Stream.Read($header,$offset,46-$offset);if($read -eq 0){throw 'Incomplete central-directory entry.'};$offset+=$read}
        if([BitConverter]::ToUInt32($header,0) -ne 0x02014b50){throw 'Unexpected central-directory record.'}
        $actualEntries++;if($actualEntries -gt $MaximumEntries){throw 'Package ZIP directory exceeds its actual entry limit.'}
        $variableBytes=[int][BitConverter]::ToUInt16($header,28)+[int][BitConverter]::ToUInt16($header,30)+[int][BitConverter]::ToUInt16($header,32)
        if($variableBytes -gt $directoryEnd-$Stream.Position){throw 'Central-directory entry exceeds metadata bounds.'}
        $Stream.Position+=$variableBytes
    }
    if($actualEntries -ne $entries){throw 'Actual and advertised ZIP directory counts disagree.'}
    $Stream.Position=0
    return [pscustomobject]@{Entries=$entries;DirectoryBytes=$directoryBytes}
}

function Test-AnalysisWindowsPackageInputSource {
    <#.SYNOPSIS
    Reverifies the original and preserved package archive and license without deploying them.
    #>
    [CmdletBinding()][OutputType([pscustomobject])]
    param([Parameter(Mandatory)][psobject]$PackageInput)
    $ErrorActionPreference='Stop'
    if($PackageInput.Schema -ne 'PowerShellProfile.WindowsPackageInput.v1' -or $PackageInput.Status -notin 'Building','Completed' -or $PackageInput.MaxPackageBytes -lt 1 -or $PackageInput.MaxPackageBytes -gt 64GB){throw 'Invalid preserved package-input record.'}
    foreach($kind in 'Archive','License'){
        $hashProperty=$kind+'SHA256';$bytesProperty=$kind+'Bytes'
        $expectedHash=$PackageInput.$hashProperty;$expectedBytes=$PackageInput.$bytesProperty
        $limit=if($kind -eq 'License'){1MB}else{[long]$PackageInput.MaxPackageBytes}
        if($expectedHash -notmatch '^[A-Fa-f0-9]{64}$' -or $expectedBytes -lt 1 -or $expectedBytes -gt $limit){throw 'Invalid preserved package-input hash or length.'}
        foreach($property in ('Source'+$kind+'Path'),($kind+'Path')){
            $path=$PackageInput.$property
            if(-not [IO.Path]::IsPathFullyQualified($path)){throw 'Package-input paths must be absolute.'}
            Assert-AnalysisWindowsPayloadRegularPath $path
            $stream=[IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
            try{
                if($stream.Length -ne $expectedBytes){throw "Package input source or preserved file changed: $property"}
                $actual=Get-AnalysisWindowsPackageStreamHash -Stream $stream -MaximumBytes $expectedBytes
                if($actual.Bytes -ne $expectedBytes -or $actual.SHA256 -cne $expectedHash.ToUpperInvariant()){throw "Package input source or preserved file changed: $property"}
            }finally{$stream.Dispose()}
        }
    }
    return [pscustomobject]@{Status='Completed';SourcesVerified=2;PreservedFilesVerified=2;SourceUnchanged=$true}
}

function New-AnalysisWindowsPackageInput {
    <#
    .SYNOPSIS
    Preserves a signed package container and license and compares every payload file.
    .DESCRIPTION
    Does not execute or deploy anything. Windows deployment must subsequently validate
    package and license signatures. OutputDirectory must be new with an existing parent.
    ZIP names are decoded once; paths, entry counts and streamed expansion are bounded.
    #>
    [CmdletBinding(SupportsShouldProcess)][OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$PackageArchivePath,
        [Parameter(Mandatory)][string]$PackageLicensePath,
        [Parameter(Mandatory)][psobject]$Payload,
        [Parameter(Mandatory)][string]$OutputDirectory,
        [ValidateRange(1,68719476736)][long]$MaxPackageBytes=8GB
    )
    $ErrorActionPreference='Stop'
    $archiveSource=$ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($PackageArchivePath)
    $licenseSource=$ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($PackageLicensePath)
    $output=$ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputDirectory)
    foreach($path in $archiveSource,$licenseSource,$output){Assert-AnalysisWindowsPayloadRegularPath $path}
    if($archiveSource.Equals($licenseSource,[StringComparison]::OrdinalIgnoreCase)){throw 'Archive and license must be distinct files.'}
    foreach($path in $archiveSource,$licenseSource){if(-not(Test-Path -LiteralPath $path -PathType Leaf)){throw 'Package archive and license must be existing regular files.'}}
    $archiveLength=(Get-Item -LiteralPath $archiveSource -Force -ErrorAction Stop).Length
    $licenseLength=(Get-Item -LiteralPath $licenseSource -Force -ErrorAction Stop).Length
    if($archiveLength -lt 1 -or $archiveLength -gt $MaxPackageBytes){throw 'Package archive exceeds its byte limit.'}
    if($licenseLength -lt 1 -or $licenseLength -gt 1MB){throw 'Package license must be between 1 byte and 1 MiB.'}
    if(Test-Path -LiteralPath $output){throw 'OutputDirectory already exists; refusing overwrite.'}
    $parent=[IO.Path]::GetDirectoryName($output)
    if(-not(Test-Path -LiteralPath $parent -PathType Container)){throw 'OutputDirectory requires an existing parent directory.'}
    if($Payload.Schema -ne 'PowerShellProfile.WindowsPayload.v1' -or $Payload.Status -ne 'Completed' -or $Payload.Mode -ne 'DesktopLayout' -or $null -eq $Payload.Package){throw 'A completed packaged desktop payload is required.'}
    $files=@($Payload.Files);$directories=@($Payload.Directories|Where-Object {$null -ne $_})
    if($files.Count -lt 1 -or $files.Count -gt 50000 -or $directories.Count -gt 200000 -or $files.Count+$directories.Count -gt 200064){throw 'Payload inventory exceeds package-input limits.'}
    foreach($path in @($archiveSource,$licenseSource,$Payload.SourceRoot,$Payload.SourcePath,$Payload.ArchivePath,$Payload.ManifestPath)){
        if(-not [IO.Path]::IsPathFullyQualified($path)){throw 'Preserved source paths must be absolute.'}
        $full=[IO.Path]::GetFullPath($path).TrimEnd('\','/');$base=$output.TrimEnd('\','/')
        if($full.Equals($base,[StringComparison]::OrdinalIgnoreCase) -or $full.StartsWith($base+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase) -or $base.StartsWith($full+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)){throw 'OutputDirectory must not overlap package inputs or the preserved payload.'}
    }
    $expected=[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
    $caseNames=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    [long]$payloadBytes=0
    foreach($file in $files){
        Assert-AnalysisWindowsPayloadRelativePath $file.Path
        if($file.Path.Contains('\') -or $file.Bytes -lt 0 -or $file.Bytes -gt $MaxPackageBytes -or $file.SHA256 -notmatch '^[A-Fa-f0-9]{64}$' -or -not $caseNames.Add($file.Path)){throw 'Invalid or duplicate payload file record.'}
        $payloadBytes+=[long]$file.Bytes;if($payloadBytes -gt $MaxPackageBytes){throw 'Payload exceeds its byte limit.'}
        $expected.Add($file.Path,$file)
    }
    $expectedDirectories=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach($directory in $directories){Assert-AnalysisWindowsPayloadRelativePath $directory;if($directory.Contains('\') -or -not $caseNames.Add($directory)){throw 'Invalid or duplicate payload directory record.'};$null=$expectedDirectories.Add($directory)}
    if($payloadBytes -ne $Payload.TotalBytes -or -not $expected.ContainsKey('AppxManifest.xml') -or -not $expected.ContainsKey($Payload.EntryPoint) -or $expected['AppxManifest.xml'].SHA256 -ne $Payload.Package.ManifestSHA256 -or $expected[$Payload.EntryPoint].SHA256 -ne $Payload.SourceSHA256){throw 'Payload manifest, entry point or byte totals disagree.'}
    if($expected.ContainsKey('[Content_Types].xml')){throw 'The installed payload unexpectedly contains container-only metadata.'}
    if(-not $PSCmdlet.ShouldProcess($output,'Preserve package and license; verify every archived payload file without deployment')){return}
    $archivePath=Join-Path $output 'package.msix';$licensePath=Join-Path $output 'license.xml';$manifestPath=Join-Path $output 'package-input.json'
    $result=[ordered]@{Schema='PowerShellProfile.WindowsPackageInput.v1';Status='Building';SourceArchivePath=$archiveSource;SourceLicensePath=$licenseSource;ArchivePath=$archivePath;LicensePath=$licensePath;ManifestPath=$manifestPath;ArchiveSHA256=$null;LicenseSHA256=$null;ArchiveBytes=$archiveLength;LicenseBytes=$licenseLength;FilesVerified=0;ContainerOnlyFiles=@();MaxPackageBytes=$MaxPackageBytes;Validation=$null}
    $streams=[Collections.Generic.List[IO.Stream]]::new();$created=$false;$zip=$null
    try{
        # Deny writes and deletes while preserving both source files.
        $sourceArchive=[IO.File]::Open($archiveSource,'Open','Read','Read');$streams.Add($sourceArchive)
        $sourceLicense=[IO.File]::Open($licenseSource,'Open','Read','Read');$streams.Add($sourceLicense)
        if($sourceArchive.Length -ne $archiveLength -or $sourceLicense.Length -ne $licenseLength){throw 'Package input length changed before preservation.'}
        $licenseSettings=[Xml.XmlReaderSettings]::new();$licenseSettings.DtdProcessing=[Xml.DtdProcessing]::Prohibit;$licenseSettings.XmlResolver=$null;$licenseSettings.MaxCharactersInDocument=1MB;$licenseSettings.CloseInput=$false
        $reader=[Xml.XmlReader]::Create($sourceLicense,$licenseSettings)
        try{$licenseXml=[Xml.XmlDocument]::new();$licenseXml.XmlResolver=$null;$licenseXml.Load($reader)}finally{$reader.Dispose();$sourceLicense.Position=0}
        if($licenseXml.DocumentElement.LocalName -cne 'License' -or $licenseXml.DocumentElement.NamespaceURI -cne 'urn:schemas-microsoft-com:windows:store:licensing:ls'){throw 'Package license has an unsupported XML root or namespace.'}
        $directoryProof=Test-AnalysisWindowsPackageZipDirectory -Stream $sourceArchive -MaximumEntries ($files.Count+$directories.Count+1)
        Assert-AnalysisWindowsPayloadRegularPath $output
        $null=New-Item -Path $parent -Name ([IO.Path]::GetFileName($output)) -ItemType Directory -ErrorAction Stop;$created=$true
        Assert-AnalysisWindowsPayloadRegularPath $output
        foreach($kind in 'Archive','License'){
            $source=if($kind -eq 'Archive'){$sourceArchive}else{$sourceLicense};$source.Position=0
            $destination=if($kind -eq 'Archive'){$archivePath}else{$licensePath}
            $limit=if($kind -eq 'Archive'){$archiveLength}else{$licenseLength}
            $writer=[IO.File]::Open($destination,'CreateNew','Write','None');$buffer=[byte[]]::new(65536);[long]$copied=0
            try{while(($count=$source.Read($buffer,0,[int][Math]::Min($buffer.Length,$limit-$copied+1))) -gt 0){$copied+=$count;if($copied -gt $limit){throw 'Package source grew while copying.'};$writer.Write($buffer,0,$count)}}finally{$writer.Dispose()}
            if($copied -ne $limit){throw 'Package source was truncated while copying.'}
            $source.Position=0;$sourceHash=Get-AnalysisWindowsPackageStreamHash -Stream $source -MaximumBytes $limit
            Assert-AnalysisWindowsPayloadRegularPath $destination
            $preserved=[IO.File]::Open($destination,'Open','Read','Read');$streams.Add($preserved)
            $copiedHash=Get-AnalysisWindowsPackageStreamHash -Stream $preserved -MaximumBytes $limit
            if($sourceHash.Bytes -ne $copiedHash.Bytes -or $sourceHash.SHA256 -cne $copiedHash.SHA256){throw 'Preserved package-input bytes differ from source.'}
            $result[$kind+'SHA256']=$sourceHash.SHA256
            if($kind -eq 'Archive'){$preservedArchive=$preserved}
        }
        $preservedArchive.Position=0;$zip=[IO.Compression.ZipArchive]::new($preservedArchive,[IO.Compression.ZipArchiveMode]::Read,$true)
        if($zip.Entries.Count -ne $directoryProof.Entries){throw 'ZIP directory and parsed entry counts disagree.'}
        $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        $matched=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        [long]$declared=0;[long]$expanded=0;$metadataPresent=$false;$directoriesVerified=0
        foreach($entry in $zip.Entries){
            $name=ConvertFrom-AnalysisWindowsPackagePartName $entry.FullName;$isDirectory=$name.EndsWith('/');$key=$name.TrimEnd('/')
            if(-not $seen.Add($key)){throw 'Duplicate or case-colliding package entry.'}
            if($entry.Length -lt 0 -or $entry.CompressedLength -lt 0){throw 'Invalid package entry length.'}
            if(($entry.ExternalAttributes -band 0x400) -ne 0 -or (($entry.ExternalAttributes -shr 16) -band 0xF000) -eq 0xA000){throw 'Reparse or symbolic-link package entry refused.'}
            if($isDirectory){
                if($entry.Length -ne 0 -or -not $expectedDirectories.Contains($key)){throw 'Unexpected or nonempty package directory entry.'}
                $entryStream=$entry.Open();try{$null=Get-AnalysisWindowsPackageStreamHash -Stream $entryStream -MaximumBytes 0}finally{$entryStream.Dispose()}
                $directoriesVerified++;continue
            }
            if($key -ceq '[Content_Types].xml'){$entryLimit=1MB;$metadataPresent=$true}
            elseif($expected.ContainsKey($key)){$entryLimit=[long]$expected[$key].Bytes;if($entry.Length -ne $entryLimit){throw "Package file length differs from payload: $key"}}
            else{throw "Unexpected package file absent from payload: $key"}
            if($entry.Length -gt $entryLimit){throw 'Package entry exceeds its byte limit.'}
            $declared+=$entry.Length;if($declared -gt $MaxPackageBytes+1MB){throw 'Package declared expanded bytes exceed their limit.'}
            $entryStream=$entry.Open()
            try{$entryHash=Get-AnalysisWindowsPackageStreamHash -Stream $entryStream -MaximumBytes $entryLimit}finally{$entryStream.Dispose()}
            if($entryHash.Bytes -ne $entry.Length){throw 'Package expanded length differs from directory metadata.'}
            $expanded+=$entryHash.Bytes;if($expanded -gt $MaxPackageBytes+1MB){throw 'Package actual expanded bytes exceed their limit.'}
            if($key -cne '[Content_Types].xml'){
                if($entryHash.SHA256 -cne $expected[$key].SHA256.ToUpperInvariant()){throw "Package file hash differs from payload: $key"}
                $null=$matched.Add($key)
            }
        }
        if(-not $metadataPresent -or $matched.Count -ne $files.Count){throw 'Package is missing payload files or required [Content_Types].xml metadata.'}
        $zip.Dispose();$zip=$null
        $sourceProof=Test-AnalysisWindowsPackageInputSource -PackageInput ([pscustomobject]$result)
        $payloadProof=Test-AnalysisWindowsPayloadSource -Payload $Payload
        $binding=$licenseXml.DocumentElement.SelectSingleNode('*[local-name()="Binding"]')
        $family=if($binding){$binding.SelectSingleNode('*[local-name()="PFM"]')}else{$null}
        if(($family -and $family.InnerText.Length -gt 1024) -or $licenseXml.DocumentElement.GetAttribute('ContentID').Length -gt 128){throw 'Package license identity metadata exceeds its text limit.'}
        $result.FilesVerified=$matched.Count;$result.ContainerOnlyFiles=@('[Content_Types].xml')
        $result.Validation=[pscustomobject]@{EveryPayloadFileMatched=$true;PayloadSourceUnchanged=($payloadProof.Status -eq 'Completed');PackageInputSourceUnchanged=$sourceProof.SourceUnchanged;DeclaredExpandedBytes=$declared;ActualExpandedBytes=$expanded;DirectoryEntriesVerified=$directoriesVerified;ArchiveEntries=$directoryProof.Entries;CentralDirectoryBytes=$directoryProof.DirectoryBytes;PartNameDecoding='Single-pass strict UTF-8 URI decoding; encoded separators refused';SignatureValidated=$false;LicenseAcceptedByWindows=$false;LicensePackageFamily=if($family){$family.InnerText}else{$null};LicenseContentID=$licenseXml.DocumentElement.GetAttribute('ContentID');Authority='Windows deployment must validate package and license signatures and applicability.'}
        $result.Status='Completed'
        $json=[Text.UTF8Encoding]::new($false).GetBytes(($result|ConvertTo-Json -Depth 12));$writer=[IO.File]::Open($manifestPath,'CreateNew','Write','None')
        try{$writer.Write($json,0,$json.Length)}finally{$writer.Dispose()}
        return [pscustomobject]$result
    }catch{
        $result.Status='Failed';$result.Error=$_.Exception.Message.Substring(0,[Math]::Min(4096,$_.Exception.Message.Length))
        if($created -and -not(Test-Path -LiteralPath $manifestPath)){
            try{Assert-AnalysisWindowsPayloadRegularPath $output;$writer=[IO.File]::Open($manifestPath,'CreateNew','Write','None');try{$bytes=[Text.UTF8Encoding]::new($false).GetBytes(($result|ConvertTo-Json -Depth 12));$writer.Write($bytes,0,$bytes.Length)}finally{$writer.Dispose()}}catch{Write-Verbose 'Failed package-input evidence could not be retained.'}
        }
        throw
    }finally{if($zip){$zip.Dispose()};foreach($stream in $streams){$stream.Dispose()}}
}
