function Copy-StandardFile {
    <#
    .SYNOPSIS
    Copies stable logical file bytes with SHA256 verification and staged publication.
    .DESCRIPTION
    The source is held with read-only sharing during copying and hashing. Returns
    a boolean for compatibility, or a detailed record with -PassThru.
    Includes all extensions. Does not copy ACLs or alternate data streams.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$SourceFile,[Parameter(Mandatory)][string]$DestinationFile,[switch]$PassThru)
    $record=[pscustomobject]@{Success=$false;Source=$SourceFile;Destination=$DestinationFile;Length=0L;SHA256=$null;Verified=$false;Method='LogicalStream';Error=$null}
    $inputStream=$null;$outputStream=$null;$temporary=$null
    try {
        $source=(Get-Item -LiteralPath $SourceFile -Force -ErrorAction Stop)
        if($source.PSIsContainer -or $source.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Source must be a regular file.'}
        $destination=$ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($DestinationFile)
        if($source.FullName -eq $destination){throw 'Source and destination must differ.'}
        $record.Source=$source.FullName;$record.Destination=$destination
        $inputStream=[IO.File]::Open($source.FullName,'Open','Read','Read')
        $record.Length=$inputStream.Length
        $null=[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($destination))
        $temporary=$destination+'.'+[guid]::NewGuid().ToString('N')+'.partial'
        $outputStream=[IO.File]::Open($temporary,'CreateNew','ReadWrite','None')
        $inputStream.CopyTo($outputStream)
        $inputStream.Position=0;$outputStream.Position=0
        $hasher=[Security.Cryptography.SHA256]::Create()
        try {
            $sourceHash=[BitConverter]::ToString($hasher.ComputeHash($inputStream)).Replace('-','')
            $destinationHash=[BitConverter]::ToString($hasher.ComputeHash($outputStream)).Replace('-','')
        } finally {$hasher.Dispose()}
        if($sourceHash -ne $destinationHash -or $outputStream.Length -ne $record.Length){throw 'Copied length or SHA256 differs from source.'}
        $outputStream.Dispose();$outputStream=$null
        [IO.File]::SetLastWriteTimeUtc($temporary,$source.LastWriteTimeUtc)
        [IO.File]::Move($temporary,$destination,$true)
        $record.SHA256=$destinationHash;$record.Verified=$true;$record.Success=$true
    }
    catch {$record.Error=$_.Exception.Message}
    finally {
        if($inputStream){$inputStream.Dispose()}
        if($outputStream){$outputStream.Dispose()}
        if($temporary -and [IO.File]::Exists($temporary)){[IO.File]::Delete($temporary)}
    }
    if($PassThru){$record}else{[bool]$record.Success}
}
