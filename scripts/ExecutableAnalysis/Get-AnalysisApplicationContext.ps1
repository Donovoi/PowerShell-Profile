function Get-AnalysisApplicationContext {
    <#
    .SYNOPSIS
    Preserves bounded adjacent application metadata and ASAR companions.
    .DESCRIPTION
    Internal helper called after the analysis command's ShouldProcess decision.
    Reads only fixed adjacent candidates and a bounded ASAR unpacked tree. It does
    not execute targets, parse ASAR contents, install dependencies or follow links.
    PreservedFiles.RelativePath is relative to RunDirectory. Inventory.RelativePath
    identifies the source layout; native entry points are inventoried, not copied.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$SourcePath,
        [Parameter(Mandatory)][string]$RunDirectory,
        [Parameter(Mandatory)][ValidateRange(0,9223372036854775807)][long]$MaxCompanionBytes,
        [string]$PreservedInputPath
    )
    $ErrorActionPreference='Stop'
    $comparison=if($IsWindows){[StringComparison]::OrdinalIgnoreCase}else{[StringComparison]::Ordinal}
    $comparer=if($IsWindows){[StringComparer]::OrdinalIgnoreCase}else{[StringComparer]::Ordinal}
    $inventory=[Collections.Generic.List[object]]::new()
    $preserved=[Collections.Generic.List[object]]::new()
    $entryPoints=[Collections.Generic.List[object]]::new()
    $limitations=[Collections.Generic.List[string]]::new()
    $seen=[Collections.Generic.HashSet[string]]::new($comparer)
    $state=@{Partial=$false;Detected=$false;Bytes=0L;InventoryFull=$false}
    $run=$ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($RunDirectory)
    $source=$ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($SourcePath)
    $applicationRoot=[IO.Path]::GetDirectoryName($source)
    $packageRoot=$null
    $reportPath=Join-Path $run 'basic/application-context.json'
    $copyRoot=Join-Path $run 'application/input'
    $runPrefix=$run.TrimEnd([IO.Path]::DirectorySeparatorChar)+[IO.Path]::DirectorySeparatorChar

    function Add-ContextLimitation {
        param([string]$Message,[switch]$Partial)
        if(-not $limitations.Contains($Message)){$limitations.Add($Message)}
        if($Partial){$state.Partial=$true}
    }
    function Assert-ContextRegularPath {
        param([string]$LiteralPath)
        $cursor=[IO.Path]::GetFullPath($LiteralPath)
        $ancestors=[Collections.Generic.Stack[string]]::new()
        while($cursor){
            $ancestors.Push($cursor)
            $parent=[IO.Path]::GetDirectoryName($cursor)
            if($parent -eq $cursor){break};$cursor=$parent
        }
        # Inspect parents before children, so a linked directory is never traversed.
        while($ancestors.Count){
            $cursor=$ancestors.Pop();$item=$null
            try{$item=Get-Item -LiteralPath $cursor -Force -ErrorAction Stop}
            catch{if($_.CategoryInfo.Category -ne 'ObjectNotFound'){throw}}
            if($item -and ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw "Reparse-point path refused: $cursor"}
        }
    }
    function Get-ContextCandidate {
        param([string]$LiteralPath,[string]$RelativePath,[string]$Kind)
        try{
            Assert-ContextRegularPath $LiteralPath
            Get-Item -LiteralPath $LiteralPath -Force -ErrorAction Stop
        }catch{
            if($_.CategoryInfo.Category -eq 'ObjectNotFound'){return}
            $state.Detected=$true
            $null=Add-ContextInventory -LiteralPath $LiteralPath -RelativePath $RelativePath -Kind $Kind -Status 'Refused' -Reason $_.Exception.Message
            Add-ContextLimitation ("Adjacent candidate refused ($RelativePath): $($_.Exception.Message)") -Partial
        }
    }
    function Add-ContextInventory {
        param([string]$LiteralPath,[string]$RelativePath,[string]$Kind,[string]$Status='Discovered',[string]$Reason)
        if($inventory.Count -ge 5000){
            $state.InventoryFull=$true
            Add-ContextLimitation 'Application inventory stopped at 5,000 entries; further entries were not inspected or preserved.' -Partial
            return $null
        }
        $row=[pscustomobject]@{SourcePath=$LiteralPath;RelativePath=$RelativePath;Kind=$Kind;Bytes=$null;SHA256=$null;Status=$Status;Reason=$Reason;RetainedPath=$null}
        $inventory.Add($row)
        return $row
    }
    function Save-ContextFile {
        param($Row,[string]$Destination,[switch]$Metadata,[switch]$Reuse)
        $created=$false;$inputStream=$null;$outputStream=$null
        try {
            Assert-ContextRegularPath $Row.SourcePath
            $item=Get-Item -LiteralPath $Row.SourcePath -Force
            if($item.PSIsContainer){throw 'Expected a regular file, found a directory.'}
            $inputStream=[IO.File]::Open($item.FullName,'Open','Read','Read')
            $Row.Bytes=$inputStream.Length
            if($Metadata -and $Row.Bytes -gt 1MB){throw 'Metadata exceeds the 1 MiB read/copy limit.'}
            if(-not $Reuse -and $Row.Bytes -gt ($MaxCompanionBytes-$state.Bytes)){
                $Row.Status='Omitted';$Row.Reason='The total companion copy budget is exhausted.'
                Add-ContextLimitation ("Companion not preserved within the copy budget: "+$Row.RelativePath) -Partial
                return
            }
            $destinationFull=[IO.Path]::GetFullPath($Destination)
            if(-not $destinationFull.StartsWith($runPrefix,$comparison)){throw 'Companion destination escapes RunDirectory.'}
            Assert-ContextRegularPath $destinationFull
            if($Reuse){
                $retained=Get-Item -LiteralPath $destinationFull -Force
                if($retained.PSIsContainer){throw 'PreservedInputPath must be a regular file.'}
            }else{
                $null=[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($destinationFull))
                Assert-ContextRegularPath ([IO.Path]::GetDirectoryName($destinationFull))
                $outputStream=[IO.File]::Open($destinationFull,'CreateNew','Write','None');$created=$true
                $inputStream.CopyTo($outputStream);$outputStream.Dispose();$outputStream=$null
            }
            $inputStream.Position=0
            $sha=[Security.Cryptography.SHA256]::Create()
            try{$sourceHash=[Convert]::ToHexString($sha.ComputeHash($inputStream))}finally{$sha.Dispose()}
            $retainedHash=(Get-FileHash -LiteralPath $destinationFull -Algorithm SHA256).Hash
            if($retainedHash -ne $sourceHash){throw 'Retained companion SHA256 differs from its locked source.'}
            $Row.SHA256=$sourceHash;$Row.Status='Preserved';$Row.RetainedPath=$destinationFull
            if(-not $Reuse){$state.Bytes+=$Row.Bytes}
            $preserved.Add([pscustomobject]@{SourcePath=$item.FullName;Path=$destinationFull;RelativePath=[IO.Path]::GetRelativePath($run,$destinationFull);SHA256=$sourceHash;Bytes=$Row.Bytes;Kind=$Row.Kind;ReusedInput=[bool]$Reuse})
        }catch{
            $Row.Status='Refused';$Row.Reason=$_.Exception.Message
            Add-ContextLimitation ("Companion could not be preserved ($($Row.RelativePath)): $($_.Exception.Message)") -Partial
            if($created){if($outputStream){$outputStream.Dispose();$outputStream=$null};[IO.File]::Delete($Destination)}
        }finally{if($outputStream){$outputStream.Dispose()};if($inputStream){$inputStream.Dispose()}}
    }
    function Read-ContextMetadataFile {
        param($Row)
        Assert-ContextRegularPath $Row.SourcePath
        $readPath=if($Row.RetainedPath){$Row.RetainedPath}else{$Row.SourcePath}
        $stream=[IO.File]::Open($readPath,'Open','Read','Read')
        try{
            if($stream.Length -gt 1MB){throw 'Metadata exceeds the 1 MiB read limit.'}
            $bytes=[byte[]]::new([int]$stream.Length);$offset=0
            while($offset -lt $bytes.Length){$count=$stream.Read($bytes,$offset,$bytes.Length-$offset);if(-not $count){throw 'Metadata ended before its declared length.'};$offset+=$count}
            return ,$bytes
        }finally{$stream.Dispose()}
    }
    function Read-ContextManifest {
        param($Row,[string]$Root)
        $reader=$null;$memory=$null
        try{
            $bytes=Read-ContextMetadataFile -Row $Row
            $settings=[Xml.XmlReaderSettings]::new();$settings.DtdProcessing=[Xml.DtdProcessing]::Prohibit;$settings.XmlResolver=$null;$settings.MaxCharactersInDocument=1MB
            $memory=[IO.MemoryStream]::new($bytes,$false);$reader=[Xml.XmlReader]::Create($memory,$settings)
            $document=[Xml.XmlDocument]::new();$document.XmlResolver=$null;$document.Load($reader)
            if($document.DocumentElement.LocalName -ne 'Package'){throw 'The XML root is not an Appx Package.'}
            foreach($node in $document.SelectNodes('//*[local-name()="Application" or local-name()="Extension"][@Executable]')){
                if($state.InventoryFull){break}
                $declared=$node.GetAttribute('Executable');$resolved=$null;$reason=$null;$exists=$false
                try{
                    $parts=$declared -split '[\\/]'
                    if(-not $declared -or [IO.Path]::IsPathRooted($declared) -or $declared -match '[:*?\x00]' -or @($parts|Where-Object {$_ -in '.','..','' -or $_.EndsWith('.') -or $_.EndsWith(' ')}).Count){throw 'Declared executable path is rooted, ambiguous or traverses its package root.'}
                    $resolved=[IO.Path]::GetFullPath((Join-Path $Root ($parts -join [IO.Path]::DirectorySeparatorChar)))
                    $prefix=$Root.TrimEnd([IO.Path]::DirectorySeparatorChar)+[IO.Path]::DirectorySeparatorChar
                    if(-not $resolved.StartsWith($prefix,$comparison)){throw 'Declared executable escapes its package root.'}
                    Assert-ContextRegularPath $resolved
                    $entry=Get-Item -LiteralPath $resolved -Force -ErrorAction Stop
                    if($entry.PSIsContainer){throw 'Declared executable is not a regular file.'}
                    $exists=$true
                }catch{$reason=$_.Exception.Message;Add-ContextLimitation ("Declared entry point was not verified ($declared): $reason") -Partial}
                $row=Add-ContextInventory -LiteralPath $resolved -RelativePath $declared -Kind 'DeclaredEntryPoint' -Status $(if($exists){'Inventoried'}else{'Refused'}) -Reason $reason
                if(-not $row){break};if($exists){$row.Bytes=$entry.Length}
                $entryPoints.Add([pscustomobject]@{DeclaredPath=$declared;SourcePath=$resolved;Exists=$exists;Element=$node.LocalName;Id=$node.GetAttribute('Id');EntryPoint=$node.GetAttribute('EntryPoint');SelectedInput=[bool]($resolved -and $resolved.Equals($source,$comparison));Preserved=$false;Reason=$reason})
            }
        }catch{Add-ContextLimitation ("Appx manifest could not be parsed safely: $($_.Exception.Message)") -Partial}
        finally{if($reader){$reader.Dispose()};if($memory){$memory.Dispose()}}
    }

    Assert-ContextRegularPath $run
    if(-not(Test-Path -LiteralPath $run -PathType Container)){throw 'RunDirectory must be an existing regular directory.'}
    Assert-ContextRegularPath $reportPath
    if(Test-Path -LiteralPath $reportPath){throw 'Application context report already exists; refusing overwrite.'}
    if(Test-Path -LiteralPath (Join-Path $run 'application')){throw 'Application context output already exists; refusing overwrite.'}
    $null=[IO.Directory]::CreateDirectory((Join-Path $run 'basic'))
    try{
        Assert-ContextRegularPath $source
        $sourceItem=Get-Item -LiteralPath $source -Force
        if($sourceItem.PSIsContainer -or $sourceItem.PSProvider.Name -ne 'FileSystem'){throw 'SourcePath must identify one regular filesystem file.'}
        $directAsar=$sourceItem.Extension -eq '.asar'
        if($PreservedInputPath -and -not $directAsar){throw 'PreservedInputPath is only used for a directly selected ASAR.'}
        $candidates=[Collections.Generic.List[object]]::new()
        foreach($relative in @('package.json','owl-shell-runtime.json','owl-electron-app.json','owl-app.ini','resources/package.json','resources/owl-shell-runtime.json','resources/owl-electron-app.json','resources/owl-app.ini')){
            $candidates.Add([pscustomobject]@{Path=(Join-Path $applicationRoot $relative);Relative=$relative;Kind='ApplicationMetadata'})
        }
        $manifest=Join-Path $applicationRoot 'AppxManifest.xml'
        $manifestItem=Get-ContextCandidate -LiteralPath $manifest -RelativePath 'AppxManifest.xml' -Kind 'AppxManifest'
        if(-not $manifestItem){
            $parent=[IO.Path]::GetDirectoryName($applicationRoot)
            if($parent){$manifest=Join-Path $parent 'AppxManifest.xml';$manifestItem=Get-ContextCandidate -LiteralPath $manifest -RelativePath 'AppxManifest.xml' -Kind 'AppxManifest'}
        }
        if($manifestItem){$packageRoot=[IO.Path]::GetDirectoryName($manifest);$candidates.Insert(0,[pscustomobject]@{Path=$manifest;Relative='AppxManifest.xml';Kind='AppxManifest'})}
        foreach($candidate in $candidates){
            if($state.InventoryFull){break}
            $item=Get-ContextCandidate -LiteralPath $candidate.Path -RelativePath $candidate.Relative -Kind $candidate.Kind
            if(-not $item){continue}
            $state.Detected=$true
            $row=Add-ContextInventory -LiteralPath $candidate.Path -RelativePath $candidate.Relative -Kind $candidate.Kind
            if(-not $row){break}
            Save-ContextFile $row (Join-Path $copyRoot $candidate.Relative) -Metadata
            if($candidate.Kind -eq 'AppxManifest' -and $row.Status -ne 'Refused'){Read-ContextManifest $row $packageRoot}
        }
        $asarPath=if($directAsar){$source}else{Join-Path $applicationRoot 'resources/app.asar'}
        $asarRelative=if($directAsar){$sourceItem.Name}else{'resources/app.asar'}
        $asarDestination=Join-Path $copyRoot $asarRelative
        if($directAsar -and $PreservedInputPath){$asarDestination=$ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($PreservedInputPath)}
        $asarItem=Get-ContextCandidate -LiteralPath $asarPath -RelativePath $asarRelative -Kind 'AsarCandidate'
        $sidecarPath=$asarPath+'.unpacked';$sidecarDestination=$asarDestination+'.unpacked'
        $sidecarItem=Get-ContextCandidate -LiteralPath $sidecarPath -RelativePath ($asarRelative+'.unpacked') -Kind 'AsarUnpackedDirectory'
        if($asarItem -or $sidecarItem){
            $state.Detected=$true
            if($asarItem){
                $row=Add-ContextInventory -LiteralPath $asarPath -RelativePath $asarRelative -Kind 'AsarCandidate'
                if($row){Save-ContextFile $row $asarDestination -Reuse:($directAsar -and [bool]$PreservedInputPath)}
            }else{Add-ContextLimitation 'An unpacked sidecar exists without its adjacent ASAR candidate.' -Partial}
            if(-not $sidecarItem){
                if(-not @($inventory|Where-Object {$_.SourcePath -eq $sidecarPath -and $_.Status -eq 'Refused'}).Count){
                    $null=Add-ContextInventory -LiteralPath $sidecarPath -RelativePath ($asarRelative+'.unpacked') -Kind 'AsarUnpackedDirectory' -Status 'Absent' -Reason 'No sidecar was found; only ASAR inspection can determine whether one is required.'
                    Add-ContextLimitation 'No adjacent ASAR unpacked directory was found. Whether unpacked members are required remains unknown until archive inspection.'
                }
            }else{
                if(Test-Path -LiteralPath $sidecarDestination){throw 'Retained ASAR sidecar destination already exists; refusing overwrite.'}
                $stack=[Collections.Generic.Stack[object]]::new();$stack.Push(@{Path=$sidecarPath;Relative=($asarRelative+'.unpacked');Depth=0;Destination=$sidecarDestination})
                while($stack.Count -and -not $state.InventoryFull){
                    $directory=$stack.Pop();$row=if($directory.Row){$directory.Row}else{Add-ContextInventory -LiteralPath $directory.Path -RelativePath $directory.Relative -Kind 'AsarUnpackedDirectory'}
                    if(-not $row){break}
                    try{
                        Assert-ContextRegularPath $directory.Path
                        if(-not(Test-Path -LiteralPath $directory.Path -PathType Container)){throw 'ASAR unpacked path is not a directory.'}
                        if([IO.Path]::GetFullPath($directory.Path).StartsWith($runPrefix,$comparison) -or [IO.Path]::GetFullPath($directory.Path).Equals($run,$comparison)){throw 'Refusing to inventory the current analysis output as input.'}
                        $row.Status='Inventoried'
                        foreach($path in [IO.Directory]::EnumerateFileSystemEntries($directory.Path)){
                            if($state.InventoryFull){break}
                            $relative=Join-Path $directory.Relative ([IO.Path]::GetFileName($path))
                            $destination=Join-Path $directory.Destination ([IO.Path]::GetFileName($path))
                            $item=Get-Item -LiteralPath $path -Force
                            if($item.PSIsContainer -and -not($item.Attributes -band [IO.FileAttributes]::ReparsePoint)){
                                if($directory.Depth -ge 16){$null=Add-ContextInventory -LiteralPath $path -RelativePath $relative -Kind 'AsarUnpackedDirectory' -Status 'Omitted' -Reason 'Directory depth exceeds 16.';Add-ContextLimitation ("Unpacked directory depth limit reached: $relative") -Partial}
                                else{
                                    $childRow=Add-ContextInventory -LiteralPath $path -RelativePath $relative -Kind 'AsarUnpackedDirectory'
                                    if($childRow){$stack.Push(@{Path=$path;Relative=$relative;Depth=$directory.Depth+1;Destination=$destination;Row=$childRow})}
                                }
                            }else{
                                if(-not $seen.Add($path)){continue}
                                $fileRow=Add-ContextInventory -LiteralPath $path -RelativePath $relative -Kind 'AsarUnpackedFile'
                                if($fileRow){Save-ContextFile $fileRow $destination}
                            }
                        }
                    }catch{$row.Status='Refused';$row.Reason=$_.Exception.Message;Add-ContextLimitation ("Unpacked directory was not fully inspected ($($directory.Relative)): $($_.Exception.Message)") -Partial}
                }
            }
            Add-ContextLimitation 'The ApplicationContext collection stage does not inspect ASAR members. Consult subsequent REA inspection, extraction and retained-file verification for archive coverage; this collection-stage limit does not describe those later results.'
        }
    }catch{Add-ContextLimitation $_.Exception.Message -Partial}
    foreach($row in $inventory){if($row.Status -eq 'Discovered'){$row.Status='Omitted';$row.Reason='Inventory limits or an earlier failure prevented inspection.';$state.Partial=$true}}
    if($state.Detected){Add-ContextLimitation 'This is bounded adjacent application context, not a complete package snapshot. Native entry-point binaries, DLL dependencies, package registration, user data and runtime activation are not preserved or exercised.'}
    $result=[pscustomobject]@{SchemaVersion=1;Status=$(if($state.Partial){'Partial'}elseif($state.Detected){'Completed'}else{'Skipped'});Detected=$state.Detected;ApplicationRoot=$applicationRoot;PackageRoot=$packageRoot;EntryPoints=$entryPoints.ToArray();PreservedFiles=$preserved.ToArray();Inventory=$inventory.ToArray();Limitations=$limitations.ToArray();Scope='Fixed adjacent metadata, source-directory or immediate-parent Appx manifest, one ASAR candidate and its bounded unpacked sidecar only.';CopiedBytes=$state.Bytes;MaxCompanionBytes=$MaxCompanionBytes;InventoryLimit=5000;DirectoryDepthLimit=16;MetadataByteLimit=1MB}
    $bytes=[Text.UTF8Encoding]::new($false).GetBytes(($result|ConvertTo-Json -Depth 10))
    $stream=[IO.File]::Open($reportPath,'CreateNew','Write','None')
    try{$stream.Write($bytes,0,$bytes.Length)}finally{$stream.Dispose()}
    return $result
}
