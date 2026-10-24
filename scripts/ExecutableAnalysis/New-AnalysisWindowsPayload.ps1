function Assert-AnalysisWindowsPayloadRegularPath {
    param([string]$LiteralPath)
    $ancestors=[Collections.Generic.Stack[string]]::new()
    $volume=[IO.Path]::GetPathRoot($LiteralPath)
    $relative=$LiteralPath.Substring($volume.Length).TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar)
    if($relative){Assert-AnalysisWindowsPayloadRelativePath $relative -IgnoreDepth}
    $cursor=[IO.Path]::GetFullPath($LiteralPath)
    while($cursor){
        $ancestors.Push($cursor)
        $parent=[IO.Path]::GetDirectoryName($cursor)
        if($parent -eq $cursor){break};$cursor=$parent
    }
    while($ancestors.Count){
        $cursor=$ancestors.Pop()
        # Recheck every ancestor without the filesystem provider's per-path
        # overhead. Only absent paths are tolerated for a new destination;
        # access and other I/O errors must still propagate to the caller.
        try{$attributes=[IO.File]::GetAttributes($cursor)}
        catch [IO.FileNotFoundException]{continue}
        catch [IO.DirectoryNotFoundException]{continue}
        if($attributes -band [IO.FileAttributes]::ReparsePoint){throw "Reparse-point path refused: $cursor"}
    }
}

function Assert-AnalysisWindowsPayloadRelativePath {
    param([string]$Path,[switch]$IgnoreDepth,[ValidateRange(1,64)][int]$DepthLimit=64)
    if(-not $Path -or [IO.Path]::IsPathRooted($Path) -or $Path -match '[<>:"|?*\x00-\x1F]'){throw "Invalid relative Windows payload path: $Path"}
    $parts=$Path -split '[\\/]'
    if(-not $IgnoreDepth -and $parts.Count -gt $depthLimit){throw "Payload directory depth exceeds $depthLimit components."}
    foreach($part in $parts){
        if($part -in '','.','..' -or $part.EndsWith('.') -or $part.EndsWith(' ') -or $part -match '^(?i:CON|PRN|AUX|NUL|CONIN\$|CONOUT\$|COM[1-9\u00B9\u00B2\u00B3]|LPT[1-9\u00B9\u00B2\u00B3])(?:\.|$)'){
            throw "Ambiguous or reserved Windows payload path: $Path"
        }
    }
}

function Get-AnalysisWindowsPayloadFileHash {
    param([string]$LiteralPath)
    Assert-AnalysisWindowsPayloadRegularPath $LiteralPath
    $stream=[IO.File]::Open($LiteralPath,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    $sha=[Security.Cryptography.SHA256]::Create()
    try{return [pscustomobject]@{Bytes=$stream.Length;SHA256=[Convert]::ToHexString($sha.ComputeHash($stream))}}
    finally{$sha.Dispose();$stream.Dispose()}
}

function Test-AnalysisWindowsPayloadSource {
    <#
    .SYNOPSIS
    Reverifies preserved source bytes and the complete selected layout without copying.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][psobject]$Payload)
    $ErrorActionPreference='Stop'
    if($Payload.Schema -ne 'PowerShellProfile.WindowsPayload.v1' -or $Payload.Status -notin 'Building','Completed' -or $Payload.Mode -notin 'SingleFile','DesktopLayout'){throw 'Invalid preserved payload source record.'}
    $files=@($Payload.Files);$directories=@($Payload.Directories|Where-Object {$null -ne $_})
    if($Payload.MaxPackageFiles -lt 1 -or $Payload.MaxPackageFiles -gt 50000 -or $Payload.MaxPackageBytes -lt 1 -or $Payload.MaxPackageBytes -gt 64GB -or $files.Count -lt 1 -or $files.Count -gt $Payload.MaxPackageFiles -or $directories.Count -gt 200000){throw 'Payload source inventory exceeds supported limits.'}
    if($Payload.Mode -eq 'DesktopLayout' -and $null -eq $Payload.PSObject.Properties['Directories']){throw 'The preserved desktop payload has no complete directory inventory.'}
    if($Payload.Mode -eq 'SingleFile' -and ($files.Count -ne 1 -or $directories.Count)){throw 'Single-file source verification refuses extra files or directories.'}
    $entryLimit=4*[int]$Payload.MaxPackageFiles+64
    if($files.Count+$directories.Count -gt $entryLimit){throw 'Payload source inventory exceeds its entry limit.'}
    if(-not [IO.Path]::IsPathFullyQualified($Payload.SourceRoot) -or -not [IO.Path]::IsPathFullyQualified($Payload.SourcePath)){throw 'Payload source paths must be absolute.'}
    Assert-AnalysisWindowsPayloadRegularPath $Payload.SourceRoot
    Assert-AnalysisWindowsPayloadRegularPath $Payload.SourcePath
    $root=[IO.Path]::GetFullPath($Payload.SourceRoot)
    if(-not(Test-Path -LiteralPath $root -PathType Container)){throw 'Payload source root is no longer a directory.'}
    Assert-AnalysisWindowsPayloadRelativePath $Payload.EntryPoint
    $entryPath=[IO.Path]::GetFullPath((Join-Path $root ($Payload.EntryPoint -replace '[\\/]',[IO.Path]::DirectorySeparatorChar)))
    if(-not $entryPath.Equals([IO.Path]::GetFullPath($Payload.SourcePath),[StringComparison]::OrdinalIgnoreCase)){throw 'Payload source entry point and source path disagree.'}
    $expectedNames=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $caseNames=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $expectedDirectories=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    [long]$totalBytes=0;$entryMatched=$false
    foreach($file in $files){
        Assert-AnalysisWindowsPayloadRelativePath $file.Path
        if($file.Bytes -lt 0 -or $file.Bytes -gt $Payload.MaxPackageBytes -or $file.SHA256 -notmatch '^[a-fA-F0-9]{64}$' -or -not $caseNames.Add($file.Path)){throw 'Invalid or duplicate preserved source file record.'}
        $null=$expectedNames.Add($file.Path)
        $totalBytes+=[long]$file.Bytes;if($totalBytes -gt $Payload.MaxPackageBytes){throw 'Payload source bytes exceed their preserved bound.'}
        if($file.Path -ceq $Payload.EntryPoint){if($file.SHA256 -ne $Payload.SourceSHA256){throw 'Preserved source entry-point hashes disagree.'};$entryMatched=$true}
        $original=Join-Path $root ($file.Path -replace '[\\/]',[IO.Path]::DirectorySeparatorChar)
        $current=Get-AnalysisWindowsPayloadFileHash $original
        if($current.Bytes -ne $file.Bytes -or $current.SHA256 -ne $file.SHA256){throw "Source changed during preservation: $($file.Path)"}
    }
    if(-not $entryMatched -or $totalBytes -ne $Payload.TotalBytes){throw 'Payload source entry point or byte totals disagree.'}
    foreach($directory in $directories){
        Assert-AnalysisWindowsPayloadRelativePath $directory
        if(-not $caseNames.Add($directory)){throw 'Duplicate or conflicting preserved directory record.'}
        $null=$expectedNames.Add($directory);$null=$expectedDirectories.Add($directory)
    }
    if($Payload.Mode -eq 'DesktopLayout'){
        $verifiedNames=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        $verificationQueue=[Collections.Generic.Queue[string]]::new();$verificationQueue.Enqueue($root)
        while($verificationQueue.Count){
            $directory=$verificationQueue.Dequeue();Assert-AnalysisWindowsPayloadRegularPath $directory
            foreach($path in [IO.Directory]::EnumerateFileSystemEntries($directory)){
                if($verifiedNames.Count -ge $entryLimit){throw 'Final payload inventory exceeded its entry limit.'}
                Assert-AnalysisWindowsPayloadRegularPath $path
                $item=Get-Item -LiteralPath $path -Force
                $relative=[IO.Path]::GetRelativePath($root,$item.FullName).Replace('\','/')
                Assert-AnalysisWindowsPayloadRelativePath $relative
                if(-not $verifiedNames.Add($relative) -or -not $expectedNames.Contains($relative) -or [bool]$item.PSIsContainer -ne $expectedDirectories.Contains($relative)){throw "Source layout changed during preservation: $relative"}
                if($item.PSIsContainer){$verificationQueue.Enqueue($item.FullName)}
            }
        }
        if($verifiedNames.Count -ne $expectedNames.Count){throw 'Source layout changed during preservation; an inventoried path is missing.'}
    }
    return [pscustomobject]@{Status='Completed';FilesVerified=$files.Count;DirectoriesVerified=$directories.Count}
}

function New-AnalysisWindowsPayload {
    <#
    .SYNOPSIS
    Preserves an executable and its selected desktop layout for isolated guest use.
    .DESCRIPTION
    Creates a new uncompressed ZIP and hash manifest without executing or registering
    target content. Automatic layout discovery is limited to adjacent Appx manifests
    or a resources/app.asar sibling. Reparse points, ambiguous Windows paths and
    incomplete inventories fail closed. Directory depth is bounded to 64 components.
    A failed write retains a Failed manifest and partial archive for diagnosis.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$InputPath,
        [Parameter(Mandatory)][string]$OutputDirectory,
        [string]$ApplicationRoot,
        [ValidateRange(1,68719476736)][long]$MaxPackageBytes=8GB,
        [ValidateRange(1,50000)][int]$MaxPackageFiles=10000
    )
    $ErrorActionPreference='Stop'
    $comparison=[StringComparison]::OrdinalIgnoreCase
    $source=$ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($InputPath)
    $output=$ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputDirectory)
    $depthLimit=64
    $entryLimit=4*$MaxPackageFiles+$depthLimit



    function Test-PayloadContainedPath {
        param([string]$Path,[string]$Root)
        $full=[IO.Path]::GetFullPath($Path).TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar)
        $base=[IO.Path]::GetFullPath($Root).TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar)
        return $full.Equals($base,$comparison) -or $full.StartsWith($base+[IO.Path]::DirectorySeparatorChar,$comparison)
    }

    function Read-PayloadManifest {
        param([string]$LiteralPath,[string]$Root)
        Assert-AnalysisWindowsPayloadRegularPath $LiteralPath
        $stream=[IO.File]::Open($LiteralPath,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
        $reader=$null;$sha=$null
        try{
            if($stream.Length -gt 1MB){throw 'Appx manifest exceeds the 1 MiB metadata limit.'}
            $settings=[Xml.XmlReaderSettings]::new();$settings.DtdProcessing=[Xml.DtdProcessing]::Prohibit;$settings.XmlResolver=$null;$settings.MaxCharactersInDocument=1MB
            $reader=[Xml.XmlReader]::Create($stream,$settings)
            $document=[Xml.XmlDocument]::new();$document.XmlResolver=$null;$document.Load($reader)
            if($document.DocumentElement.LocalName -ne 'Package'){throw 'Appx manifest root must be Package.'}
            $reader.Dispose();$reader=$null;$stream.Position=0
            $sha=[Security.Cryptography.SHA256]::Create();$manifestHash=[Convert]::ToHexString($sha.ComputeHash($stream))
            $identities=@($document.DocumentElement.SelectNodes('./*[local-name()="Identity"]'))
            if($identities.Count -ne 1){throw 'Appx manifest must have exactly one Identity.'}
            $identity=[ordered]@{}
            foreach($name in 'Name','Publisher','Version','ProcessorArchitecture','ResourceId'){$identity[$name]=$identities[0].GetAttribute($name)}
            if(-not $identity.Name -or -not $identity.Version){throw 'Appx identity must declare Name and Version.'}
            $families=@(foreach($node in $document.SelectNodes('/*[local-name()="Package"]/*[local-name()="Dependencies"]/*[local-name()="TargetDeviceFamily"]')){
                $minimum=$node.GetAttribute('MinVersion');if($minimum){$null=[version]::Parse($minimum)}
                [pscustomobject]@{Name=$node.GetAttribute('Name');MinVersion=$minimum;MaxVersionTested=$node.GetAttribute('MaxVersionTested')}
            })
            $applications=@(foreach($node in $document.SelectNodes('/*[local-name()="Package"]/*[local-name()="Applications"]/*[local-name()="Application"]')){
                $attributes=[ordered]@{}
                foreach($attribute in $node.Attributes){if($attribute.Prefix -ne 'xmlns' -and $attribute.Name -ne 'xmlns'){$attributes[$attribute.Name]=$attribute.Value}}
                [pscustomobject]@{Id=$node.GetAttribute('Id');Executable=$node.GetAttribute('Executable');EntryPoint=$node.GetAttribute('EntryPoint');Attributes=[pscustomobject]$attributes}
            })
            $services=@(foreach($node in $document.SelectNodes('//*[local-name()="Service"]')){
                $attributes=[ordered]@{}
                foreach($attribute in $node.Attributes){if($attribute.Prefix -ne 'xmlns' -and $attribute.Name -ne 'xmlns'){$attributes[$attribute.Name]=$attribute.Value}}
                $extension=$node.ParentNode
                while($extension -and $extension.LocalName -ne 'Extension'){$extension=$extension.ParentNode}
                [pscustomobject]@{Name=$node.GetAttribute('Name');Executable=if($extension){$extension.GetAttribute('Executable')}else{''};Category=if($extension){$extension.GetAttribute('Category')}else{''};Attributes=[pscustomobject]$attributes}
            })
            foreach($node in $document.SelectNodes('//*[@Executable]')){
                $declared=$node.GetAttribute('Executable');Assert-AnalysisWindowsPayloadRelativePath $declared
                $resolved=[IO.Path]::GetFullPath((Join-Path $Root ($declared -replace '[\\/]',[IO.Path]::DirectorySeparatorChar)))
                if(-not(Test-PayloadContainedPath $resolved $Root)){throw 'An Appx executable declaration escapes the package root.'}
                Assert-AnalysisWindowsPayloadRegularPath $resolved
                if(-not(Test-Path -LiteralPath $resolved -PathType Leaf)){throw "A declared Appx executable is missing: $declared"}
            }
            $minimumVersions=@($families|Where-Object MinVersion|ForEach-Object{[version]$_.MinVersion}|Sort-Object -Descending)
            return [pscustomobject]@{ManifestPath='AppxManifest.xml';ManifestSHA256=$manifestHash;Identity=[pscustomobject]$identity;TargetDeviceFamilies=$families;MinOSVersion=if($minimumVersions.Count){$minimumVersions[0].ToString()}else{$null};Applications=$applications;Services=$services;RegistrationPerformed=$false}
        }finally{if($reader){$reader.Dispose()};if($sha){$sha.Dispose()};$stream.Dispose()}
    }

    Assert-AnalysisWindowsPayloadRegularPath $source
    $inputItem=Get-Item -LiteralPath $source -Force
    if($inputItem.PSIsContainer -or $inputItem.Extension -ine '.exe' -or -not $inputItem.Length){throw 'InputPath must name a nonempty regular .exe file.'}
    $sourceDirectory=$inputItem.DirectoryName
    # Get-Item can retain caller casing on Windows. Enumerating the literal file
    # name recovers the stored filename instead of renaming it in the payload.
    $sourceMatches=@([IO.Directory]::EnumerateFiles($sourceDirectory,$inputItem.Name,[IO.SearchOption]::TopDirectoryOnly)|Select-Object -First 2)
    if($sourceMatches.Count -ne 1){throw 'Selected executable filename is missing or case-ambiguous.'}
    $source=$sourceMatches[0]
    $root=$sourceDirectory;$rootKind='Standalone';$mode='SingleFile';$package=$null;$manifestSource=$null
    if($ApplicationRoot){
        $root=$ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($ApplicationRoot)
        Assert-AnalysisWindowsPayloadRegularPath $root
        if(-not(Test-Path -LiteralPath $root -PathType Container)){throw 'ApplicationRoot must be an existing regular directory.'}
        $root=(Get-Item -LiteralPath $root -Force).FullName;$rootKind='Explicit';$mode='DesktopLayout'
        $candidate=Join-Path $root 'AppxManifest.xml';Assert-AnalysisWindowsPayloadRegularPath $candidate
        if(Test-Path -LiteralPath $candidate){$manifestSource=$candidate}
    }else{
        foreach($candidateRoot in @($sourceDirectory,[IO.Path]::GetDirectoryName($sourceDirectory))|Where-Object {$_}){
            $candidate=Join-Path $candidateRoot 'AppxManifest.xml';Assert-AnalysisWindowsPayloadRegularPath $candidate
            if(Test-Path -LiteralPath $candidate){$root=$candidateRoot;$rootKind='AppxDirectory';$mode='DesktopLayout';$manifestSource=$candidate;break}
        }
        if(-not $manifestSource){
            $candidate=Join-Path $sourceDirectory 'resources/app.asar';Assert-AnalysisWindowsPayloadRegularPath $candidate
            if(Test-Path -LiteralPath $candidate){
                if(-not(Test-Path -LiteralPath $candidate -PathType Leaf)){throw 'Adjacent app.asar must be a regular file.'}
                $rootKind='Electron';$mode='DesktopLayout'
            }
        }
    }
    $root=[IO.Path]::GetFullPath($root)
    if(-not(Test-PayloadContainedPath $source $root) -or $source.Equals($root,$comparison)){throw 'InputPath must be inside ApplicationRoot.'}
    $entryPoint=[IO.Path]::GetRelativePath($root,$source).Replace('\','/')
    Assert-AnalysisWindowsPayloadRelativePath $entryPoint
    Assert-AnalysisWindowsPayloadRegularPath $output
    if($mode -eq 'DesktopLayout'){
        if((Test-PayloadContainedPath $output $root) -or (Test-PayloadContainedPath $root $output)){throw 'OutputDirectory must not overlap the source root.'}
    }elseif(Test-PayloadContainedPath $source $output){throw 'OutputDirectory must not contain or equal the selected source file.'}
    if(Test-Path -LiteralPath $output){throw 'OutputDirectory already exists; refusing overwrite.'}
    if($manifestSource){$package=Read-PayloadManifest $manifestSource $root}
    if(-not $PSCmdlet.ShouldProcess($output,"Preserve '$source' and the selected $mode layout into a new verified Windows payload")){return}
    $fileList=[Collections.Generic.List[object]]::new()
    $directories=[Collections.Generic.List[string]]::new()
    $paths=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $totalBytes=0L;$entryCount=0
    $queue=[Collections.Generic.Queue[string]]::new()
    if($mode -eq 'DesktopLayout'){$queue.Enqueue($root)}else{$fileList.Add([pscustomobject]@{SourcePath=$source;Path=$entryPoint;Bytes=$inputItem.Length});$totalBytes=$inputItem.Length}
    while($queue.Count){
        $directory=$queue.Dequeue();Assert-AnalysisWindowsPayloadRegularPath $directory
        foreach($path in [IO.Directory]::EnumerateFileSystemEntries($directory)){
            if(++$entryCount -gt $entryLimit){throw "Payload inventory exceeds its $entryLimit-entry limit."}
            Assert-AnalysisWindowsPayloadRegularPath $path
            $item=Get-Item -LiteralPath $path -Force
            $relative=[IO.Path]::GetRelativePath($root,$item.FullName).Replace('\','/')
            Assert-AnalysisWindowsPayloadRelativePath $relative
            if(-not $paths.Add($relative)){throw "Case-colliding payload path: $relative"}
            if($item.PSIsContainer){
                if($directories.Count -ge 200000){throw 'Payload exceeds its 200,000-directory limit.'}
                $directories.Add($relative);$queue.Enqueue($item.FullName);continue
            }
            if($fileList.Count -ge $MaxPackageFiles){throw "Payload exceeds its $MaxPackageFiles-file limit."}
            if($item.Length -gt ($MaxPackageBytes-$totalBytes)){throw 'Payload exceeds its total byte limit.'}
            $fileList.Add([pscustomobject]@{SourcePath=$item.FullName;Path=$relative;Bytes=$item.Length});$totalBytes+=$item.Length
        }
    }
    if($totalBytes -gt $MaxPackageBytes){throw 'Payload exceeds its total byte limit.'}
    $selectedFile=@($fileList|Where-Object {$_.Path.Equals($entryPoint,$comparison)})
    if($selectedFile.Count -ne 1){throw 'Selected executable was absent or ambiguous in the preserved layout.'}
    $entryPoint=$selectedFile[0].Path
    $archivePath=Join-Path $output 'payload.zip';$manifestPath=Join-Path $output 'payload-manifest.json'
    $workingDirectory=([IO.Path]::GetDirectoryName($entryPoint)).Replace('\','/')
    $files=[Collections.Generic.List[object]]::new()
    $result=[ordered]@{Schema='PowerShellProfile.WindowsPayload.v1';Status='Building';Mode=$mode;RootKind=$rootKind;EntryPoint=$entryPoint;WorkingDirectory=$workingDirectory;SourcePath=$source;SourceRoot=$root;Package=$package;Files=$files;Directories=@($directories|Sort-Object);TotalBytes=$totalBytes;SourceSHA256=$null;ArchiveSHA256=$null;ArchivePath=$archivePath;ManifestPath=$manifestPath;MaxPackageBytes=$MaxPackageBytes;MaxPackageFiles=$MaxPackageFiles;DirectoryDepthLimit=$depthLimit;DirectoryLimit=200000;InventoryEntryLimit=$entryLimit;PreservationLimitations=@('File bytes and directory names are preserved; source ACLs, ownership, timestamps and Windows package registration state are not recreated.','Package declarations are untrusted source metadata; copying a layout does not install its dependencies or register its services.')}
    $created=$false;$archiveStream=$null;$zip=$null
    try{
        Assert-AnalysisWindowsPayloadRegularPath $output
        if(Test-Path -LiteralPath $output){throw 'OutputDirectory appeared during inventory; refusing overwrite.'}
        $null=[IO.Directory]::CreateDirectory($output);$created=$true;Assert-AnalysisWindowsPayloadRegularPath $output
        $archiveStream=[IO.File]::Open($archivePath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
        $zip=[IO.Compression.ZipArchive]::new($archiveStream,[IO.Compression.ZipArchiveMode]::Create,$true)
        foreach($file in $fileList|Sort-Object Path){
            Assert-AnalysisWindowsPayloadRegularPath $file.SourcePath
            $inputStream=[IO.File]::Open($file.SourcePath,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
            $entryStream=$null;$sha=[Security.Cryptography.SHA256]::Create()
            try{
                if($inputStream.Length -ne $file.Bytes){throw "Source length changed after inventory: $($file.Path)"}
                $entry=$zip.CreateEntry($file.Path,[IO.Compression.CompressionLevel]::NoCompression)
                $entryStream=$entry.Open();$inputStream.CopyTo($entryStream);$entryStream.Dispose();$entryStream=$null
                $inputStream.Position=0;$hash=[Convert]::ToHexString($sha.ComputeHash($inputStream))
                $files.Add([pscustomobject]@{Path=$file.Path;Bytes=$file.Bytes;SHA256=$hash})
                if($file.Path -ceq $entryPoint){$result.SourceSHA256=$hash}
                if($package -and $file.Path -ieq 'AppxManifest.xml' -and $hash -ne $package.ManifestSHA256){throw 'Appx manifest changed after metadata inspection.'}
            }finally{if($entryStream){$entryStream.Dispose()};$sha.Dispose();$inputStream.Dispose()}
        }
        $zip.Dispose();$zip=$null;$archiveStream.Dispose();$archiveStream=$null
        $null=Test-AnalysisWindowsPayloadSource -Payload ([pscustomobject]$result)
        $result.ArchiveSHA256=(Get-AnalysisWindowsPayloadFileHash $archivePath).SHA256
        $result.Status='Completed'
        $manifestStream=[IO.File]::Open($manifestPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
        try{$bytes=[Text.UTF8Encoding]::new($false).GetBytes(($result|ConvertTo-Json -Depth 12));$manifestStream.Write($bytes,0,$bytes.Length)}finally{$manifestStream.Dispose()}
        return [pscustomobject]$result
    }catch{
        $failure=$_.Exception.Message;$result.Status='Failed';$result.Error=$failure
        if($created -and -not(Test-Path -LiteralPath $manifestPath)){
            try{
                Assert-AnalysisWindowsPayloadRegularPath $output
                $failureStream=[IO.File]::Open($manifestPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
                try{$bytes=[Text.UTF8Encoding]::new($false).GetBytes(($result|ConvertTo-Json -Depth 12));$failureStream.Write($bytes,0,$bytes.Length)}finally{$failureStream.Dispose()}
            }catch{Write-Verbose 'The failed payload manifest could not be retained.'}
        }
        throw
    }finally{if($zip){$zip.Dispose()};if($archiveStream){$archiveStream.Dispose()}}
}
