function Find-FilesWithGlobPattern {
    <#
    .SYNOPSIS
    Finds file paths using a filename or relative-path glob.
    .DESCRIPTION
    A leaf pattern (for example *.log) matches at any depth. Relative patterns
    use / or \ between segments; ** matches zero or more directories.
    Each other segment uses PowerShell wildcard syntax (*, ?, [a-z]).
    Reparse points are excluded. No compiler, temporary source or SIMD is used.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string]$GlobPattern)
    $root=(Get-Item -LiteralPath $Path -Force -ErrorAction Stop).FullName
    if (-not [IO.Directory]::Exists($root)) { throw 'Path must be a directory.' }
    if ((Get-Item -LiteralPath $root -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Search root cannot be a reparse point.' }
    $patternParts=$GlobPattern.Replace('\','/').Split('/')
    if (@($patternParts | Where-Object { -not $_ -or $_ -in '.','..' }).Count) { throw 'Use a relative glob without empty, dot or parent segments.' }
    $matchers=@($patternParts | ForEach-Object { [Management.Automation.WildcardPattern]::new($_,'IgnoreCase,CultureInvariant') })
    function Test-GlobSegment([string[]]$Segments,[int]$PatternIndex=0,[int]$SegmentIndex=0) {
        if ($PatternIndex -eq $patternParts.Count) { return $SegmentIndex -eq $Segments.Count }
        if ($patternParts[$PatternIndex] -eq '**') {
            for ($index=$SegmentIndex; $index -le $Segments.Count; $index++) {
                if (Test-GlobSegment $Segments ($PatternIndex+1) $index) { return $true }
            }
            return $false
        }
        if ($SegmentIndex -ge $Segments.Count -or -not $matchers[$PatternIndex].IsMatch($Segments[$SegmentIndex])) { return $false }
        Test-GlobSegment $Segments ($PatternIndex+1) ($SegmentIndex+1)
    }
    $queue=[Collections.Generic.Queue[string]]::new()
    $queue.Enqueue($root)
    $matchesFound=[Collections.Generic.List[string]]::new()
    while ($queue.Count) {
        foreach ($item in Get-ChildItem -LiteralPath $queue.Dequeue() -Force -ErrorAction Stop) {
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
            if ($item.PSIsContainer) { $queue.Enqueue($item.FullName); continue }
            $matchesPattern=if($patternParts.Count -eq 1){$matchers[0].IsMatch($item.Name)}else{
                Test-GlobSegment ([IO.Path]::GetRelativePath($root,$item.FullName).Replace('\','/').Split('/'))
            }
            if ($matchesPattern) { $matchesFound.Add($item.FullName) }
        }
    }
    $matchesFound | Sort-Object
}
