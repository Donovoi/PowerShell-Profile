function Extract-ZipFile {
    <#
    .SYNOPSIS
    Extracts a ZIP after validating every entry and destination.
    .DESCRIPTION
    Rejects traversal, device names, alternate streams, symbolic links, duplicate
    destinations and existing reparse points. Existing files require -Force.
    Use a destination that other processes cannot modify during extraction.
    Validation precedes writes; an I/O failure can leave earlier entries.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$zipFilePath,
        [Parameter(Mandatory)][string]$outputFolderPath,
        [switch]$Force
    )
    $ErrorActionPreference = 'Stop'
    $source = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($zipFilePath)
    $root = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($outputFolderPath)
    if ($root.Length -gt [IO.Path]::GetPathRoot($root).Length) { $root = $root.TrimEnd('\', '/') }
    $prefix = $root.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    function Assert-PlainPath([string]$Path) {
        for ($part = $Path; $part; $part = [IO.Path]::GetDirectoryName($part)) {
            if (Test-Path -LiteralPath $part) {
                if ((Get-Item -LiteralPath $part -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {
                    throw "ZIP destination contains a reparse point: $part"
                }
            }
        }
    }
    Assert-PlainPath $root
    $archive = [IO.Compression.ZipFile]::OpenRead($source)
    try {
        $seen = [Collections.Generic.Dictionary[string,bool]]::new([StringComparer]::OrdinalIgnoreCase)
        $entries = foreach ($entry in $archive.Entries) {
            $name = $entry.FullName.Replace('/', '\')
            if ([IO.Path]::IsPathRooted($name)) { throw "Rooted ZIP entry: $name" }
            $isDirectory = $name.EndsWith('\')
            foreach ($part in $name.TrimEnd('\').Split('\')) {
                if (-not $part -or $part -in '.', '..' -or $part -match '[<>:"|?*\x00-\x1f]' -or
                    $part -match '[. ]$' -or $part -match '^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])($|\.)') {
                    throw "Unsafe ZIP entry: $name"
                }
            }
            if ((($entry.ExternalAttributes -shr 16) -band 0xF000) -eq 0xA000) { throw "ZIP symbolic link: $name" }
            $target = [IO.Path]::GetFullPath([IO.Path]::Combine($root, $name)).TrimEnd('\')
            if (-not $target.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { throw "ZIP entry escapes destination: $name" }
            if ($target -eq $source) { throw 'ZIP cannot overwrite its own archive.' }
            if ($seen.ContainsKey($target)) { throw "Duplicate ZIP destination: $name" }
            $seen.Add($target, $isDirectory)
            Assert-PlainPath $target
            if (Test-Path -LiteralPath $target) {
                $existing = Get-Item -LiteralPath $target -Force
                if ($existing.PSIsContainer -ne $isDirectory) { throw "ZIP file/directory conflict: $name" }
                if (-not $isDirectory -and -not $Force) { throw "File exists; use -Force: $target" }
            }
            [pscustomobject]@{ Entry = $entry; Target = $target; IsDirectory = $isDirectory }
        }
        foreach ($item in $entries) {
            for ($parent = [IO.Path]::GetDirectoryName($item.Target); $parent -and $parent.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase); $parent = [IO.Path]::GetDirectoryName($parent)) {
                if (($seen.ContainsKey($parent) -and -not $seen[$parent]) -or [IO.File]::Exists($parent)) { throw "ZIP parent is a file: $parent" }
            }
        }
        if (-not $PSCmdlet.ShouldProcess($root, "Extract $($archive.Entries.Count) validated ZIP entries")) { return }
        $null = [IO.Directory]::CreateDirectory($root)
        foreach ($item in $entries) {
            Assert-PlainPath $item.Target
            if ($item.IsDirectory) { $null = [IO.Directory]::CreateDirectory($item.Target); continue }
            $null = [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($item.Target))
            $temporary = $item.Target + '.' + [guid]::NewGuid().ToString('N') + '.partial'
            try {
                [IO.Compression.ZipFileExtensions]::ExtractToFile($item.Entry, $temporary, $false)
                [IO.File]::Move($temporary, $item.Target, [bool]$Force)
            }
            finally { if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) } }
        }
    }
    finally { $archive.Dispose() }
}
