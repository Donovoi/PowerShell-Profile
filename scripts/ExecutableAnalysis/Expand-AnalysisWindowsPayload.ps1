function Expand-AnalysisWindowsPayload {
    # Trusted guest preparation. This reads data only; it never loads target code.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ManifestPath,
        [Parameter(Mandatory)][ValidatePattern('^[a-fA-F0-9]{64}$')][string]$ExpectedManifestSHA256,
        [Parameter(Mandatory)][string]$ArchivePath,
        [Parameter(Mandatory)][string]$OutputDirectory
    )
    $ErrorActionPreference='Stop'
    function Get-PayloadHash([string]$Path) {
        $stream=[IO.File]::OpenRead($Path);$hasher=[Security.Cryptography.SHA256]::Create()
        try{([BitConverter]::ToString($hasher.ComputeHash($stream))).Replace('-','')}finally{$hasher.Dispose();$stream.Dispose()}
    }
    function Assert-PayloadPath([string]$Path) {
        if([string]::IsNullOrWhiteSpace($Path) -or $Path.Length -gt 30000 -or $Path -match '[\\:\x00-\x1f]' -or $Path.StartsWith('/')){throw 'Invalid payload relative path.'}
        $parts=$Path.Split('/')
        if($parts.Count -gt 65){throw 'Payload path exceeds the depth limit.'}
        foreach($part in $parts){
            if(-not $part -or $part -in '.','..' -or $part -match '[<>"|?*]' -or $part -match '[. ]$' -or $part -match '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)'){throw 'Unsafe payload path component.'}
        }
    }
    function Assert-RegularAncestor([string]$Path) {
        $cursor=[IO.Path]::GetFullPath($Path)
        while($cursor){
            if(Test-Path -LiteralPath $cursor){if((Get-Item -LiteralPath $cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Payload paths cannot traverse reparse points.'}}
            $parent=[IO.Path]::GetDirectoryName($cursor);if($parent -eq $cursor){break};$cursor=$parent
        }
    }
    foreach($path in @($ManifestPath,$ArchivePath,$OutputDirectory)){Assert-RegularAncestor $path}
    if((Get-Item -LiteralPath $ManifestPath).Length -gt 32MB){throw 'Payload manifest exceeds 32 MiB.'}
    if((Get-PayloadHash $ManifestPath) -ne $ExpectedManifestSHA256){throw 'Payload manifest hash does not match the host.'}
    $manifest=Get-Content -LiteralPath $ManifestPath -Raw -Encoding UTF8|ConvertFrom-Json
    if($manifest.Schema -ne 'PowerShellProfile.WindowsPayload.v1' -or $manifest.Status -ne 'Completed' -or $manifest.Mode -notin 'SingleFile','DesktopLayout'){throw 'Invalid payload manifest.'}
    if(@($manifest.Files).Count -lt 1 -or @($manifest.Files).Count -gt 50000 -or $manifest.TotalBytes -lt 1 -or $manifest.TotalBytes -gt 64GB){throw 'Payload manifest exceeds supported bounds.'}
    if((Get-PayloadHash $ArchivePath) -ne $manifest.ArchiveSHA256){throw 'Payload archive hash does not match the host.'}
    $expected=New-Object 'Collections.Generic.Dictionary[string,object]' ([StringComparer]::OrdinalIgnoreCase)
    [long]$declaredBytes=0
    foreach($row in $manifest.Files){
        Assert-PayloadPath $row.Path
        if($row.SHA256 -notmatch '^[a-fA-F0-9]{64}$' -or $row.Bytes -lt 0 -or $row.Bytes -gt 64GB -or $expected.ContainsKey($row.Path)){throw 'Invalid or duplicate payload file record.'}
        $expected.Add($row.Path,$row);$declaredBytes+=[long]$row.Bytes
        if($declaredBytes -gt 64GB){throw 'Payload file bytes exceed the limit.'}
    }
    if($declaredBytes -ne $manifest.TotalBytes){throw 'Payload byte totals disagree.'}
    Assert-PayloadPath $manifest.EntryPoint
    if(-not $expected.ContainsKey($manifest.EntryPoint) -or $expected[$manifest.EntryPoint].SHA256 -ne $manifest.SourceSHA256){throw 'Payload entry point identity is missing or inconsistent.'}
    if(Test-Path -LiteralPath $OutputDirectory){throw 'Payload extraction destination already exists.'}
    $root=[IO.Path]::GetFullPath($OutputDirectory).TrimEnd('\','/')
    $null=[IO.Directory]::CreateDirectory($root)
    if(@($manifest.Directories).Count -gt 200000){throw 'Payload directory inventory exceeds its limit.'}
    $directories=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach($directory in $manifest.Directories){
        if($null -eq $directory){continue}
        Assert-PayloadPath $directory
        if(-not $directories.Add($directory) -or $expected.ContainsKey($directory)){throw 'Duplicate or conflicting payload directory.'}
        $null=[IO.Directory]::CreateDirectory(('\\?\'+$root+'\'+$directory.Replace('/','\')))
    }
    Add-Type -AssemblyName System.IO.Compression
    $inputStream=[IO.File]::OpenRead($ArchivePath);$archive=$null
    $copied=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    [long]$copiedBytes=0
    try {
        $archive=New-Object IO.Compression.ZipArchive($inputStream,[IO.Compression.ZipArchiveMode]::Read,$false)
        if($archive.Entries.Count -ne $expected.Count){throw 'Archive entry count differs from the manifest.'}
        # Reuse the bounded buffer instead of allocating a large object per member.
        $buffer=New-Object byte[] 1048576
        foreach($entry in $archive.Entries){
            Assert-PayloadPath $entry.FullName
            if(-not $expected.ContainsKey($entry.FullName) -or -not $copied.Add($entry.FullName)){throw 'Unexpected or duplicate ZIP entry.'}
            $row=$expected[$entry.FullName]
            if($entry.Length -ne $row.Bytes){throw 'ZIP member length differs from its manifest.'}
            # All components have been validated; the extended prefix supports deep
            # package assets under Windows PowerShell 5.1 without path normalization.
            $destination='\\?\'+$root+'\'+$entry.FullName.Replace('/','\')
            $null=[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($destination))
            $sourceStream=$entry.Open();$destinationStream=$null
            try {
                $destinationStream=[IO.File]::Open($destination,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
                [long]$written=0
                while(($count=$sourceStream.Read($buffer,0,$buffer.Length)) -gt 0){
                    $written+=$count;if($written -gt $row.Bytes){throw 'ZIP member exceeded its declared size.'}
                    $destinationStream.Write($buffer,0,$count)
                }
                if($written -ne $row.Bytes){throw 'ZIP member ended before its declared size.'}
            }finally{if($destinationStream){$destinationStream.Dispose()};$sourceStream.Dispose()}
            if((Get-PayloadHash $destination) -ne $row.SHA256){throw 'Extracted payload member SHA256 differs from its preserved source.'}
            $copiedBytes+=$written
        }
    }finally{if($archive){$archive.Dispose()};$inputStream.Dispose()}
    if($copied.Count -ne $expected.Count -or $copiedBytes -ne $declaredBytes){throw 'Payload extraction is incomplete.'}
    [pscustomobject]@{Status='Completed';ManifestSHA256=$ExpectedManifestSHA256;ArchiveSHA256=$manifest.ArchiveSHA256;FilesVerified=$copied.Count;BytesVerified=$copiedBytes;EntryPoint=$manifest.EntryPoint;SourceSHA256=$manifest.SourceSHA256;Root=$root;Mode=$manifest.Mode;RootKind=$manifest.RootKind}
}
