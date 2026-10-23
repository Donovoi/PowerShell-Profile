function Copy-FileSystemArtifact {
    <#
    .SYNOPSIS
    Collects files, including LOG files, with per-file provenance and honest totals.
    .DESCRIPTION
    Literal paths take priority over wildcard interpretation. Glob paths support
    ** and preserve paths relative to the fixed prefix. A literal directory is
    copied under its own name. Reparse points are reported as unsupported.
    Success means every selected file was verified; partial collections are explicit.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][string]$SourcePath,[Parameter(Mandatory)][string]$DestinationPath,[pscustomobject[]]$ForensicTools=@())
    $result=[pscustomobject]@{Success=$false;PartialSuccess=$false;FilesCollected=0;FilesFailed=0;Errors=@();Files=@()}
    try {
        if(-not (Get-Command Initialize-CmdletDependencies -ErrorAction SilentlyContinue)){. (Join-Path $PSScriptRoot 'Initialize-CmdletDependencies.ps1')}
        Initialize-CmdletDependencies -RequiredCmdlets @('Copy-StandardFile','Copy-LockedFile','Find-FilesWithGlobPattern') -PreferLocal -ErrorAction Stop
        $destination=$ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($DestinationPath)
        if(Test-Path -LiteralPath $SourcePath){
            $item=Get-Item -LiteralPath $SourcePath -Force -ErrorAction Stop
            if($item.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Reparse-point sources are unsupported.'}
            if($item.PSIsContainer){$base=$item.FullName;$destination=Join-Path $destination $item.Name;$pattern='*'}
            else{$base=$item.DirectoryName;$files=@($item);$pattern=$null}
        } else {
            $normalized=$ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($SourcePath).Replace('/','\')
            $wildcard=$normalized.IndexOfAny([char[]]'*?[')
            if($wildcard -lt 0){throw "Source does not exist: $SourcePath"}
            $separator=$normalized.LastIndexOf('\',$wildcard)
            if($separator -lt 0){throw 'Glob must have a fixed parent directory.'}
            $base=$normalized.Substring(0,$separator+1).TrimEnd('\')
            if($base -match '^[A-Za-z]:$'){$base+='\'}
            $pattern=$normalized.Substring($separator+1)
        }
        $base=[IO.Path]::GetFullPath($base)
        if($destination -eq $base -or $destination.StartsWith($base.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Collection destination must be outside the source tree.'}
        if($pattern){
            $files=@(Find-FilesWithGlobPattern -Path $base -GlobPattern $pattern | ForEach-Object {Get-Item -LiteralPath $_ -Force -ErrorAction Stop})
            # Enumeration does not follow junctions. Report exclusions rather than claiming completeness.
            $links=@(Get-ChildItem -LiteralPath $base -Recurse -Force -Attributes ReparsePoint -ErrorAction Stop)
            foreach($link in $links){$result.Errors+="Unsupported reparse point: $($link.FullName)"}
        }
        if(-not $files.Count){throw "No matching files: $SourcePath"}
        foreach($file in $files){
            $relative=[IO.Path]::GetRelativePath($base,$file.FullName)
            $target=Join-Path $destination $relative
            $record=Copy-StandardFile -SourceFile $file.FullName -DestinationFile $target -PassThru
            if(-not $record.Success -and $ForensicTools.Count){$record=Copy-LockedFile -SourceFile $file.FullName -DestinationFile $target -ForensicTools $ForensicTools -PassThru}
            $result.Files+= $record
            if($record.Success){$result.FilesCollected++}else{$result.FilesFailed++;$result.Errors+="$($file.FullName): $($record.Error)"}
        }
    }
    catch {$result.Errors+=$_.Exception.Message}
    $result.Success=$result.FilesCollected -gt 0 -and $result.Errors.Count -eq 0
    $result.PartialSuccess=$result.FilesCollected -gt 0 -and -not $result.Success
    $result
}
